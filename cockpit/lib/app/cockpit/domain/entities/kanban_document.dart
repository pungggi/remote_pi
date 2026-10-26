/// Um arquivo `.kanban`: frontmatter YAML opcional + colunas em `##` + cards
/// em itens de checklist markdown.
///
/// ```markdown
/// ---
/// columns: [Backlog, Doing, Done]
/// labels: {relay: orange, bug: red}
/// ---
///
/// ## Doing
///
/// - [ ] Túnel SSH no host <!-- id: k3 labels: relay -->
///       Nota livre em markdown.
///
/// ## Done
///
/// - [x] Absorver o plugin de PTY <!-- id: k1 -->
/// ```
///
/// **O parser nunca lança.** Qualquer arquivo vira um [KanbanDocument]: sem
/// `##` o quadro sai sem colunas (a UI cai no viewer de markdown), e um bloco
/// que não casa com card vira um [KanbanCard] `recognized: false` — visível e
/// arrastável inteiro, mas sem edição inline. Markdown que não modelamos
/// sobrevive intacto porque nenhuma edição reserializa o arquivo: toda mutação
/// é uma **emenda de linhas** sobre o texto original ([_splice]), então
/// comentários, indentação e blocos estranhos ficam byte a byte no lugar.
library;

/// Cores possíveis de um marcador. Nomes, não hex: cor livre não sobrevive à
/// troca de tema (a UI resolve cada nome num token do tema atual).
enum KanbanLabelColor {
  orange,
  purple,
  red,
  green,
  amber,
  blue,
  gray;

  static KanbanLabelColor parse(String value) =>
      KanbanLabelColor.values.firstWhere(
        (c) => c.name == value.trim().toLowerCase(),
        orElse: () => KanbanLabelColor.gray,
      );
}

/// Um comentário de card: um bloco marcado por `<!-- comment: <data> -->`
/// dentro do corpo do card. O mais NOVO fica no topo, então a ordem do arquivo
/// já é a ordem de leitura — ninguém precisa ordenar por data pra exibir.
class KanbanComment {
  const KanbanComment({
    required this.text,
    required this.createdAt,
    required this.startLine,
    required this.endLine,
  });

  final String text;

  /// O que estava no marcador (ISO curto, `2026-09-06T19:22`). Texto de
  /// máquina: não é traduzido nem reformatado por locale.
  final String? createdAt;

  final int startLine;
  final int endLine;
}

/// Um card. [startLine]/[endLine] delimitam as linhas de origem no arquivo
/// (fim exclusivo) — é por esse intervalo que o card é movido sem reescrever
/// nada em volta.
class KanbanCard {
  const KanbanCard({
    required this.title,
    required this.checked,
    required this.labels,
    required this.notes,
    required this.startLine,
    required this.endLine,
    required this.id,
    this.comments = const [],
    this.blockedBy = const [],
    int? notesEndLine,
    this.recognized = true,
  }) : notesEndLine = notesEndLine ?? endLine;

  final String title;
  final bool checked;
  final List<String> labels;

  /// Ids dos cards que bloqueiam este (`blockedBy: k1, k2` no comentário).
  /// Só esta direção é gravada; "bloqueia N" é derivado na leitura
  /// ([KanbanDocument.blocksCount]). Referência por id: renomear não quebra.
  final List<String> blockedBy;

  /// Corpo em markdown: as linhas de continuação ATÉ o primeiro comentário
  /// (sem a indentação comum).
  final String notes;

  /// Comentários do card, do mais novo para o mais antigo.
  final List<KanbanComment> comments;

  final int startLine;
  final int endLine;

  /// Onde a nota acaba e os comentários começam (fim exclusivo). Editar a nota
  /// mexe só neste intervalo — sem isso, reescrever a nota apagaria a conversa
  /// abaixo dela.
  final int notesEndLine;

  /// Id estável no comentário HTML. `null` até a primeira mutação pela UI —
  /// não obrigamos ninguém (nem o agente) a escrever isso à mão.
  final String? id;

  /// `false` quando o bloco não casou com a forma de card. A UI mostra, deixa
  /// arrastar inteiro e **não** deixa editar — mexer no que não entendemos é
  /// como se perde conteúdo.
  final bool recognized;

  int get lineCount => endLine - startLine;
}

/// Uma coluna: o heading `##` e tudo até o próximo heading (fim exclusivo).
class KanbanColumn {
  const KanbanColumn({
    required this.name,
    required this.cards,
    required this.headingLine,
    required this.endLine,
  });

  final String name;
  final List<KanbanCard> cards;
  final int headingLine;
  final int endLine;
}

/// Resultado do parse. Imutável: as mutações devolvem o **conteúdo novo** do
/// arquivo (String), e quem chamou reparseia. Assim a tela nunca diverge do
/// que foi gravado.
class KanbanDocument {
  const KanbanDocument({
    required this.lines,
    required this.columns,
    required this.labelColors,
    required this.frontmatterEnd,
    this.title,
    this.eol = '\n',
  });

  /// O arquivo inteiro, linha a linha — a fonte de verdade das emendas.
  final List<String> lines;

  final List<KanbanColumn> columns;

  /// Marcador → cor, lido de `labels:` no frontmatter. Marcador usado num card
  /// mas ausente daqui existe do mesmo jeito, em cinza.
  final Map<String, KanbanLabelColor> labelColors;

  /// Linha logo após o `---` de fechamento; 0 quando não há frontmatter.
  final int frontmatterEnd;

  /// Terminador de linha do arquivo original (`\n` ou `\r\n`).
  ///
  /// Preservá-lo é o que mantém a promessa do formato no Windows: sem isto, um
  /// arquivo CRLF virava LF na PRIMEIRA edição e mover um card produzia um diff
  /// tocando todas as linhas — exatamente o oposto da emenda de três linhas.
  final String eol;

  /// Nome do quadro (`title:` no frontmatter), quando houver. É o rótulo que a
  /// aba mostra — mora no arquivo, e não só no layout, pra viajar com ele no
  /// git e reaparecer em qualquer máquina que o abra.
  final String? title;

  bool get isBoard => columns.isNotEmpty;

  String get content => lines.join(eol);

  /// Card por id (`null` se nenhum card tem esse id).
  KanbanCard? cardById(String id) {
    for (final column in columns) {
      for (final card in column.cards) {
        if (card.id == id) return card;
      }
    }
    return null;
  }

  /// Índice da coluna onde [card] está (-1 se não está no documento).
  int columnOf(KanbanCard card) {
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].cards.any((c) => c.startLine == card.startLine)) return i;
    }
    return -1;
  }

  /// Cards que bloqueiam [card] e ainda existem (ids desconhecidos ficam de
  /// fora; ver [unknownBlockers]).
  List<KanbanCard> blockersOf(KanbanCard card) => [
    for (final id in card.blockedBy) ?cardById(id),
  ];

  /// Ids em `blockedBy` que não apontam pra card nenhum (apagado, ou erro).
  List<String> unknownBlockers(KanbanCard card) => [
    for (final id in card.blockedBy)
      if (cardById(id) == null) id,
  ];

  /// Bloqueado = ao menos um bloqueador que ainda não chegou à última coluna.
  /// Derivado, nunca gravado: quando o bloqueador termina, o bloqueio some
  /// sozinho. Id desconhecido não bloqueia (não há o que esperar).
  bool isBlocked(KanbanCard card) {
    if (columns.isEmpty) return false;
    final last = columns.length - 1;
    return blockersOf(card).any((b) => columnOf(b) != last);
  }

  /// Quantos cards ainda dependem de [card] (o inverso de `blockedBy`).
  int blocksCount(KanbanCard card) {
    final id = card.id;
    if (id == null) return 0;
    var n = 0;
    for (final column in columns) {
      for (final c in column.cards) {
        if (c.blockedBy.contains(id)) n++;
      }
    }
    return n;
  }

  /// Todos os marcadores em uso, na ordem em que aparecem no frontmatter e
  /// depois os que só existem nos cards.
  List<String> get allLabels {
    final seen = <String>{...labelColors.keys};
    final extra = <String>[];
    for (final column in columns) {
      for (final card in column.cards) {
        for (final label in card.labels) {
          if (seen.add(label)) extra.add(label);
        }
      }
    }
    return [...labelColors.keys, ...extra];
  }

  /// Quantos cards usam [label].
  int usageOf(String label) => columns
      .expand((c) => c.cards)
      .where((card) => card.labels.contains(label))
      .length;

  KanbanLabelColor colorOf(String label) =>
      labelColors[label] ?? KanbanLabelColor.gray;

  // ---------------------------------------------------------------- parse ---

  static final _heading = RegExp(r'^##[ \t]+(.*?)[ \t]*$');
  static final _cardLine = RegExp(r'^[ \t]{0,1}-[ \t]+\[([ xX])\][ \t]?(.*)$');
  static final _meta = RegExp(r'<!--\s*(.*?)\s*-->\s*$');
  static final _idKey = RegExp(r'\bid:\s*([A-Za-z0-9_-]+)');
  // `labels:` para antes de ` blockedBy:` (e vice-versa): as duas chaves
  // vivem no mesmo comentário, em qualquer ordem.
  static final _labelsKey = RegExp(
    r'\blabels:\s*(.*?)(?:\s+blockedBy:|\s*-->|$)',
  );
  static final _blockedByKey = RegExp(
    r'\bblockedBy:\s*(.*?)(?:\s+labels:|\s*-->|$)',
  );
  static final _commentMark = RegExp(r'^\s*<!--\s*comment:\s*(.*?)\s*-->\s*$');

  static KanbanDocument parse(String content) {
    // O terminador do arquivo é o do PRIMEIRO fim de linha — o que ele usa de
    // fato. Depois disso trabalhamos só com `\n` internamente.
    final firstBreak = content.indexOf('\n');
    final eol = (firstBreak > 0 && content[firstBreak - 1] == '\r')
        ? '\r\n'
        : '\n';
    final lines = content.replaceAll('\r\n', '\n').split('\n');
    final frontmatterEnd = _frontmatterEnd(lines);
    final labelColors = _parseLabelColors(lines, frontmatterEnd);
    final title = _parseTitle(lines, frontmatterEnd);

    // Índices dos headings de coluna, ignorando o que está dentro de cerca de
    // código (senão um `## ` num bloco ``` viraria coluna fantasma).
    final headings = <int>[];
    var fenced = false;
    for (var i = frontmatterEnd; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('```')) fenced = !fenced;
      if (fenced) continue;
      if (_heading.hasMatch(line)) headings.add(i);
    }

    final columns = <KanbanColumn>[];
    for (var h = 0; h < headings.length; h++) {
      final headingLine = headings[h];
      final endLine = h + 1 < headings.length ? headings[h + 1] : lines.length;
      columns.add(
        KanbanColumn(
          name: _heading.firstMatch(lines[headingLine])!.group(1)!,
          headingLine: headingLine,
          endLine: endLine,
          cards: _parseCards(lines, headingLine + 1, endLine),
        ),
      );
    }

    return KanbanDocument(
      lines: lines,
      columns: columns,
      labelColors: labelColors,
      frontmatterEnd: frontmatterEnd,
      title: title,
      eol: eol,
    );
  }

  /// `title: <nome>` do frontmatter. Aspas em volta são opcionais e caem fora;
  /// comentário YAML no fim da linha também.
  static String? _parseTitle(List<String> lines, int frontmatterEnd) {
    for (var i = 0; i < frontmatterEnd; i++) {
      final match = RegExp(r'^title:\s*(.*?)\s*$').firstMatch(lines[i]);
      if (match == null) continue;
      final value = _scalar(match.group(1)!);
      return value.isEmpty ? null : value;
    }
    return null;
  }

  /// Um escalar YAML simples: tira aspas, ou corta o comentário de fim de linha.
  ///
  /// A regra de comentário é a do YAML — `#` só abre comentário quando vem
  /// depois de espaço —, e por isso um título com `#` no meio precisa de
  /// aspas (`title: "Sprint #4"`), exatamente como em YAML de verdade.
  static String _scalar(String raw) {
    final value = raw.trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      return value.substring(1, value.length - 1);
    }
    final comment = RegExp(r'(^|\s)#').firstMatch(value);
    if (comment == null) return value;
    return value.substring(0, comment.start).trim();
  }

  /// Índice da primeira linha após o frontmatter (0 se não houver).
  static int _frontmatterEnd(List<String> lines) {
    if (lines.isEmpty || lines.first.trim() != '---') return 0;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') return i + 1;
    }
    return 0; // abertura sem fechamento: não é frontmatter, é conteúdo.
  }

  static Map<String, KanbanLabelColor> _parseLabelColors(
    List<String> lines,
    int frontmatterEnd,
  ) {
    final colors = <String, KanbanLabelColor>{};
    for (var i = 0; i < frontmatterEnd; i++) {
      // Não-guloso até a chave de fechamento: o que vier depois (comentário
      // YAML) não faz parte do mapa.
      final match = RegExp(r'^labels:\s*\{(.*?)\}').firstMatch(lines[i]);
      if (match == null) continue;
      for (final entry in match.group(1)!.split(',')) {
        final parts = entry.split(':');
        if (parts.length != 2) continue;
        final name = parts[0].trim();
        if (name.isEmpty) continue;
        colors[name] = KanbanLabelColor.parse(parts[1]);
      }
    }
    return colors;
  }

  /// Fatia [from, to) em cards. O que não é card vira bloco `recognized:
  /// false` em vez de sumir.
  static List<KanbanCard> _parseCards(List<String> lines, int from, int to) {
    final cards = <KanbanCard>[];
    var i = from;
    var pendingStart = -1; // início de um bloco não reconhecido em aberto

    void flushUnrecognized(int end) {
      if (pendingStart < 0) return;
      var stop = end;
      while (stop > pendingStart && lines[stop - 1].trim().isEmpty) {
        stop--;
      }
      if (stop > pendingStart) {
        final raw = lines.sublist(pendingStart, stop);
        cards.add(
          KanbanCard(
            title: raw.first.trim(),
            checked: false,
            labels: const [],
            notes: raw.skip(1).join('\n'),
            startLine: pendingStart,
            endLine: stop,
            id: null,
            recognized: false,
          ),
        );
      }
      pendingStart = -1;
    }

    while (i < to) {
      final match = _cardLine.firstMatch(lines[i]);
      if (match == null) {
        if (lines[i].trim().isNotEmpty && pendingStart < 0) pendingStart = i;
        i++;
        continue;
      }
      flushUnrecognized(i);

      final start = i;
      var end = i + 1;
      // Continuações: linhas indentadas (≥2 espaços) e as brancas entre elas.
      while (end < to) {
        final line = lines[end];
        if (line.trim().isEmpty) {
          final next = _nextNonBlank(lines, end + 1, to);
          if (next == null || !_isContinuation(lines[next])) break;
          end++;
          continue;
        }
        if (!_isContinuation(line)) break;
        end++;
      }

      final head = match.group(2) ?? '';
      final meta = _meta.firstMatch(head);
      final title = (meta == null ? head : head.substring(0, meta.start))
          .trim();
      final metaBody = meta?.group(1) ?? '';

      // O corpo se divide em nota e comentários no PRIMEIRO marcador; o que
      // vem antes é nota, cada marcador abre um comentário que vai até o
      // próximo (ou até o fim do card).
      final marks = <int>[];
      for (var j = start + 1; j < end; j++) {
        if (_commentMark.hasMatch(lines[j])) marks.add(j);
      }
      final notesEnd = marks.isEmpty ? end : marks.first;
      final comments = <KanbanComment>[];
      for (var m = 0; m < marks.length; m++) {
        final from = marks[m];
        final to = m + 1 < marks.length ? marks[m + 1] : end;
        comments.add(
          KanbanComment(
            createdAt: _commentMark.firstMatch(lines[from])!.group(1),
            text: _dedent(lines.sublist(from + 1, to)),
            startLine: from,
            endLine: to,
          ),
        );
      }

      cards.add(
        KanbanCard(
          title: title,
          checked: match.group(1)!.toLowerCase() == 'x',
          labels: _parseLabels(metaBody),
          blockedBy: _parseList(_blockedByKey, metaBody),
          notes: _dedent(lines.sublist(start + 1, notesEnd)),
          comments: comments,
          startLine: start,
          endLine: end,
          notesEndLine: notesEnd,
          id: _idKey.firstMatch(metaBody)?.group(1),
        ),
      );
      i = end;
    }
    flushUnrecognized(to);
    return cards;
  }

  static bool _isContinuation(String line) =>
      line.startsWith('  ') || line.startsWith('\t');

  static int? _nextNonBlank(List<String> lines, int from, int to) {
    for (var i = from; i < to; i++) {
      if (lines[i].trim().isNotEmpty) return i;
    }
    return null;
  }

  static List<String> _parseLabels(String metaBody) =>
      _parseList(_labelsKey, metaBody);

  static List<String> _parseList(RegExp key, String metaBody) {
    final match = key.firstMatch(metaBody);
    if (match == null) return const [];
    return match
        .group(1)!
        .split(',')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// Remove a indentação comum das linhas de nota.
  static String _dedent(List<String> raw) {
    if (raw.isEmpty) return '';
    var indent = 1 << 30;
    for (final line in raw) {
      if (line.trim().isEmpty) continue;
      indent = indent < _indentOf(line) ? indent : _indentOf(line);
    }
    if (indent == 1 << 30) indent = 0;
    return raw
        .map((l) => l.length >= indent ? l.substring(indent) : l.trimLeft())
        .join('\n')
        .trim();
  }

  static int _indentOf(String line) {
    var n = 0;
    while (n < line.length && (line[n] == ' ' || line[n] == '\t')) {
      n++;
    }
    return n;
  }
}
