/// Uma nota de um caderno `nome.notebook/` (plano 62, passo 4): um `.md` com
/// frontmatter YAML raso (`title`, `tags`, `created`, `updated`) + corpo
/// markdown. O parser é conservador e **nunca lança**: sem frontmatter, o
/// título vem do nome do arquivo e a nota cai em [kUntagged].
///
/// ```markdown
/// ---
/// title: Túnel SSH no host
/// tags: [relay, agent]
/// created: 2026-09-07T10:12
/// updated: 2026-09-07T11:40
/// ---
///
/// Corpo livre em markdown.
/// ```
library;

/// Tag atribuída pela UI a nota sem tag (decisão N2: toda nota tem ao menos uma).
const String kUntagged = 'untagged';

/// Tag reservada para notas criadas pelo agente (decisão N5).
const String kAgentTag = 'agent';

/// Sufixo de pasta que o Cockpit trata como caderno.
const String kNotebookSuffix = '.notebook';

bool isNotebookFolder(String name) =>
    name.toLowerCase().endsWith(kNotebookSuffix);

class NotebookNote {
  const NotebookNote({
    required this.path,
    required this.title,
    required this.tags,
    required this.body,
    required this.raw,
    this.created,
    this.updated,
  });

  /// Caminho absoluto do `.md`.
  final String path;
  final String title;

  /// Nunca vazio: sem tag no arquivo → `[kUntagged]`.
  final List<String> tags;

  /// Markdown sem o frontmatter.
  final String body;

  /// Conteúdo integral do arquivo (o que o editor cru mostra).
  final String raw;
  final DateTime? created;
  final DateTime? updated;

  String get fileName => path.split('/').last;

  bool get fromAgent => tags.contains(kAgentTag);

  /// Ordenação da lista: mais recente primeiro; sem data vai pro fim.
  DateTime? get sortDate => updated ?? created;

  static final _fence = RegExp(r'^---\s*$');
  static final _kv = RegExp(r'^([A-Za-z_][\w-]*)\s*:\s*(.*?)\s*$');

  /// Parse do conteúdo integral [raw] do arquivo em [path].
  static NotebookNote parse(String path, String raw) {
    final lines = raw.split('\n');
    final fields = <String, String>{};
    var body = raw;
    if (lines.isNotEmpty && _fence.hasMatch(lines.first)) {
      var end = -1;
      for (var i = 1; i < lines.length; i++) {
        if (_fence.hasMatch(lines[i])) {
          end = i;
          break;
        }
        final m = _kv.firstMatch(lines[i]);
        if (m != null) fields[m.group(1)!.toLowerCase()] = m.group(2)!;
      }
      if (end > 0) {
        body = lines.sublist(end + 1).join('\n');
        if (body.startsWith('\n')) body = body.substring(1);
      } else {
        fields.clear(); // fence sem fechamento = não é frontmatter
      }
    }
    final fileName = path.split('/').last;
    final stem = fileName.endsWith('.md')
        ? fileName.substring(0, fileName.length - 3)
        : fileName;
    final title = _unquote(fields['title'] ?? '').trim();
    var tags = _parseList(fields['tags'] ?? '');
    if (tags.isEmpty) tags = const [kUntagged];
    return NotebookNote(
      path: path,
      title: title.isEmpty ? stem : title,
      tags: tags,
      body: body,
      raw: raw,
      created: _parseDate(fields['created']),
      updated: _parseDate(fields['updated']),
    );
  }

  /// Conteúdo inicial de uma nota nova.
  static String template({
    required String title,
    required List<String> tags,
    required DateTime now,
    String body = '',
  }) {
    final stamp = _stamp(now);
    final t = tags.isEmpty ? const [kUntagged] : tags;
    return '---\n'
        'title: ${_quoteIfNeeded(title)}\n'
        'tags: [${t.join(', ')}]\n'
        'created: $stamp\n'
        'updated: $stamp\n'
        '---\n'
        '\n'
        '$body';
  }

  /// Nome de arquivo a partir do título: `2026-09-07-tunel-ssh.md`.
  static String fileNameFor(String title, DateTime now) {
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r'[àáâãä]'), 'a')
        .replaceAll(RegExp(r'[èéêë]'), 'e')
        .replaceAll(RegExp(r'[ìíîï]'), 'i')
        .replaceAll(RegExp(r'[òóôõö]'), 'o')
        .replaceAll(RegExp(r'[ùúûü]'), 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final date = _stamp(now).substring(0, 10);
    return '$date-${slug.isEmpty ? 'note' : slug}.md';
  }

  /// Substitui (ou insere) a linha `tags:` do frontmatter de [raw]. Sem
  /// frontmatter, cria um só com `tags:`. Lista vazia grava `[]` (a UI mostra
  /// como sem tag).
  static String setTags(String raw, List<String> tags) {
    final clean = tags
        .map((t) => t.trim().toLowerCase())
        .where((t) => t.isNotEmpty)
        .toSet();
    return _setField(raw, 'tags', '[${clean.join(', ')}]');
  }

  /// Substitui (ou insere) `title:` no frontmatter de [raw]. O nome do
  /// arquivo não muda — o título é só metadado.
  static String setTitle(String raw, String title) =>
      _setField(raw, 'title', _quoteIfNeeded(title.trim()));

  static String _setField(String raw, String key, String value) {
    final line = '$key: $value';
    final lines = raw.split('\n');
    if (lines.isEmpty || !_fence.hasMatch(lines.first)) {
      return '---\n$line\n---\n\n$raw';
    }
    for (var i = 1; i < lines.length; i++) {
      if (_fence.hasMatch(lines[i])) {
        lines.insert(i, line);
        return lines.join('\n');
      }
      if (lines[i].toLowerCase().startsWith('$key:')) {
        lines[i] = line;
        return lines.join('\n');
      }
    }
    return '---\n$line\n---\n\n$raw';
  }

  /// Troca o corpo de [raw] por [body], preservando o frontmatter byte a byte.
  /// Sem frontmatter, [body] vira o arquivo inteiro.
  static String replaceBody(String raw, String body) {
    final lines = raw.split('\n');
    if (lines.isEmpty || !_fence.hasMatch(lines.first)) return body;
    for (var i = 1; i < lines.length; i++) {
      if (_fence.hasMatch(lines[i])) {
        final head = lines.sublist(0, i + 1).join('\n');
        return '$head\n\n$body';
      }
    }
    return body;
  }

  /// Substitui (ou insere) `updated:` no frontmatter de [raw].
  static String touchUpdated(String raw, DateTime now) {
    final lines = raw.split('\n');
    if (lines.isEmpty || !_fence.hasMatch(lines.first)) return raw;
    for (var i = 1; i < lines.length; i++) {
      if (_fence.hasMatch(lines[i])) {
        lines.insert(i, 'updated: ${_stamp(now)}');
        return lines.join('\n');
      }
      if (lines[i].toLowerCase().startsWith('updated:')) {
        lines[i] = 'updated: ${_stamp(now)}';
        return lines.join('\n');
      }
    }
    return raw;
  }

  static String _stamp(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}T${two(d.hour)}:${two(d.minute)}';
  }

  static List<String> _parseList(String v) {
    var s = v.trim();
    if (s.startsWith('[') && s.endsWith(']')) s = s.substring(1, s.length - 1);
    return s
        .split(',')
        .map((e) => _unquote(e).trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static DateTime? _parseDate(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    return DateTime.tryParse(_unquote(v).trim());
  }

  /// Tira aspas simples/duplas; em aspas duplas, desfaz `\\n` e `\\"` (é como
  /// [_quoteIfNeeded] grava título com quebra de linha).
  static String _unquote(String v) {
    final s = v.trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      return s
          .substring(1, s.length - 1)
          .replaceAll('\\n', '\n')
          .replaceAll('\\"', '"');
    }
    if (s.length >= 2 && s.startsWith("'") && s.endsWith("'")) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  /// Aspas duplas quando o valor tem `:`/`#` (YAML) ou quebra de linha — a
  /// quebra vira `\\n` pra o frontmatter continuar com uma linha por chave.
  static String _quoteIfNeeded(String v) {
    if (!v.contains(':') && !v.contains('#') && !v.contains('\n')) return v;
    final esc = v.replaceAll('"', '\\"').replaceAll('\n', '\\n');
    return '"$esc"';
  }
}
