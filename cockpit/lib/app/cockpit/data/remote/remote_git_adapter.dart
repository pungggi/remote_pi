import 'package:cockpit/app/cockpit/domain/entities/git_file_status.dart'
    as app;
import 'package:cockpit/app/cockpit/domain/entities/git_info.dart';
import 'package:cockpit_core/cockpit_core.dart' as core;

/// Converte o `GitStatus` do protocolo (porcelain XY) no `GitInfo` do app
/// (branch + mapas de status por caminho relativo), pra o painel de Source
/// Control funcionar igual ao git local (plano 58, source control remoto).
GitInfo remoteGitInfo(core.GitStatus status) {
  final files = <String, app.GitFileStatus>{};
  final stagedFiles = <String, app.GitFileStatus>{};
  final changedFiles = <String, app.GitFileStatus>{};
  final untrackedDirs = <String>{};
  final ignored = <String>{};

  for (final f in status.files) {
    final x = f.staged; // index
    final y = f.worktree; // working tree
    // O porcelain marca PASTA colapsada com barra final (`?? .cockpit/`).
    // Servidor atualizado manda `-uall` e não colapsa mais, mas host com
    // servidor antigo continua mandando — e guardar a chave COM a barra fazia
    // a árvore do Source Control desenhar a pasta como se fosse um arquivo.
    final isDir = f.path.endsWith('/');
    final path = isDir ? f.path.substring(0, f.path.length - 1) : f.path;
    if (path.isEmpty) continue;

    // Raiz ignorada (`!!`, com `--ignored=matching`): cobre os descendentes e
    // NÃO é mudança — sem este ramo ela cairia como "staged" logo abaixo.
    if (x == '!' && y == '!') {
      ignored.add(path);
      continue;
    }

    if (_isConflict(x, y)) {
      files[path] = app.GitFileStatus.conflict;
      changedFiles[path] = app.GitFileStatus.conflict;
      continue;
    }
    if (x == '?' && y == '?') {
      // Untracked. O porcelain -z já lista pastas untracked colapsadas com
      // barra final; guardamos a raiz pra tingir os descendentes.
      final u = app.GitFileStatus.untracked;
      files[path] = u;
      changedFiles[path] = u;
      // Pasta colapsada: guarda a raiz pra tingir os descendentes, que o git
      // não enumerou (só acontece com servidor antigo, sem `-uall`).
      if (isDir) untrackedDirs.add(path);
      continue;
    }

    app.GitFileStatus? strongest;
    if (x != ' ' && x != '?') {
      final s = x == 'D' ? app.GitFileStatus.deleted : app.GitFileStatus.staged;
      stagedFiles[path] = s;
      strongest = app.GitFileStatus.strongest(strongest, s);
    }
    if (y != ' ' && y != '?') {
      final c = y == 'D'
          ? app.GitFileStatus.deleted
          : app.GitFileStatus.modified;
      changedFiles[path] = c;
      strongest = app.GitFileStatus.strongest(strongest, c);
    }
    if (strongest != null) files[path] = strongest;
  }

  return GitInfo(
    branch: status.branch,
    files: files,
    stagedFiles: stagedFiles,
    changedFiles: changedFiles,
    untrackedDirs: untrackedDirs,
    ignored: ignored,
  );
}

bool _isConflict(String x, String y) =>
    x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D');
