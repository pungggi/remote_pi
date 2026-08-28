// Wave 4 (plano 58) — GATE: o anaki (driver de DB Rust/FFI) executa num
// processo Dart headless, FORA do Flutter? Se sim, o cockpit-server pode
// hospedar os drivers de banco e a wave é viável no desenho Dart-only.
//
// Uso (da pasta cockpit/):
//   (cd tool/wave4 && dart pub get)
//   dart run tool/wave4/wave4_gate.dart
import 'dart:io';
import 'dart:isolate';

import 'package:anaki_sqlite/anaki_sqlite.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('wave4-sqlite-');
  final dbPath = '${dir.path}/gate.db';

  try {
    final rows = await Isolate.run(() async {
      final driver = SqliteDriver(dbPath);
      await driver.rawOpen();
      try {
        await driver.rawExecute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)',
          null,
        );
        await driver.rawExecute(
          "INSERT INTO t (name) VALUES ('wave4-remote')",
          null,
        );
        return await driver.rawQuery('SELECT id, name FROM t', null);
      } finally {
        await driver.rawClose();
      }
    });

    final ok = rows.isNotEmpty && '${rows.first}'.contains('wave4-remote');
    stdout.writeln('  rows: $rows');
    stdout.writeln(ok ? 'GATE PASS: anaki roda headless' : 'GATE FAIL');
    exit(ok ? 0 : 1);
  } catch (e, s) {
    stderr.writeln('GATE FAIL: $e\n$s');
    exit(1);
  } finally {
    await dir.delete(recursive: true);
  }
}
