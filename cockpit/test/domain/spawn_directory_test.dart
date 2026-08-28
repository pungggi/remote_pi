import 'dart:io';

import 'package:cockpit/app/core/utils/spawn_directory.dart';
import 'package:cockpit/app/core/utils/user_home.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('spawn_dir_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('pasta existente é usada como está', () {
    final resolved = resolveSpawnDirectory(root.path);

    expect(resolved.path, root.path);
    expect(resolved.fellBack, isFalse);
  });

  test('pasta apagada cai no ancestral existente mais próximo', () {
    // Cenário real do bug: o workspace some entre dois boots e o layout salvo
    // ainda aponta pra ele.
    final missing = p.join(root.path, 'projects', 'redirect_api');

    final resolved = resolveSpawnDirectory(missing);

    expect(resolved.path, root.path);
    expect(resolved.requested, missing);
    expect(resolved.fellBack, isTrue);
  });

  test('preserva o ancestral mais próximo, não pula direto pra home', () {
    final projects = Directory(p.join(root.path, 'projects'))
      ..createSync(recursive: true);
    final missing = p.join(projects.path, 'redirect_api');

    final resolved = resolveSpawnDirectory(missing);

    expect(resolved.path, projects.path);
    expect(resolved.fellBack, isTrue);
  });

  test('caminho vazio resolve para a home (ou vazio, sem home)', () {
    final resolved = resolveSpawnDirectory('');

    expect(resolved.requested, '');
    final home = userHome();
    if (home != null && Directory(home).existsSync()) {
      expect(resolved.path, home);
    } else {
      expect(resolved.path, '');
    }
  });

  test('espaço em branco é tratado como vazio', () {
    expect(resolveSpawnDirectory('   ').requested, '');
  });
}
