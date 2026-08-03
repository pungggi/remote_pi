import 'dart:io';

import 'package:cockpit/app/cockpit/data/layout/ckp_layout_loader.dart';
import 'package:cockpit/app/cockpit/domain/entities/layout_spec.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ckp_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> write(String yaml, {String name = 'dev.ckp'}) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsString(yaml);
    return f.path;
  }

  Future<LayoutSpec> loadOk(String path, {String os = 'macos'}) async {
    final res = await CkpLayoutLoader(hostOs: os).load(path);
    return switch (res) {
      Success(:final value) => value,
      Failure(:final error) => fail('expected success, got: $error'),
    };
  }

  Future<String> loadErr(String path) async {
    final res = await const CkpLayoutLoader().load(path);
    return switch (res) {
      Failure(:final error) => error,
      Success() => fail('expected failure'),
    };
  }

  test('layout completo: nome do arquivo, autorun, panes', () async {
    final path = await write('''
autorun: worktree
panes:
  - name: Frontend
    cwd: frontend
    command: claude
  - name: Backend
    cwd: backend
    split: right
    command: npm run dev
''');
    final spec = await loadOk(path);
    expect(spec.name, 'dev');
    expect(spec.autorunWorktree, isTrue);
    expect(spec.panes, hasLength(2));
    expect(spec.panes.first.split, LayoutSplit.tab);
    expect(spec.panes[1].split, LayoutSplit.right);
    expect(spec.panes[1].command, 'npm run dev');
  });

  test('defaults: cwd ".", split tab, sem command', () async {
    final spec = await loadOk(await write('panes:\n  - name: Shell\n'));
    expect(spec.autorunWorktree, isFalse);
    final p = spec.panes.single;
    expect(p.cwd, '.');
    expect(p.split, LayoutSplit.tab);
    expect(p.command, isNull);
  });

  test('platforms filtra pelo SO (string ou lista)', () async {
    final path = await write('''
panes:
  - name: All
  - name: Win
    platforms: windows
  - name: Desktop
    platforms: [Windows, linux]
''');
    final onMac = await loadOk(path);
    expect(onMac.panes.map((p) => p.name), ['All']);
    final onWin = await loadOk(path, os: 'windows');
    expect(onWin.panes.map((p) => p.name), ['All', 'Win', 'Desktop']);
  });

  test('cwd absoluto ou com backslash é rejeitado', () async {
    expect(
      await loadErr(await write('panes:\n  - name: X\n    cwd: /abs\n')),
      contains('relative'),
    );
    expect(
      await loadErr(await write('panes:\n  - name: X\n    cwd: "a\\\\b"\n')),
      contains('forward slashes'),
    );
    expect(
      await loadErr(await write('panes:\n  - name: X\n    cwd: "C:/x"\n')),
      contains('relative'),
    );
  });

  test('erros legíveis: YAML inválido, panes vazio, split/autorun inválidos, '
      'nome duplicado', () async {
    expect(
      await loadErr(await write('panes: [broken')),
      contains('invalid YAML'),
    );
    expect(await loadErr(await write('panes: []')), contains('non-empty'));
    expect(
      await loadErr(await write('panes:\n  - name: X\n    split: left\n')),
      contains('split'),
    );
    expect(
      await loadErr(await write('autorun: boot\npanes:\n  - name: X\n')),
      contains('autorun'),
    );
    expect(
      await loadErr(await write('panes:\n  - name: X\n  - name: x\n')),
      contains('duplicated'),
    );
    expect(await loadErr('${tmp.path}/nope.ckp'), contains('not found'));
  });
}
