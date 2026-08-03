import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/core/data/setup/hive_migration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String hiveDir;
  late String stateDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hive_migration_test');
    hiveDir = p.join(tmp.path, 'legacy');
    stateDir = p.join(tmp.path, 'state');
    await Directory(hiveDir).create(recursive: true);
    await Directory(stateDir).create(recursive: true);
  });

  tearDown(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  /// Cria as 5 boxes legadas com conteúdo representativo e as fecha (arquivos
  /// .hive ficam no disco, como numa instalação real).
  Future<void> seedLegacyBoxes() async {
    Hive.init(hiveDir);
    final settings = await Hive.openBox<dynamic>('settings');
    await settings.put('app', {'themeMode': 'dark', 'enableAgent': true});
    final window = await Hive.openBox<dynamic>('window_state');
    await window.putAll({
      'x': 10.0,
      'y': 20.0,
      'width': 1280.0,
      'height': 720.0,
    });
    final projects = await Hive.openBox<dynamic>('projects');
    await projects.put('uid-1', {'id': 'uid-1', 'path': '/x', 'name': 'x'});
    await projects.put('__last_selected__::default', 'uid-1');
    final layouts = await Hive.openBox<dynamic>('layouts');
    await layouts.put('uid-1', '{"tree":{}}');
    final realms = await Hive.openBox<dynamic>('realms');
    await realms.put('default', {'id': 'default', 'name': 'Default'});
    await Hive.close();
  }

  Map<String, dynamic> readJson(String name) {
    final raw = File(p.join(stateDir, '$name.json')).readAsStringSync();
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  HiveToJsonMigration migration() => HiveToJsonMigration(
    appVersion: '9.9.9',
    stateDirOverride: stateDir,
    legacyDirCandidatesOverride: [
      p.join(tmp.path, 'nonexistent'), // candidato sem boxes é pulado
      hiveDir,
    ],
  );

  test('migra as 5 boxes pro JSON e grava o marcador por último', () async {
    await seedLegacyBoxes();

    final ran = await migration().runIfNeeded();
    expect(ran, isTrue);

    expect(readJson('settings')['data'], {
      'app': {'themeMode': 'dark', 'enableAgent': true},
    });
    expect(readJson('window_state')['data'], {
      'x': 10.0,
      'y': 20.0,
      'width': 1280.0,
      'height': 720.0,
    });
    expect(readJson('projects')['data'], {
      'uid-1': {'id': 'uid-1', 'path': '/x', 'name': 'x'},
      '__last_selected__::default': 'uid-1',
    });
    expect(readJson('layouts')['data'], {'uid-1': '{"tree":{}}'});
    expect(readJson('realms')['data'], {
      'default': {'id': 'default', 'name': 'Default'},
    });

    final marker = readJson('migration');
    expect(marker['from'], hiveDir);
    expect(marker['appVersion'], '9.9.9');
    expect(marker['failed'], isEmpty);

    // Boxes legadas preservadas (backup/rollback).
    expect(File(p.join(hiveDir, 'projects.hive')).existsSync(), isTrue);
  });

  test('idempotente: marcador existente → skip total', () async {
    await seedLegacyBoxes();
    await migration().runIfNeeded();

    // Marca o JSON de projects pra detectar reescrita indevida.
    final probe = File(p.join(stateDir, 'projects.json'));
    await probe.writeAsString('{"version":1,"data":{"probe":true}}');

    final ranAgain = await migration().runIfNeeded();
    expect(ranAgain, isFalse);
    expect(readJson('projects')['data'], {'probe': true}); // intocado
  });

  test(
    'box corrompida (bytes lixo) → Hive recupera vazia, sem abortar',
    () async {
      await seedLegacyBoxes();
      // Frames inválidos: o Hive "recupera" a box descartando o conteúdo — a
      // migração segue e o JSON nasce vazio, sem entrar em `failed`.
      await File(
        p.join(hiveDir, 'layouts.hive'),
      ).writeAsBytes(List<int>.filled(64, 0xFF));

      final ran = await migration().runIfNeeded();
      expect(ran, isTrue);
      expect(readJson('layouts')['data'], isEmpty);
      // As demais migraram normalmente.
      expect(readJson('projects')['data'], isNotEmpty);
    },
  );

  test('box que falha ao ler → JSON vazio + registrada em failed', () async {
    await seedLegacyBoxes();
    // Valor não-encodável em JSON (double não finito): o dump da box lança →
    // box entra em `failed`, migração não aborta.
    Hive.init(hiveDir);
    final layouts = await Hive.openBox<dynamic>('layouts');
    await layouts.put('bad', double.infinity);
    await Hive.close();

    final ran = await migration().runIfNeeded();
    expect(ran, isTrue);

    final marker = readJson('migration');
    expect(marker['failed'], ['layouts']);
    expect(readJson('layouts')['data'], isEmpty);
    expect(readJson('projects')['data'], isNotEmpty);
  });

  test('instalação fresca (sem Hive) → só o marcador, from null', () async {
    final ran = await HiveToJsonMigration(
      stateDirOverride: stateDir,
      legacyDirCandidatesOverride: [p.join(tmp.path, 'nonexistent')],
    ).runIfNeeded();
    expect(ran, isTrue);

    final marker = readJson('migration');
    expect(marker['from'], isNull);
    expect(marker['failed'], isEmpty);
    // Nenhum JSON de box criado — nascem sob demanda.
    expect(File(p.join(stateDir, 'settings.json')).existsSync(), isFalse);
  });
}
