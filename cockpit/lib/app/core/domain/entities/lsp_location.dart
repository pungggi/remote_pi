import 'package:cockpit/app/core/domain/entities/lsp_diagnostic.dart';

/// Localização num arquivo (path + range) — resultado de `textDocument/definition`.
class LspLocation {
  const LspLocation({required this.uri, required this.range});

  /// URI do arquivo (`file:///...`).
  final String uri;

  /// Range dentro do arquivo (start + end).
  final LspRange range;

  factory LspLocation.fromJson(Map<String, dynamic> json) => LspLocation(
    uri: json['uri'] as String? ?? '',
    range: LspRange.fromJson((json['range'] as Map).cast<String, dynamic>()),
  );
}

/// LocationLink (formato newer de alguns servers: targetUri + targetRange + originSelectionRange).
class LspLocationLink {
  const LspLocationLink({
    required this.targetUri,
    required this.targetRange,
    this.originSelectionRange,
  });

  final String targetUri;
  final LspRange targetRange;
  final LspRange? originSelectionRange;

  factory LspLocationLink.fromJson(Map<String, dynamic> json) =>
      LspLocationLink(
        targetUri: json['targetUri'] as String? ?? '',
        targetRange: LspRange.fromJson(
          (json['targetRange'] as Map).cast<String, dynamic>(),
        ),
        originSelectionRange: json['originSelectionRange'] is Map
            ? LspRange.fromJson(
                (json['originSelectionRange'] as Map).cast<String, dynamic>(),
              )
            : null,
      );

  /// Converte pra Location (drop originSelectionRange).
  LspLocation toLocation() => LspLocation(uri: targetUri, range: targetRange);
}

/// Converte offset UTF-16 linear pra {line, character} (base 0).
/// Mesmo padrão de `diagnosticRangesFor` inverso.
LspPosition offsetToPosition(String text, int offset) {
  if (offset < 0) return const LspPosition(0, 0);
  if (offset > text.length) offset = text.length;

  var line = 0;
  var lineStart = 0;
  for (var i = 0; i < offset; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      line++;
      lineStart = i + 1;
    }
  }
  final character = offset - lineStart;
  return LspPosition(line, character);
}

/// Decodifica resposta de `textDocument/definition` (pode ser vários formatos).
/// Retorna primeira location, ou null se não há resultado.
LspLocation? parseDefinitionResponse(Object? response) {
  if (response == null) return null;

  // Map simples — pode ser Location ou LocationLink
  if (response is Map<String, dynamic>) {
    if (response.containsKey('targetUri')) {
      return LspLocationLink.fromJson(response).toLocation();
    }
    return LspLocation.fromJson(response);
  }

  // Array — Location[] ou LocationLink[]
  if (response is List) {
    if (response.isEmpty) return null;
    final first = response[0];
    if (first is Map<String, dynamic>) {
      if (first.containsKey('targetUri')) {
        return LspLocationLink.fromJson(first).toLocation();
      }
      return LspLocation.fromJson(first);
    }
  }

  return null;
}
