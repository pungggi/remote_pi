import 'dart:io';

import 'package:cockpit/app/cockpit/data/tasks/npm_adapter.dart';
import 'package:cockpit/app/cockpit/domain/entities/task_definition.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('npm_adapter_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> writePackageJson(String content) =>
      File('${tmp.path}/package.json').writeAsString(content);

  test('matches when package.json exists', () async {
    expect(await const NpmAdapter().matches(tmp.path), isFalse);
    await writePackageJson('{}');
    expect(await const NpmAdapter().matches(tmp.path), isTrue);
  });

  test('one task per script, npm run <name>', () async {
    await writePackageJson('''
      { "scripts": { "dev": "vite", "build": "tsc", "test": "vitest" } }
    ''');
    final tasks = await const NpmAdapter().tasksFor(tmp.path);
    expect(
      tasks.map((t) => t.id),
      containsAll(['npm:dev', 'npm:build', 'npm:test']),
    );
    final dev = tasks.firstWhere((t) => t.id == 'npm:dev');
    expect(dev.command, 'npm');
    expect(dev.args, ['run', 'dev']);
    expect(dev.cwd, tmp.path);
  });

  test(
    'watch heuristic: dev/start/serve/watch are watch, rest oneShot',
    () async {
      await writePackageJson('''
      { "scripts": { "dev": "vite", "build": "tsc", "watch:css": "x", "lint": "y" } }
    ''');
      final tasks = await const NpmAdapter().tasksFor(tmp.path);
      TaskKind kindOf(String id) => tasks.firstWhere((t) => t.id == id).kind;
      expect(kindOf('npm:dev'), TaskKind.watch);
      expect(kindOf('npm:watch:css'), TaskKind.watch);
      expect(kindOf('npm:build'), TaskKind.oneShot);
      expect(kindOf('npm:lint'), TaskKind.oneShot);
    },
  );

  test('invalid json yields no tasks', () async {
    await writePackageJson('{ not json');
    expect(await const NpmAdapter().tasksFor(tmp.path), isEmpty);
  });
}
