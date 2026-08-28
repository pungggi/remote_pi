import 'dart:convert';
import 'dart:typed_data';

import 'package:cockpit/app/cockpit/domain/entities/http_document.dart';

/// Resposta normalizada de um request — o contrato que a aba e a CLI conhecem.
class HttpResponseResult {
  const HttpResponseResult({
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.bodyBytes,
    required this.elapsed,
    required this.requestLabel,
    this.truncated = false,
  });

  final int statusCode;
  final String reasonPhrase;
  final List<HttpHeader> headers;
  final Uint8List bodyBytes;
  final Duration elapsed;

  /// Rótulo do request que gerou esta resposta (`### nome` ou `GET url`).
  final String requestLabel;

  /// True quando o teto de bytes cortou o corpo — nunca truncar em silêncio.
  final bool truncated;

  int get sizeBytes => bodyBytes.length;

  String? headerValue(String name) {
    final lower = name.toLowerCase();
    for (final h in headers) {
      if (h.name.toLowerCase() == lower) return h.value;
    }
    return null;
  }

  String get contentType => headerValue('content-type') ?? '';

  bool get isJson {
    final ct = contentType.toLowerCase();
    return ct.contains('json') || ct.contains('+json');
  }

  /// Corpo como texto. Decodifica UTF-8 tolerando bytes inválidos (resposta
  /// binária vira replacement chars em vez de exceção).
  String get bodyText => utf8.decode(bodyBytes, allowMalformed: true);

  /// Corpo JSON indentado, ou `null` quando não é JSON válido — a aba cai no
  /// texto cru nesse caso (servidor que mente no `Content-Type` é comum).
  String? get prettyJson {
    if (bodyBytes.isEmpty) return null;
    try {
      final decoded = jsonDecode(bodyText);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } on FormatException {
      return null;
    }
  }

  /// Forma JSON da CLI (`{"ok": {...}}` fica por conta do chamador). O corpo
  /// vai decodificado quando é JSON válido, senão como texto.
  Map<String, Object?> toJson() {
    final pretty = prettyJson;
    return {
      'status': statusCode,
      'reason': reasonPhrase,
      'headers': {for (final h in headers) h.name: h.value},
      'elapsedMs': elapsed.inMilliseconds,
      'sizeBytes': sizeBytes,
      'truncated': truncated,
      'request': requestLabel,
      if (pretty != null) 'json': jsonDecode(bodyText) else 'body': bodyText,
    };
  }
}
