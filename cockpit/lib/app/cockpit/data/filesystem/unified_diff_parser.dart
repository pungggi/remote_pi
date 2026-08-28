import 'package:cockpit/app/cockpit/domain/entities/file_diff.dart';

final RegExp _hunkHeader = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');

/// Parseia um unified diff (`git diff`) em hunks, inferindo se é
/// novo/deletado pelos marcadores `--- /dev/null` / `+++ /dev/null`.
/// Compartilhado pelo leitor local ([GitDiffReaderImpl]) e pelo diff remoto.
(List<DiffHunk>, FileDiffKind) parseUnifiedDiff(String out) {
  final hunks = <DiffHunk>[];
  var kind = FileDiffKind.modified;
  DiffHunk? current;
  var oldNo = 0;
  var newNo = 0;
  List<DiffLine> lines = [];

  void flush() {
    final c = current;
    if (c != null) hunks.add(DiffHunk(header: c.header, lines: lines));
  }

  for (final line in out.split('\n')) {
    if (line.startsWith('--- ')) {
      if (line.startsWith('--- /dev/null')) kind = FileDiffKind.added;
      continue;
    }
    if (line.startsWith('+++ ')) {
      if (line.startsWith('+++ /dev/null')) kind = FileDiffKind.deleted;
      continue;
    }
    if (line.startsWith('diff --git') ||
        line.startsWith('index ') ||
        line.startsWith('new file') ||
        line.startsWith('deleted file') ||
        line.startsWith('similarity ') ||
        line.startsWith('rename ')) {
      continue;
    }
    final m = _hunkHeader.firstMatch(line);
    if (m != null) {
      flush();
      oldNo = int.parse(m.group(1)!);
      newNo = int.parse(m.group(2)!);
      lines = [];
      current = DiffHunk(header: line, lines: lines);
      continue;
    }
    if (current == null) continue;
    if (line.startsWith(r'\')) continue; // "\ No newline at end of file"
    if (line.startsWith('+')) {
      lines.add(
        DiffLine(
          kind: DiffLineKind.added,
          text: line.substring(1),
          newLine: newNo++,
        ),
      );
    } else if (line.startsWith('-')) {
      lines.add(
        DiffLine(
          kind: DiffLineKind.removed,
          text: line.substring(1),
          oldLine: oldNo++,
        ),
      );
    } else if (line.startsWith(' ')) {
      lines.add(
        DiffLine(
          kind: DiffLineKind.context,
          text: line.substring(1),
          oldLine: oldNo++,
          newLine: newNo++,
        ),
      );
    }
  }
  flush();
  return (hunks, kind);
}

bool unifiedDiffLooksBinary(String diffOut) =>
    RegExp(r'^Binary files .* differ$', multiLine: true).hasMatch(diffOut);
