import 'dart:io';

import 'package:cockpit/app/cockpit/data/filesystem/git_binary.dart';
import 'package:cockpit/app/cockpit/domain/contracts/git_history_reader.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_history_commit.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_history_file_change.dart';
import 'package:cockpit/app/cockpit/domain/exceptions/git_history_error.dart';
import 'package:cockpit/app/cockpit/domain/git_history_parsers.dart';
import 'package:cockpit/app/core/data/setup/remote_pi_resolver.dart';
import 'package:cockpit/app/core/domain/result.dart';

// Os parsers moraram aqui; migraram pro dominio (compartilhados com o caminho
// remoto, plano 58). Reexporta pra nao quebrar quem importava daqui (testes).
export 'package:cockpit/app/cockpit/domain/git_history_parsers.dart';

/// Leitor estruturado do `git log`; os separadores de controle evitam depender
/// de alinhamento, locale ou do desenho textual de `--graph`.
class GitHistoryReaderImpl implements GitHistoryReader {
  GitHistoryReaderImpl(this._gitBinary);

  final GitBinary _gitBinary;

  @override
  Future<Result<List<GitHistoryCommit>, GitHistoryError>> read(
    String repoPath, {
    int limit = 100,
  }) async {
    try {
      final git = await _gitBinary.resolve();
      final result = await Process.run(git, [
        '-C',
        repoPath,
        'log',
        '-n',
        '$limit',
        '--decorate=short',
        '--date=iso-strict',
        '--format=%H%x1f%P%x1f%D%x1f%an%x1f%aI%x1f%s%x1e',
      ], environment: await envWithNodeOnPath());
      if (result.exitCode != 0) {
        return Failure(
          GitHistoryError(
            GitHistoryErrorKind.commandFailed,
            detail: result.stderr.toString().trim(),
          ),
        );
      }
      return Success(GitHistoryParser.parse(result.stdout.toString()));
    } on ProcessException catch (error) {
      return Failure(
        GitHistoryError(
          GitHistoryErrorKind.commandFailed,
          detail: error.message,
        ),
      );
    }
  }

  @override
  Future<Result<List<GitHistoryFileChange>, GitHistoryError>> readFiles(
    String repoPath,
    String commitHash,
  ) async {
    try {
      final git = await _gitBinary.resolve();
      final result = await Process.run(git, [
        '-C',
        repoPath,
        'show',
        '--format=',
        '--name-status',
        '-z',
        '--find-renames',
        '--first-parent',
        commitHash,
        '--',
      ], environment: await envWithNodeOnPath());
      if (result.exitCode != 0) {
        return Failure(
          GitHistoryError(
            GitHistoryErrorKind.commandFailed,
            detail: result.stderr.toString().trim(),
          ),
        );
      }
      return Success(
        GitHistoryFileChangeParser.parse(result.stdout.toString()),
      );
    } on ProcessException catch (error) {
      return Failure(
        GitHistoryError(
          GitHistoryErrorKind.commandFailed,
          detail: error.message,
        ),
      );
    }
  }
}
