/// Plan/123 — one `## [...]` entry parsed from the bundled CHANGELOG.md,
/// shown in Settings → About → What's new.
class ChangelogEntry {
  const ChangelogEntry({required this.title, required this.body});

  /// Raw header text after the leading `## ` — e.g.
  /// `[Unreleased] — PC mesh foundation` or `[1.1.0] - 2026-06-12`.
  final String title;

  /// Markdown body between this header and the next `## ` (the `### Added`
  /// subsections, bullets, code). Rendered with `AgentMarkdown`.
  final String body;

  @override
  String toString() => 'ChangelogEntry($title)';
}

/// Parse a Keep-a-Changelog markdown blob into version entries, **newest
/// first** (file order). The preamble (title + intro, before the first
/// `## `) is dropped. Only level-2 headers (`## `) start a new entry; deeper
/// headers (`### Added` etc.) stay inside the body they belong to.
///
/// [limit] caps how many entries are returned (default 5) so the "What's new"
/// page stays scannable on a phone.
List<ChangelogEntry> parseChangelog(String md, {int limit = 5}) {
  final lines = md.split('\n');
  final entries = <ChangelogEntry>[];
  String? title;
  final body = <String>[];
  for (final line in lines) {
    if (line.startsWith('## ')) {
      if (title != null) {
        entries.add(ChangelogEntry(title: title, body: body.join('\n').trim()));
      }
      title = line.substring(3).trim();
      body.clear();
    } else if (title != null) {
      body.add(line);
    }
  }
  if (title != null) {
    entries.add(ChangelogEntry(title: title, body: body.join('\n').trim()));
  }
  return entries.take(limit).toList();
}
