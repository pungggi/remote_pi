/// Estado de um arquivo no `git status` (porcelain v1, dois chars XY).
class GitFileStatus {
  const GitFileStatus({
    required this.path,
    required this.staged,
    required this.worktree,
  });

  final String path;

  /// Código do index (X) e da worktree (Y): 'M','A','D','R','?',' ' etc.
  final String staged;
  final String worktree;

  Map<String, Object?> toJson() => {'p': path, 'x': staged, 'y': worktree};

  factory GitFileStatus.fromJson(Map<String, Object?> j) => GitFileStatus(
    path: j['p'] as String,
    staged: j['x'] as String,
    worktree: j['y'] as String,
  );
}

class GitStatus {
  const GitStatus({required this.branch, required this.files});

  final String branch;
  final List<GitFileStatus> files;

  Map<String, Object?> toJson() => {
    'branch': branch,
    'files': [for (final f in files) f.toJson()],
  };

  factory GitStatus.fromJson(Map<String, Object?> j) => GitStatus(
    branch: j['branch'] as String,
    files: [
      for (final f in (j['files'] as List).cast<Map>())
        GitFileStatus.fromJson(f.cast<String, Object?>()),
    ],
  );
}

enum GitErrorKind { notARepo, command }

class GitException implements Exception {
  const GitException(this.kind, [this.detail]);
  final GitErrorKind kind;

  /// stderr cru do binário `git` — exibido interpolado, nunca traduzido.
  final String? detail;

  @override
  String toString() => 'GitException(${kind.name}: $detail)';
}

/// Git do servidor: roda o binário `git` no host que serve (plano 58, Wave 3).
/// [repoPath] é a raiz do repositório no filesystem remoto.
/// Saída crua de `git <args>` (exit code + streams), pro escape hatch [GitService.run].
class GitRunResult {
  const GitRunResult({
    required this.code,
    required this.stdout,
    required this.stderr,
  });

  final int code;
  final String stdout;
  final String stderr;

  Map<String, Object?> toJson() => {
    'code': code,
    'stdout': stdout,
    'stderr': stderr,
  };

  factory GitRunResult.fromJson(Map<String, Object?> j) => GitRunResult(
    code: (j['code'] as num?)?.toInt() ?? -1,
    stdout: j['stdout'] as String? ?? '',
    stderr: j['stderr'] as String? ?? '',
  );
}

abstract interface class GitService {
  Future<GitStatus> status(String repoPath);

  /// Diff unificado de um arquivo (staged ou worktree).
  Future<String> diff(String repoPath, String file, {bool staged = false});

  Future<void> stage(String repoPath, List<String> files);
  Future<void> unstage(String repoPath, List<String> files);
  Future<void> commit(String repoPath, String message);

  /// Roda `git <args>` cru no repo e devolve (code, stdout, stderr) SEM lançar
  /// em exit ≠ 0 — escape hatch para operações sem método dedicado (log/show/
  /// restore/rm/amend). O cliente parseia a saída com os parsers que já tem.
  Future<GitRunResult> run(String repoPath, List<String> args);
}
