import 'package:cockpit/app/cockpit/domain/entities/git_history_commit.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_history_file_change.dart';

/// Parsers puros do `git log`/`git show` — no dominio porque o caminho local
/// (`GitHistoryReaderImpl`) e o remoto (host via `git.run`, plano 58) alimentam
/// exatamente a mesma saida, entao o parsing nao pode morar na `data/`.
///
/// Os separadores de controle evitam depender de alinhamento, locale ou do
/// desenho textual de `--graph`.
class GitHistoryParser {
  static const _rs = '\u001e';
  static const _fs = '\u001f';

  static List<GitHistoryCommit> parse(String output) {
    final commits = <GitHistoryCommit>[];
    for (final record in output.split(_rs)) {
      if (record.trim().isEmpty) continue;
      // `git log` acrescenta uma quebra de linha apos cada record separator.
      // Sem remove-la do inicio, todo hash apos o primeiro vira uma revisao
      // invalida quando usado em `git show`.
      final fields = record.trim().split(_fs);
      if (fields.length < 6 || fields.first.isEmpty) continue;
      final decorations = fields[2].trim();
      commits.add(
        GitHistoryCommit(
          hash: fields[0],
          parents: fields[1].trim().isEmpty
              ? const []
              : fields[1].trim().split(RegExp(r'\s+')),
          refs: decorations.isEmpty
              ? const []
              : decorations.split(',').map((ref) => ref.trim()).toList(),
          author: fields[3],
          authoredAt: DateTime.tryParse(fields[4]),
          subject: fields.sublist(5).join(_fs),
        ),
      );
    }
    return commits;
  }
}

/// Parser do formato NUL-delimitado de `git show --name-status -z`.
class GitHistoryFileChangeParser {
  static const _nul = '\u0000';

  static List<GitHistoryFileChange> parse(String output) {
    final fields = output.split(_nul);
    final changes = <GitHistoryFileChange>[];
    for (var index = 0; index < fields.length - 1;) {
      final status = fields[index++];
      if (status.isEmpty || index >= fields.length) continue;
      if (status.startsWith('R') || status.startsWith('C')) {
        if (index + 1 >= fields.length) break;
        final previousPath = fields[index++];
        final path = fields[index++];
        changes.add(
          GitHistoryFileChange(
            status: status,
            path: path,
            previousPath: previousPath,
          ),
        );
      } else {
        changes.add(
          GitHistoryFileChange(status: status, path: fields[index++]),
        );
      }
    }
    return changes;
  }
}
