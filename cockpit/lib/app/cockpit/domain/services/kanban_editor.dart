import 'package:cockpit/app/cockpit/domain/entities/kanban_document.dart';

/// Mutações de um `.kanban`. Cada operação devolve o **conteúdo novo** do
/// arquivo; quem chamou grava e reparseia.
///
/// A regra que sustenta o formato: nada aqui reserializa o documento. Toda
/// operação é uma emenda sobre `doc.lines` — recorta o intervalo de linhas do
/// card (ou da coluna) e reinsere noutro ponto. É o que faz um arraste virar
/// um diff de três linhas no git em vez de reescrever o arquivo, e o que deixa
/// markdown que o parser não modela sobreviver intacto.
///
/// Operações compostas (apagar coluna movendo os cards) rodam em etapas,
/// reparseando entre elas — arquivo de kanban é pequeno, e assim cada etapa
/// enxerga índices sempre válidos.
abstract final class KanbanEditor {
  // ------------------------------------------------------------ cards ------

  /// Move [card] para o fim de [toColumn] (ou antes do card de índice
  /// [atIndex], quando informado). Sincroniza o `[x]`: estar na última coluna
  /// **é** estar concluído.
  static String moveCard(
    KanbanDocument doc,
    KanbanCard card,
    int toColumn, {
    int? atIndex,
  }) {
    if (toColumn < 0 || toColumn >= doc.columns.length) return doc.content;
    final target = doc.columns[toColumn];
    final lines = [...doc.lines];

    // O separador em branco viaja junto com o card: sem isso, mover deixa uma
    // linha em branco órfã na origem e cola dois cards no destino.
    var end = card.endLine;
    if (end < lines.length && lines[end].trim().isEmpty) end++;
    final block = lines.sublist(card.startLine, end);

    if (card.recognized) {
      block[0] = _headerLine(
        card,
        checked: toColumn == doc.columns.length - 1,
        id: card.id ?? _newId(doc),
      );
    }
    if (block.last.trim().isNotEmpty) block.add('');

    var insertAt = atIndex != null && atIndex < target.cards.length
        ? target.cards[atIndex].startLine
        : _appendPoint(doc, target);

    lines.removeRange(card.startLine, end);
    if (insertAt > card.startLine) insertAt -= (end - card.startLine);
    insertAt = insertAt.clamp(0, lines.length);
    lines.insertAll(insertAt, block);
    return lines.join(doc.eol);
  }

  /// Empurra o card uma coluna adiante. Na última, volta uma — o mesmo botão
  /// desfaz, em vez de esconder o retorno num menu.
  static String advanceCard(KanbanDocument doc, KanbanCard card) {
    final from = _columnOf(doc, card);
    if (from < 0) return doc.content;
    final isLast = from == doc.columns.length - 1;
    final to = isLast ? from - 1 : from + 1;
    if (to < 0) return doc.content;
    return moveCard(doc, card, to);
  }

  /// Manda o card direto pra última coluna, pulando as intermediárias. Na
  /// última coluna não faz nada (o "desfazer" continua sendo o toque curto).
  static String advanceToEnd(KanbanDocument doc, KanbanCard card) {
    final from = _columnOf(doc, card);
    final last = doc.columns.length - 1;
    if (from < 0 || from >= last) return doc.content;
    return moveCard(doc, card, last);
  }

  /// Cria um card no fim de [column] com [title] e devolve o conteúdo novo.
  static String addCard(KanbanDocument doc, int column, String title) {
    if (column < 0 || column >= doc.columns.length) return doc.content;
    final lines = [...doc.lines];
    final checked = column == doc.columns.length - 1;
    final line =
        '- [${checked ? 'x' : ' '}] ${title.trim()} '
        '<!-- id: ${_newId(doc)} -->';
    final at = _appendPoint(doc, doc.columns[column]).clamp(0, lines.length);
    lines.insertAll(at, [line, '']);
    return lines.join(doc.eol);
  }

  static String deleteCard(KanbanDocument doc, KanbanCard card) {
    final lines = [...doc.lines];
    var end = card.endLine;
    if (end < lines.length && lines[end].trim().isEmpty) end++;
    lines.removeRange(card.startLine, end);
    return lines.join(doc.eol);
  }

  static String duplicateCard(KanbanDocument doc, KanbanCard card) {
    final lines = [...doc.lines];
    final block = [...lines.sublist(card.startLine, card.endLine)];
    if (card.recognized) {
      block[0] = _headerLine(card, checked: card.checked, id: _newId(doc));
    }
    lines.insertAll(card.endLine, [...block, '']);
    return lines.join(doc.eol);
  }

  static String setCardTitle(
    KanbanDocument doc,
    KanbanCard card,
    String title,
  ) {
    if (!card.recognized) return doc.content;
    final trimmed = title.trim();
    if (trimmed.isEmpty) return doc.content;
    final lines = [...doc.lines];
    lines[card.startLine] = _headerLine(
      card,
      checked: card.checked,
      id: card.id ?? _newId(doc),
      title: trimmed,
    );
    return lines.join(doc.eol);
  }

  /// Reescreve a nota do card, indentada em 6 espaços (alinhada sob o título).
  static String setCardNotes(
    KanbanDocument doc,
    KanbanCard card,
    String notes,
  ) {
    if (!card.recognized) return doc.content;
    final lines = [...doc.lines];
    final body = notes.trim();
    final replacement = body.isEmpty
        ? <String>[]
        : body.split('\n').map((l) => l.isEmpty ? '' : '      $l').toList();
    // Só o intervalo da NOTA: os comentários vivem depois dela, no mesmo card.
    lines.replaceRange(card.startLine + 1, card.notesEndLine, replacement);
    return lines.join(doc.eol);
  }

  /// Liga/desliga [label] no card.
  static String toggleLabel(KanbanDocument doc, KanbanCard card, String label) {
    if (!card.recognized) return doc.content;
    final labels = [...card.labels];
    labels.contains(label) ? labels.remove(label) : labels.add(label);
    final lines = [...doc.lines];
    lines[card.startLine] = _headerLine(
      card,
      checked: card.checked,
      id: card.id ?? _newId(doc),
      labels: labels,
    );
    return lines.join(doc.eol);
  }

  /// Define quem bloqueia [card]: [blockers] são os cards escolhidos (todos
  /// ganham id se ainda não têm — a referência é por id). Lista vazia limpa.
  static String setBlockedBy(
    KanbanDocument doc,
    KanbanCard card,
    List<KanbanCard> blockers,
  ) {
    if (!card.recognized) return doc.content;
    final lines = [...doc.lines];
    final used = doc.columns
        .expand((c) => c.cards)
        .map((c) => c.id)
        .whereType<String>()
        .toSet();
    String ensureId(KanbanCard c) {
      if (c.id case final id?) return id;
      final id = _nextId(used);
      lines[c.startLine] = _headerLine(c, checked: c.checked, id: id);
      return id;
    }

    final ids = <String>[];
    for (final b in blockers) {
      if (b.startLine == card.startLine) continue; // não bloqueia a si mesmo
      final id = ensureId(b);
      if (!ids.contains(id)) ids.add(id);
    }
    lines[card.startLine] = _headerLine(
      card,
      checked: card.checked,
      id: ensureId(card),
      blockedBy: ids,
    );
    return lines.join(doc.eol);
  }

  // ----------------------------------------------------------- colunas -----

  static String addColumn(KanbanDocument doc, String name) {
    final lines = [...doc.lines];
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    lines.addAll(['', '## ${name.trim()}', '']);
    return lines.join(doc.eol);
  }

  static String renameColumn(KanbanDocument doc, int index, String name) {
    if (index < 0 || index >= doc.columns.length) return doc.content;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return doc.content;
    final lines = [...doc.lines];
    lines[doc.columns[index].headingLine] = '## $trimmed';
    return lines.join(doc.eol);
  }

  /// Troca a coluna [index] de lugar com a vizinha em [delta] (-1 / +1).
  static String moveColumn(KanbanDocument doc, int index, int delta) {
    final other = index + delta;
    if (index < 0 || index >= doc.columns.length) return doc.content;
    if (other < 0 || other >= doc.columns.length) return doc.content;

    final first = doc.columns[index < other ? index : other];
    final second = doc.columns[index < other ? other : index];
    final lines = [...doc.lines];
    final firstBlock = lines.sublist(first.headingLine, first.endLine);
    final secondBlock = lines.sublist(second.headingLine, second.endLine);

    lines.replaceRange(first.headingLine, second.endLine, [
      ...secondBlock,
      ...firstBlock,
    ]);
    return lines.join(doc.eol);
  }

  /// Apaga a coluna [index]. Com [moveCardsToPrevious], os cards vão para a
  /// coluna anterior antes da remoção — a chamada precisa dizer o destino, o
  /// menu nunca decide isso sozinho.
  static String deleteColumn(
    KanbanDocument doc,
    int index, {
    required bool moveCardsToPrevious,
  }) {
    if (index < 0 || index >= doc.columns.length) return doc.content;

    if (moveCardsToPrevious && index > 0) {
      var current = doc;
      // Move sempre o primeiro card restante: cada passo reparseia, então os
      // índices seguintes continuam válidos.
      while (true) {
        final column = current.columns.length > index
            ? current.columns[index]
            : null;
        if (column == null || column.cards.isEmpty) break;
        current = KanbanDocument.parse(
          moveCard(current, column.cards.first, index - 1),
        );
      }
      return deleteColumn(current, index, moveCardsToPrevious: false);
    }

    final column = doc.columns[index];
    final lines = [...doc.lines];
    lines.removeRange(column.headingLine, column.endLine);
    return lines.join(doc.eol);
  }

  /// Acrescenta um comentário ao card. Entra no TOPO da conversa (logo após a
  /// nota), que é onde ele será lido primeiro — a ordem do arquivo passa a ser
  /// a ordem de leitura, sem ninguém precisar ordenar por data.
  static String addComment(
    KanbanDocument doc,
    KanbanCard card,
    String text, {
    DateTime? now,
  }) {
    if (!card.recognized) return doc.content;
    final body = text.trim();
    if (body.isEmpty) return doc.content;

    final stamp = (now ?? DateTime.now()).toIso8601String().substring(0, 16);
    final block = <String>[
      '      <!-- comment: $stamp -->',
      ...body.split('\n').map((l) => l.isEmpty ? '' : '      $l'),
      '',
    ];

    final lines = [...doc.lines];
    lines.insertAll(card.notesEndLine, block);
    return lines.join(doc.eol);
  }

  /// Remove um comentário do card.
  static String deleteComment(
    KanbanDocument doc,
    KanbanCard card,
    KanbanComment comment,
  ) {
    final lines = [...doc.lines];
    lines.removeRange(comment.startLine, comment.endLine);
    return lines.join(doc.eol);
  }

  // ------------------------------------------------------------ quadro -----

  /// Grava (ou apaga, com `null`/vazio) o `title:` do frontmatter — o nome que
  /// a aba exibe. Reusa a mesma emenda dos marcadores: linha existente é
  /// substituída, senão entra antes do `---` de fechamento; sem frontmatter,
  /// um é criado no topo.
  static String setBoardTitle(KanbanDocument doc, String? title) {
    final value = title?.trim();
    return _writeFrontmatterLine(
      doc,
      key: 'title',
      line: (value == null || value.isEmpty) ? null : 'title: $value',
    );
  }

  // -------------------------------------------------------- marcadores -----

  /// Cria ou recolore um marcador no frontmatter.
  static String upsertLabel(
    KanbanDocument doc,
    String name,
    KanbanLabelColor color,
  ) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return doc.content;
    final colors = {...doc.labelColors, trimmed: color};
    return _writeLabelColors(doc, colors);
  }

  /// Remove o marcador do frontmatter **e** de todos os cards que o usam.
  static String deleteLabel(KanbanDocument doc, String name) {
    var current = doc;
    while (true) {
      final card = current.columns
          .expand((c) => c.cards)
          .where((c) => c.labels.contains(name))
          .firstOrNull;
      if (card == null) break;
      current = KanbanDocument.parse(toggleLabel(current, card, name));
    }
    final colors = {...current.labelColors}..remove(name);
    return _writeLabelColors(current, colors);
  }

  static String _writeLabelColors(
    KanbanDocument doc,
    Map<String, KanbanLabelColor> colors,
  ) => _writeFrontmatterLine(
    doc,
    key: 'labels',
    line: colors.isEmpty
        ? null
        : 'labels: {${colors.entries.map((e) => '${e.key}: ${e.value.name}').join(', ')}}',
  );

  /// Escreve [line] como a entrada `key:` do frontmatter. `null` apaga a
  /// entrada. Sem frontmatter, cria um no topo (a menos que não haja o que
  /// escrever).
  static String _writeFrontmatterLine(
    KanbanDocument doc, {
    required String key,
    required String? line,
  }) {
    final lines = [...doc.lines];
    final pattern = RegExp('^$key:');

    if (doc.frontmatterEnd > 0) {
      final at = lines.indexWhere(pattern.hasMatch);
      if (at >= 0 && at < doc.frontmatterEnd) {
        if (line == null) {
          lines.removeAt(at);
        } else {
          lines[at] = line;
        }
      } else if (line != null) {
        lines.insert(doc.frontmatterEnd - 1, line);
      }
      return lines.join(doc.eol);
    }

    if (line == null) return doc.content;
    lines.insertAll(0, ['---', line, '---', '']);
    return lines.join(doc.eol);
  }

  // ---------------------------------------------------------- internos -----

  /// Reconstrói a linha de cabeçalho do card preservando o que não mudou.
  static String _headerLine(
    KanbanCard card, {
    required bool checked,
    required String id,
    String? title,
    List<String>? labels,
    List<String>? blockedBy,
  }) {
    final effectiveLabels = labels ?? card.labels;
    final effectiveBlockedBy = blockedBy ?? card.blockedBy;
    final meta = StringBuffer('<!-- id: $id');
    if (effectiveLabels.isNotEmpty) {
      meta.write(' labels: ${effectiveLabels.join(', ')}');
    }
    if (effectiveBlockedBy.isNotEmpty) {
      meta.write(' blockedBy: ${effectiveBlockedBy.join(', ')}');
    }
    meta.write(' -->');
    return '- [${checked ? 'x' : ' '}] ${title ?? card.title} $meta';
  }

  /// Onde inserir um card no fim de [column]: depois da última linha com
  /// conteúdo, antes das brancas que separam da próxima coluna.
  static int _appendPoint(KanbanDocument doc, KanbanColumn column) {
    var at = column.endLine;
    while (at > column.headingLine + 1 && doc.lines[at - 1].trim().isEmpty) {
      at--;
    }
    return at;
  }

  static int _columnOf(KanbanDocument doc, KanbanCard card) {
    for (var i = 0; i < doc.columns.length; i++) {
      if (doc.columns[i].cards.any((c) => c.startLine == card.startLine)) {
        return i;
      }
    }
    return -1;
  }

  /// Id curto e único no documento. Nasce na primeira mutação pela UI — o
  /// arquivo escrito à mão não precisa de nenhum.
  static String _newId(KanbanDocument doc) => _nextId(
    doc.columns
        .expand((c) => c.cards)
        .map((c) => c.id)
        .whereType<String>()
        .toSet(),
  );

  /// Primeiro `kN` livre em [used]; registra o id escolhido no conjunto, pra
  /// várias atribuições na mesma edição não colidirem.
  static String _nextId(Set<String> used) {
    for (var n = 1; ; n++) {
      final id = 'k$n';
      if (used.add(id)) return id;
    }
  }
}
