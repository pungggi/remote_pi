import 'dart:io';

import 'package:cockpit_core/cockpit_core.dart';
import 'package:cockpit_engine/cockpit_engine.dart';
import 'package:test/test.dart';

/// Exercita o parser do porcelain=v1 -z contra um repo git de verdade.
void main() {
  late Directory repo;
  const git = NativeGitService();

  setUp(() async {
    repo = await Directory.systemTemp.createTemp('git-svc-');
    Future<void> run(List<String> args) async {
      final r = await Process.run('git', ['-C', repo.path, ...args]);
      if (r.exitCode != 0) throw StateError('git ${args.first}: ${r.stderr}');
    }

    await run(['init', '-q']);
    await run(['config', 'user.email', 't@t']);
    await run(['config', 'user.name', 'T']);
  });

  tearDown(() => repo.delete(recursive: true));

  test('status: untracked → staged → committed', () async {
    File('${repo.path}/a.txt').writeAsStringSync('one\n');

    final untracked = await git.status(repo.path);
    expect(untracked.branch, isNotEmpty);
    expect(untracked.files.singleWhere((f) => f.path == 'a.txt').worktree, '?');

    await git.stage(repo.path, ['a.txt']);
    final staged = await git.status(repo.path);
    expect(staged.files.singleWhere((f) => f.path == 'a.txt').staged, 'A');

    await git.commit(repo.path, 'first');
    expect((await git.status(repo.path)).files, isEmpty);
  });

  test('diff mostra a mudança na worktree', () async {
    File('${repo.path}/a.txt').writeAsStringSync('one\n');
    await git.stage(repo.path, ['a.txt']);
    await git.commit(repo.path, 'first');
    File('${repo.path}/a.txt').writeAsStringSync('one\ntwo\n');

    final diff = await git.diff(repo.path, 'a.txt');
    expect(diff, contains('+two'));
  });

  test('repo inexistente vira GitException(notARepo)', () async {
    final notRepo = await Directory.systemTemp.createTemp('not-git-');
    addTearDown(() => notRepo.delete(recursive: true));
    expect(
      () => git.status(notRepo.path),
      throwsA(
        isA<GitException>().having(
          (e) => e.kind,
          'kind',
          GitErrorKind.notARepo,
        ),
      ),
    );
  });

  test('pasta nova é enumerada arquivo a arquivo (-uall)', () async {
    // Sem `-uall` o git colapsa numa entrada só (`?? .cockpit/`) e o cliente
    // desenhava a pasta como se fosse um arquivo no Source Control.
    Directory('${repo.path}/.cockpit').createSync();
    File('${repo.path}/.cockpit/tasks.json').writeAsStringSync('{}\n');
    File('${repo.path}/.cockpit/databases.json').writeAsStringSync('{}\n');

    final status = await git.status(repo.path);
    final paths = status.files.map((f) => f.path).toSet();
    expect(paths, contains('.cockpit/tasks.json'));
    expect(paths, contains('.cockpit/databases.json'));
    expect(
      paths.any((p) => p.endsWith('/')),
      isFalse,
      reason: 'nenhuma entrada deve ser uma pasta colapsada',
    );
  });

  test('rename não gera entrada fantasma com o nome cortado', () async {
    File('${repo.path}/old.txt').writeAsStringSync('one\n');
    await git.stage(repo.path, ['old.txt']);
    await git.commit(repo.path, 'first');
    File('${repo.path}/old.txt').renameSync('${repo.path}/new.txt');
    await git.stage(repo.path, ['old.txt', 'new.txt']);

    final status = await git.status(repo.path);
    final paths = status.files.map((f) => f.path).toList();
    // Com `-z` o caminho de ORIGEM vem num token próprio; sem pulá-lo, ele
    // virava uma entrada com os 3 primeiros caracteres comidos ("txt").
    expect(paths, ['new.txt']);
    expect(status.files.single.staged, 'R');
  });

  test('pasta ignorada aparece como !! e não como mudança', () async {
    File('${repo.path}/.gitignore').writeAsStringSync('build/\n');
    Directory('${repo.path}/build').createSync();
    File('${repo.path}/build/out.o').writeAsStringSync('x\n');

    final status = await git.status(repo.path);
    final ignored = status.files.where((f) => f.staged == '!').toList();
    expect(ignored, isNotEmpty);
    expect(ignored.first.path, startsWith('build'));
  });
}
