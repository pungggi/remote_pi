import 'dart:convert';

import 'package:cockpit/app/cockpit/domain/contracts/worktree_manager.dart';
import 'package:cockpit_core/cockpit_core.dart';
import 'package:cockpit_remote/cockpit_remote.dart';

/// Uma worktree remota crua (path no host + branch), lida do `git worktree
/// list --porcelain` do host.
class RemoteWorktreeEntry {
  const RemoteWorktreeEntry({required this.path, required this.branch});
  final String path;
  final String branch;
}

/// Operações de worktree num host remoto (plano 58, Camada B). Espelha o
/// [WorktreeManager] local, mas roda tudo via `git.run` no `cockpit-server` do
/// host — não há RPC novo, só sequências de git. O `.gitignore` é lido/escrito
/// pelo serviço de arquivos remoto (o worktree mora em `.cockpit/worktrees/`,
/// que não deve virar mudança rastreada).
class RemoteWorktreeGateway {
  RemoteWorktreeGateway(this._git, this._files);

  final RemoteGitService _git;
  final RemoteFileService _files;

  /// Subpasta (relativa ao repo) onde os worktrees nascem — mesmo layout do
  /// local (`.cockpit/worktrees/<name>`).
  static const worktreesDir = '.cockpit/worktrees';

  /// Worktrees de [repo] **excluindo** a raiz. Vazio se não é repo git.
  Future<List<RemoteWorktreeEntry>> list(String repo) async {
    final r = await _git.run(repo, const ['worktree', 'list', '--porcelain']);
    // Erro (pasta não é repo, conexão) LANÇA — não devolve `[]`: o chamador não
    // pode confundir "sem worktrees" com "falhou" e apagar os forks existentes.
    if (r.code != 0) {
      throw StateError('git worktree list failed (${r.code}): ${r.stderr}');
    }
    return parsePorcelain(r.stdout, repo);
  }

  /// Parser do `git worktree list --porcelain`: blocos separados por linha em
  /// branco, cada um com `worktree <path>` e (se em branch) `branch
  /// refs/heads/<b>`. A raiz [repo] é descartada. Público pra teste.
  static List<RemoteWorktreeEntry> parsePorcelain(String out, String repo) {
    final entries = <RemoteWorktreeEntry>[];
    String? path;
    String? branch;
    void flush() {
      if (path != null && path != repo) {
        entries.add(
          RemoteWorktreeEntry(
            path: path!,
            // detached → usa o basename como rótulo (git não dá branch).
            branch: branch ?? path!.split('/').last,
          ),
        );
      }
      path = null;
      branch = null;
    }

    for (final line in const LineSplitter().convert(out)) {
      if (line.isEmpty) {
        flush();
        continue;
      }
      if (line.startsWith('worktree ')) {
        path = line.substring('worktree '.length).trim();
      } else if (line.startsWith('branch ')) {
        final ref = line.substring('branch '.length).trim();
        branch = ref.startsWith('refs/heads/')
            ? ref.substring('refs/heads/'.length)
            : ref;
      }
    }
    flush();
    return entries;
  }

  /// Branches locais/remotas + nomes de worktree + branch padrão — insumo da
  /// validação do dialog de criar (unicidade + base).
  Future<WorktreeNamespace> namespace(String repo) async {
    final locals = await _git.run(repo, const [
      'branch',
      '--format=%(refname:short)',
    ]);
    final remotes = await _git.run(repo, const [
      'branch',
      '-r',
      '--format=%(refname:short)',
    ]);
    final wts = await list(repo);
    final head = await _git.run(repo, const [
      'symbolic-ref',
      '--quiet',
      '--short',
      'refs/remotes/origin/HEAD',
    ]);
    Set<String> lines(String out) =>
        out.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toSet();
    final defaultBranch = head.code == 0
        ? head.stdout.trim().split('/').last
        : null;
    return WorktreeNamespace(
      branches: locals.code == 0 ? lines(locals.stdout) : const {},
      remoteBranches: remotes.code == 0 ? lines(remotes.stdout) : const {},
      worktreeNames: {for (final w in wts) w.path.split('/').last},
      defaultBranch: defaultBranch,
    );
  }

  /// Cria uma worktree em `<repo>/.cockpit/worktrees/<name>` numa branch nova
  /// [name] (de [baseRef] no fork-of-fork). Garante `.cockpit/worktrees/` no
  /// `.gitignore` antes. Devolve o resultado do `git worktree add`; o caminho
  /// criado é `<repo>/.cockpit/worktrees/<name>`.
  Future<GitRunResult> add(String repo, String name, {String? baseRef}) async {
    await _ensureGitignore(repo);
    final path = '$repo/$worktreesDir/$name';
    return _git.run(repo, [
      'worktree',
      'add',
      path,
      '-b',
      name,
      if (baseRef != null && baseRef.isNotEmpty) baseRef,
    ]);
  }

  /// Caminho absoluto no host de um worktree de nome [name] em [repo].
  static String pathFor(String repo, String name) =>
      '$repo/$worktreesDir/$name';

  /// Remove o worktree em [worktreePath] e, se [branch] não vazio, apaga a
  /// branch (worktree remove ANTES do branch -D, como no local).
  Future<GitRunResult> remove(
    String repo,
    String worktreePath,
    String branch,
  ) async {
    final rm = await _git.run(repo, [
      'worktree',
      'remove',
      '--force',
      worktreePath,
    ]);
    if (rm.code != 0 || branch.isEmpty) return rm;
    return _git.run(repo, ['branch', '-D', branch]);
  }

  /// Mergeia [branch] no checkout de [repo] (o pai). Conflito/erro voltam no
  /// stderr com code ≠ 0.
  Future<GitRunResult> merge(String repo, String branch) =>
      _git.run(repo, ['merge', '--no-edit', branch]);

  /// `true` se [branch] já está mergeada na linha principal de [repo].
  Future<bool> isMerged(String repo, String branch) async {
    final r = await _git.run(repo, const [
      'branch',
      '--merged',
      '--format=%(refname:short)',
    ]);
    if (r.code != 0) return false;
    return r.stdout.split('\n').map((l) => l.trim()).contains(branch);
  }

  /// Garante `.cockpit/worktrees/` no `.gitignore` do repo (best-effort): sem
  /// isso a pasta dos worktrees apareceria como mudança não rastreada.
  Future<void> _ensureGitignore(String repo) async {
    const rule = '$worktreesDir/';
    final path = '$repo/.gitignore';
    String current = '';
    try {
      current = utf8.decode(await _files.read(path), allowMalformed: true);
    } catch (_) {
      // sem .gitignore ainda → cria com a regra.
    }
    final has = const LineSplitter()
        .convert(current)
        .map((l) => l.trim())
        .any((l) => l == rule || l == '/$rule' || l == worktreesDir);
    if (has) return;
    final sep = current.isEmpty || current.endsWith('\n') ? '' : '\n';
    final next = '$current$sep$rule\n';
    try {
      await _files.write(path, utf8.encode(next));
    } catch (_) {
      // Falha ao escrever o .gitignore não impede criar o worktree.
    }
  }
}
