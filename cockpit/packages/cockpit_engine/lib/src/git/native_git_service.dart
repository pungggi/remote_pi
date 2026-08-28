import 'dart:io';

import 'package:cockpit_core/cockpit_core.dart';

/// [GitService] rodando o binário `git` do host servidor (plano 58, Wave 3).
/// Motor é o git do sistema; nosso é o parser/orquestração — mesmo modelo do
/// `data/filesystem/git_*` do app, agora do lado do servidor.
class NativeGitService implements GitService {
  const NativeGitService();

  @override
  Future<GitStatus> status(String repoPath) async {
    // Mesmas flags do leitor local (`git_status_reader_impl`), para o Source
    // Control remoto se comportar igual ao local:
    // - `-uall`: lista os arquivos untracked UM A UM. Sem isto o git colapsa a
    //   pasta nova numa entrada só (`?? .cockpit/`), e a árvore mostrava a
    //   pasta como se fosse um arquivo.
    // - `--ignored=matching`: as raízes ignoradas vêm como `!!`, para a árvore
    //   saber o que não pintar.
    final result = await _git(repoPath, [
      'status',
      '--porcelain=v1',
      '-b',
      '-z',
      '-uall',
      '--ignored=matching',
    ]);
    final parts = result.split('\x00');
    var branch = '';
    final files = <GitFileStatus>[];
    for (var i = 0; i < parts.length; i++) {
      final entry = parts[i];
      if (entry.isEmpty) continue;
      if (entry.startsWith('## ')) {
        // "## main...origin/main [ahead 1]" → "main"
        branch = entry.substring(3).split('...').first.split(' ').first.trim();
        continue;
      }
      if (entry.length < 3) continue;
      final staged = entry[0];
      // Rename/copy no index: com `-z` o PRÓXIMO token é o caminho de origem,
      // sem os dois chars de status. Sem pular, ele virava uma entrada com o
      // nome cortado nos 3 primeiros caracteres.
      if (staged == 'R' || staged == 'C') i++;
      files.add(
        GitFileStatus(
          staged: staged,
          worktree: entry[1],
          path: entry.substring(3),
        ),
      );
    }
    return GitStatus(branch: branch, files: files);
  }

  @override
  Future<String> diff(String repoPath, String file, {bool staged = false}) =>
      _git(repoPath, ['diff', if (staged) '--cached', '--', file]);

  @override
  Future<void> stage(String repoPath, List<String> files) async {
    await _git(repoPath, ['add', '--', ...files]);
  }

  @override
  Future<void> unstage(String repoPath, List<String> files) async {
    await _git(repoPath, ['restore', '--staged', '--', ...files]);
  }

  @override
  Future<void> commit(String repoPath, String message) async {
    await _git(repoPath, ['commit', '-m', message]);
  }

  @override
  Future<GitRunResult> run(String repoPath, List<String> args) async {
    try {
      final result = await Process.run(
        'git',
        ['-C', repoPath, ...args],
        stdoutEncoding: SystemEncoding(),
        stderrEncoding: SystemEncoding(),
      );
      return GitRunResult(
        code: result.exitCode,
        stdout: result.stdout as String,
        stderr: (result.stderr as String).trim(),
      );
    } on ProcessException catch (e) {
      throw GitException(GitErrorKind.command, e.message);
    }
  }

  Future<String> _git(String repoPath, List<String> args) async {
    final ProcessResult result;
    try {
      result = await Process.run(
        'git',
        ['-C', repoPath, ...args],
        stdoutEncoding: SystemEncoding(),
        stderrEncoding: SystemEncoding(),
      );
    } on ProcessException catch (e) {
      throw GitException(GitErrorKind.command, e.message);
    }
    if (result.exitCode != 0) {
      final stderr = (result.stderr as String).trim();
      final kind = stderr.contains('not a git repository')
          ? GitErrorKind.notARepo
          : GitErrorKind.command;
      throw GitException(kind, stderr);
    }
    return result.stdout as String;
  }
}
