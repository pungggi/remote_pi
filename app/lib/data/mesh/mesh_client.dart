import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'mesh_envelope.dart';

/// Outcome of `MeshClient.fetch()`.
sealed class MeshFetchResult {
  const MeshFetchResult();
}

/// Relay returned the current envelope. `version` and `updatedAt` come
/// from the response body envelope; the [envelope] itself is the raw
/// `{blob, sig}` ready for `MeshBlob.verifyEnvelope`.
final class MeshFetchOk extends MeshFetchResult {
  final MeshEnvelope envelope;
  final int version;
  final int updatedAt;
  const MeshFetchOk({
    required this.envelope,
    required this.version,
    required this.updatedAt,
  });
}

/// Relay's stored version is `<= since` — caller is already up to date.
final class MeshFetchNotModified extends MeshFetchResult {
  const MeshFetchNotModified();
}

/// Relay never had a row for this Owner. Treat as `current_version = 0`.
final class MeshFetchNotFound extends MeshFetchResult {
  const MeshFetchNotFound();
}

/// Anything else — transient network error, 5xx, etc.
final class MeshFetchFailure extends MeshFetchResult {
  final String reason;
  const MeshFetchFailure(this.reason);
}

/// Outcome of `MeshClient.publish()`.
sealed class MeshPublishResult {
  const MeshPublishResult();
}

/// 200 OK — the relay accepted the new version.
final class MeshPublishOk extends MeshPublishResult {
  final int version;
  final int updatedAt;
  const MeshPublishOk({required this.version, required this.updatedAt});
}

/// 409 Conflict — another device published a higher version while we
/// were preparing this one. Caller should re-fetch + decide whether to
/// rebase.
final class MeshPublishConflict extends MeshPublishResult {
  const MeshPublishConflict();
}

/// 400 — malformed body, base64 broken, version non-numeric. Bug in
/// the caller, not the network.
final class MeshPublishBadRequest extends MeshPublishResult {
  final String message;
  const MeshPublishBadRequest(this.message);
}

/// 403 — signature did not verify or owner_pk_hash on the URL doesn't
/// match the embedded owner_pk.
final class MeshPublishForbidden extends MeshPublishResult {
  const MeshPublishForbidden();
}

/// 413 — blob exceeded the relay's 500KB cap (plan/24 § Q4).
final class MeshPublishTooLarge extends MeshPublishResult {
  const MeshPublishTooLarge();
}

/// Network failure, 5xx, timeout, anything else.
final class MeshPublishFailure extends MeshPublishResult {
  final String reason;
  const MeshPublishFailure(this.reason);
}

/// HTTP client for the plan-24 `/mesh/<owner_pk_hash>` endpoints.
///
/// The base URL is resolved lazily via [baseUrlProvider] so a runtime
/// change to `Preferences.relayUrl` propagates without re-creating the
/// client. Status codes 200/304/400/403/404/409/413 are folded into
/// the [MeshFetchResult] / [MeshPublishResult] sealed hierarchy; raw
/// `DioException`s never escape.
class MeshClient {
  /// Lazily resolved base URL — typically wraps `toHttpRelayUrl(
  /// resolveRelayUrl(prefs))`. Called on every request so a relay
  /// switch via Settings is picked up without re-injecting the client.
  final String Function() baseUrlProvider;

  final Dio _dio;

  MeshClient({required this.baseUrlProvider, Dio? dio})
      : _dio = dio ?? _defaultDio();

  static Dio _defaultDio() {
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      sendTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      // We treat every non-2xx status manually — don't let dio throw.
      validateStatus: (_) => true,
      // Plain so an empty / non-JSON body on 4xx/5xx doesn't trip the
      // built-in JSON parser into raising a DioException. We jsonDecode
      // manually on the success branch.
      responseType: ResponseType.plain,
    ));
  }

  /// Decode a response body string as JSON when present. Returns null
  /// when the body is empty or not a JSON object — callers fall back
  /// to status-only handling.
  Map<String, Object?>? _decodeBody(Object? data) {
    if (data is Map<String, Object?>) return data;
    if (data is String && data.isNotEmpty) {
      try {
        final parsed = jsonDecode(data);
        if (parsed is Map<String, Object?>) return parsed;
      } catch (_) {/* fall through */}
    }
    return null;
  }

  /// SHA-256 of the raw owner public key, encoded as lowercase hex.
  /// Used as the URL path segment for both GET and POST.
  static Future<String> ownerPkHash(Uint8List ownerPk) async {
    final hash = await Sha256().hash(ownerPk);
    final buf = StringBuffer();
    for (final b in hash.bytes) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  /// `null` when no relay is configured yet — since plan/102 that is a normal
  /// state before the first pairing, not an error (see [kDefaultRelayUrl]).
  /// Without this guard an empty base yields the *relative* URI `/mesh/<hash>`,
  /// which fails somewhere deeper with a far less obvious message.
  Uri? _meshUri(String hash) {
    final base = baseUrlProvider();
    if (base.isEmpty) return null;
    final trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return Uri.parse('$trimmed/mesh/$hash');
  }

  /// `GET /mesh/<hash>?since=<version>`.
  /// Returns one of [MeshFetchOk], [MeshFetchNotModified],
  /// [MeshFetchNotFound], [MeshFetchFailure].
  Future<MeshFetchResult> fetch(String hash, {int? since}) async {
    try {
      final uri = _meshUri(hash);
      if (uri == null) return const MeshFetchFailure('no relay configured');
      final response = await _dio.getUri<Object?>(
        since == null ? uri : uri.replace(queryParameters: {'since': '$since'}),
        options: Options(
          // Plain so 4xx/5xx bodies don't trip dio's JSON parser.
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      switch (response.statusCode) {
        case 200:
          final data = _decodeBody(response.data);
          if (data == null) {
            return const MeshFetchFailure('200 OK body was not a JSON object');
          }
          final version = data['version'];
          final updatedAt = data['updated_at'];
          if (version is! int || updatedAt is! int) {
            return const MeshFetchFailure(
              '200 OK missing version / updated_at integers',
            );
          }
          return MeshFetchOk(
            envelope: MeshEnvelope.fromJson(data),
            version: version,
            updatedAt: updatedAt,
          );
        case 304:
          return const MeshFetchNotModified();
        case 404:
          return const MeshFetchNotFound();
        default:
          return MeshFetchFailure(
            'unexpected status ${response.statusCode}',
          );
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status != null) {
        return MeshFetchFailure('unexpected status $status');
      }
      return MeshFetchFailure(e.message ?? 'network error');
    } catch (e) {
      return MeshFetchFailure(e.toString());
    }
  }

  /// `POST /mesh/<hash>` with `{blob, sig}` body.
  Future<MeshPublishResult> publish(
    String hash,
    MeshEnvelope envelope,
  ) async {
    try {
      final uri = _meshUri(hash);
      if (uri == null) return const MeshPublishFailure('no relay configured');
      final response = await _dio.postUri<Object?>(
        uri,
        data: jsonEncode(envelope.toJson()),
        options: Options(
          contentType: 'application/json',
          headers: {'accept': 'application/json'},
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      switch (response.statusCode) {
        case 200:
          final data = _decodeBody(response.data);
          if (data == null) {
            return const MeshPublishFailure(
              '200 OK body was not a JSON object',
            );
          }
          final version = data['version'];
          final updatedAt = data['updated_at'];
          if (version is! int || updatedAt is! int) {
            return const MeshPublishFailure(
              '200 OK missing version / updated_at integers',
            );
          }
          return MeshPublishOk(version: version, updatedAt: updatedAt);
        case 400:
          return MeshPublishBadRequest(_extractMessage(response.data));
        case 403:
          return const MeshPublishForbidden();
        case 409:
          return const MeshPublishConflict();
        case 413:
          return const MeshPublishTooLarge();
        default:
          return MeshPublishFailure(
            'unexpected status ${response.statusCode}',
          );
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status != null) {
        return MeshPublishFailure('unexpected status $status');
      }
      return MeshPublishFailure(e.message ?? 'network error');
    } catch (e) {
      return MeshPublishFailure(e.toString());
    }
  }

  String _extractMessage(Object? body) {
    final decoded = _decodeBody(body);
    if (decoded != null) {
      final m = decoded['message'];
      if (m is String) return m;
      final e = decoded['error'];
      if (e is String) return e;
    }
    if (body is String && body.isNotEmpty) return body;
    return 'bad request';
  }
}
