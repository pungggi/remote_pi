// Entidades da busca por **conteúdo** (find-in-files). Imutáveis e sem
// dependência de IO/UI — trafegam do `data/` (walk em Isolate) até a `ui/`.

/// Parâmetros de uma busca de conteúdo na pasta [root].
class ContentQuery {
  const ContentQuery({
    required this.root,
    required this.term,
    this.caseSensitive = false,
    this.wholeWord = false,
    this.regex = false,
  });

  /// Pasta raiz (caminho absoluto) onde varrer recursivamente.
  final String root;

  /// Texto (ou padrão, se [regex]) a procurar.
  final String term;

  /// Diferencia maiúsculas/minúsculas (toggle "Aa").
  final bool caseSensitive;

  /// Casa apenas palavras inteiras (toggle "ab" → `\b…\b`).
  final bool wholeWord;

  /// Interpreta [term] como expressão regular (toggle ".*").
  final bool regex;
}

/// Um intervalo `[start, end)` (colunas, base 0) de um match **dentro** da linha.
class MatchRange {
  const MatchRange(this.start, this.end);
  final int start;
  final int end;
}

/// Uma linha que contém ≥1 match, com o texto da linha e os intervalos casados.
class LineMatch {
  const LineMatch({
    required this.lineNumber,
    required this.text,
    required this.ranges,
  });

  /// Número da linha (base 1) — alimenta o gutter e o scroll-to-line.
  final int lineNumber;

  /// Texto da linha (sem o `\n`), possivelmente truncado p/ payloads enormes.
  final String text;

  /// Intervalos casados dentro de [text], em ordem.
  final List<MatchRange> ranges;
}

/// Resultados de um arquivo (caminho relativo à raiz) — um grupo do painel.
class FileMatches {
  const FileMatches({required this.relativePath, required this.matches});

  /// Caminho relativo à [ContentQuery.root] (ex.: `app/auth/session.ts`).
  final String relativePath;

  /// Linhas casadas, na ordem do arquivo.
  final List<LineMatch> matches;

  /// Total de matches no arquivo (soma dos ranges de todas as linhas).
  int get matchCount => matches.fold(0, (sum, m) => sum + m.ranges.length);
}
