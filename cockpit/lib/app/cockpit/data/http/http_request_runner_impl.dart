import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cockpit/app/cockpit/domain/contracts/http_request_runner.dart';
import 'package:cockpit/app/cockpit/domain/entities/http_document.dart';
import 'package:cockpit/app/cockpit/domain/entities/http_response_result.dart';
import 'package:cockpit/app/cockpit/domain/exceptions/http_request_error.dart';
import 'package:cockpit/app/core/domain/result.dart';

/// Executor sobre o `HttpClient` do `dart:io` — sem dependência nova no
/// pubspec. Um cliente por chamada: `.http` é uso interativo (uma request por
/// vez), então pool de conexões não paga o risco de vazar socket entre
/// workspaces.
class HttpRequestRunnerImpl implements HttpRequestRunner {
  /// Teto de corpo guardado em memória (a aba mostra o texto inteiro). Acima
  /// disso a resposta é cortada e marcada como truncada.
  static const int maxBodyBytes = 8 * 1024 * 1024;

  @override
  Future<Result<HttpResponseResult, HttpRequestError>> send(
    HttpRequestSpec spec, {
    required String baseDir,
    Duration timeout = const Duration(seconds: 30),
    bool followRedirects = true,
  }) async {
    // Placeholder não vai para o ar: acusa antes de abrir socket.
    final unresolved = HttpDocument.unresolvedIn(spec);
    if (unresolved.isNotEmpty) {
      return Failure(
        HttpRequestError(
          HttpRequestErrorKind.unresolvedVariable,
          variable: unresolved.first,
        ),
      );
    }

    final uri = Uri.tryParse(spec.url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return Failure(
        HttpRequestError(HttpRequestErrorKind.invalidUrl, detail: spec.url),
      );
    }

    // Body: literal do arquivo ou importado por `< ./arquivo`.
    Uint8List? body;
    if (spec.bodyFile != null) {
      final path = _resolve(baseDir, spec.bodyFile!);
      try {
        body = await File(path).readAsBytes();
      } on FileSystemException catch (e) {
        return Failure(
          HttpRequestError(
            HttpRequestErrorKind.bodyFileUnreadable,
            path: path,
            detail: e.osError?.message ?? e.message,
          ),
        );
      }
    } else if (spec.body != null && spec.body!.isNotEmpty) {
      body = Uint8List.fromList(utf8.encode(spec.body!));
    }

    final client = HttpClient()..connectionTimeout = timeout;
    final started = DateTime.now();
    try {
      final request = await client.openUrl(spec.method, uri).timeout(timeout);
      request.followRedirects = followRedirects;
      for (final h in spec.headers) {
        // `set` (não `add`) para o header do arquivo vencer o default do
        // HttpClient — senão `Content-Type` sai duplicado.
        request.headers.set(h.name, h.value);
      }
      if (body != null) {
        request.headers.contentLength = body.length;
        request.add(body);
      }

      final response = await request.close().timeout(timeout);
      final (bytes, truncated) = await _readBody(response, timeout);

      final headers = <HttpHeader>[];
      response.headers.forEach((name, values) {
        for (final v in values) {
          headers.add((name: name, value: v));
        }
      });

      return Success(
        HttpResponseResult(
          statusCode: response.statusCode,
          reasonPhrase: response.reasonPhrase,
          headers: headers,
          bodyBytes: bytes,
          elapsed: DateTime.now().difference(started),
          requestLabel: spec.label,
          truncated: truncated,
        ),
      );
    } on TimeoutException {
      return Failure(
        HttpRequestError(
          HttpRequestErrorKind.timeout,
          timeoutSeconds: timeout.inSeconds,
        ),
      );
    } on SocketException catch (e) {
      return Failure(
        HttpRequestError(
          HttpRequestErrorKind.connectionFailed,
          detail: e.osError?.message ?? e.message,
        ),
      );
    } on HandshakeException catch (e) {
      return Failure(
        HttpRequestError(
          HttpRequestErrorKind.connectionFailed,
          detail: e.message,
        ),
      );
    } on HttpException catch (e) {
      return Failure(
        HttpRequestError(
          HttpRequestErrorKind.connectionFailed,
          detail: e.message,
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Lê o corpo respeitando [maxBodyBytes]: passou do teto, para de acumular e
  /// devolve `truncated`.
  Future<(Uint8List, bool)> _readBody(
    HttpClientResponse response,
    Duration timeout,
  ) async {
    final builder = BytesBuilder(copy: false);
    var truncated = false;
    await for (final chunk in response.timeout(timeout)) {
      if (builder.length >= maxBodyBytes) {
        truncated = true;
        continue;
      }
      final room = maxBodyBytes - builder.length;
      if (chunk.length > room) {
        builder.add(chunk.sublist(0, room));
        truncated = true;
      } else {
        builder.add(chunk);
      }
    }
    return (builder.takeBytes(), truncated);
  }

  /// Resolve `< ./body.json` contra a pasta do arquivo `.http`; caminho
  /// absoluto passa direto.
  static String _resolve(String baseDir, String path) {
    final isAbsolute =
        path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
    if (isAbsolute || baseDir.isEmpty) return path;
    return '$baseDir${Platform.pathSeparator}$path';
  }
}
