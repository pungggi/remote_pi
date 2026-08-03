/// Tokens semânticos do LSP: posição + tipo + modificadores (formato cru).
/// Decodificados de um array plano 5-ints-por-token em offsets lineares.
library;

/// Legenda: arrays de `tokenTypes` e `tokenModifiers` (índices na resposta).
class SemanticTokensLegend {
  const SemanticTokensLegend({
    required this.tokenTypes,
    required this.tokenModifiers,
  });

  /// Nomes dos tipos (ex: `['class', 'variable', 'function', ...]`).
  final List<String> tokenTypes;

  /// Nomes dos modificadores (ex: `['declaration', 'readonly', ...]`).
  final List<String> tokenModifiers;

  factory SemanticTokensLegend.fromJson(Map<String, dynamic> json) =>
      SemanticTokensLegend(
        tokenTypes:
            (json['tokenTypes'] as List?)?.cast<String>() ?? const <String>[],
        tokenModifiers: (json['tokenModifiers'] as List?)?.cast<String>() ??
            const <String>[],
      );
}

/// Um token semântico decodificado: posição + tipo + modificadores.
class SemanticToken {
  const SemanticToken({
    required this.start,
    required this.end,
    required this.tokenType,
    required this.tokenModifiers,
  });

  final int start;
  final int end;

  /// Nome do tipo (ex: `'class'`, `'variable'`).
  final String tokenType;

  /// Lista de nomes de modificadores (ex: `['declaration', 'readonly']`).
  final List<String> tokenModifiers;
}

/// Lista de tokens semânticos do LSP para um documento.
class SemanticTokens {
  const SemanticTokens({required this.tokens});

  final List<SemanticToken> tokens;
}

/// Decodifica o array plano do LSP (`textDocument/semanticTokens/full`)
/// em offsets absolutos usando a mesma lógica de `diagnosticRangesFor`.
/// Array plano: `[deltaLine, deltaStartChar, length, tokenType, modifiers, ...]`
/// (5 ints por token).
SemanticTokens decodeSemanticTokens(
  String text,
  List<int> data,
  SemanticTokensLegend legend,
) {
  if (data.isEmpty) return SemanticTokens(tokens: const <SemanticToken>[]);

  // Índice de início de cada linha (offset logo após cada '\n').
  final lineStarts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) lineStarts.add(i + 1);
  }

  int offsetFor(int line, int character) {
    if (line < 0) return 0;
    if (line >= lineStarts.length) return text.length;
    final base = lineStarts[line];
    final contentEnd = line + 1 < lineStarts.length
        ? lineStarts[line + 1] - 1
        : text.length;
    final offset = base + (character < 0 ? 0 : character);
    return offset.clamp(base, contentEnd);
  }

  var line = 0;
  var character = 0;
  final tokens = <SemanticToken>[];

  for (var i = 0; i + 5 <= data.length; i += 5) {
    final deltaLine = data[i];
    final deltaStart = data[i + 1];
    final length = data[i + 2];
    final tokenTypeIdx = data[i + 3];
    final modifiersMask = data[i + 4];

    // Atualiza posição.
    if (deltaLine > 0) {
      line += deltaLine;
      character = deltaStart;
    } else {
      character += deltaStart;
    }

    // Resolve tipos e modificadores pela legenda.
    final tokenType = tokenTypeIdx >= 0 && tokenTypeIdx < legend.tokenTypes.length
        ? legend.tokenTypes[tokenTypeIdx]
        : '';

    final mods = <String>[];
    for (var j = 0; j < legend.tokenModifiers.length; j++) {
      if ((modifiersMask & (1 << j)) != 0) {
        mods.add(legend.tokenModifiers[j]);
      }
    }

    // Converte pra offsets lineares.
    final start = offsetFor(line, character);
    final end = (start + length).clamp(0, text.length);

    if (end > start) {
      tokens.add(SemanticToken(
        start: start,
        end: end,
        tokenType: tokenType,
        tokenModifiers: mods,
      ));
    }
  }

  return SemanticTokens(tokens: tokens);
}
