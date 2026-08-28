// Wave 0 (plano 58) — E2E do aceite:
// abre shell via cockpit-server, digita, vê saída, DESCONECTA, reata a partir
// do offset 0 e verifica que o scrollback sobreviveu ao detach.
//
// Uso (da pasta cockpit/):
//   ./tool/wave0/build_pty_dylib.sh
//   (cd tool/wave0 && dart pub get)
//   dart run tool/wave0/wave0_e2e.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cockpit_core/cockpit_core.dart';
import 'package:cockpit_remote/cockpit_remote.dart';

Future<void> main() async {
  final socketPath =
      '${Directory.systemTemp.path}/wave0-e2e-${DateTime.now().millisecondsSinceEpoch}.sock';
  final repoRoot = _cockpitRoot();

  // 1. Sobe o servidor como processo separado (como na vida real).
  final server = await Process.start(
    'dart',
    [
      'run',
      'packages/cockpit_server/bin/cockpit_server.dart',
      '--socket',
      socketPath,
    ],
    workingDirectory: repoRoot,
    environment: {
      ...Platform.environment,
      'COCKPIT_PTY_DYLIB': '$repoRoot/build/wave0/libcockpit_pty.dylib',
    },
  );
  server.stderr.transform(utf8.decoder).listen(stderr.write);
  await server.stdout
      .transform(utf8.decoder)
      .firstWhere((line) => line.contains('listening'));

  var failed = false;
  try {
    // 2. Conecta, handshake.
    final connection = await RemoteConnection.connect(socketPath);
    _check('handshake', connection.serverVersion.isNotEmpty);
    final terminals = RemoteTerminalService(connection);

    // 3. Abre shell, digita, vê o eco + resultado.
    final info = await terminals.open(
      const PtySpawnSpec(
        executable: '/bin/zsh',
        arguments: ['-f'],
        rows: 24,
        columns: 80,
      ),
    );
    _check('open (pid > 0)', info.pid > 0);

    final collected = BytesBuilder();
    final sub = terminals.attach(info.id).listen((event) {
      if (event is PtyOutputEvent) collected.add(event.chunk.bytes);
    });

    await terminals.write(
      info.id,
      Uint8List.fromList(utf8.encode('echo wave0-\$((20+22))\n')),
    );
    await _until(() => _text(collected).contains('wave0-42'));
    _check('echo roundtrip', true);

    // 4. Resize propagado (stty reporta o novo tamanho).
    await terminals.resize(info.id, 48, 132);
    await terminals.write(
      info.id,
      Uint8List.fromList(utf8.encode('stty size\n')),
    );
    await _until(() => _text(collected).contains('48 132'));
    _check('resize', true);

    // 5. DETACH: derruba a conexão inteira (simula fechar o cliente).
    await sub.cancel();
    await connection.close();

    // 6. Reata numa CONEXÃO NOVA; scrollback deve conter tudo desde o começo.
    final connection2 = await RemoteConnection.connect(socketPath);
    final terminals2 = RemoteTerminalService(connection2);
    final sessions = await terminals2.sessions();
    _check('sessão sobreviveu ao detach', sessions.any((s) => s.id == info.id));

    final replayed = BytesBuilder();
    final sub2 = terminals2.attach(info.id, fromOffset: 0).listen((event) {
      if (event is PtyOutputEvent) replayed.add(event.chunk.bytes);
    });
    await _until(
      () =>
          _text(replayed).contains('wave0-42') &&
          _text(replayed).contains('48 132'),
    );
    _check('reattach com scrollback completo', true);

    // 7. Live continua após o replay.
    await terminals2.write(
      info.id,
      Uint8List.fromList(utf8.encode('echo pos-reattach\n')),
    );
    await _until(() => _text(replayed).contains('pos-reattach'));
    _check('live após reattach', true);

    await sub2.cancel();
    await terminals2.kill(info.id);
    final after = await terminals2.sessions();
    _check('kill remove a sessão', after.every((s) => s.id != info.id));

    // 8. Flow control (Wave 1): sessão ackRead com janela de créditos; o
    // cliente devolve pty.ack por chunk e o despejo completa sem stall.
    const dumpBytes = 2 * 1024 * 1024;
    final flowInfo = await terminals2.open(
      const PtySpawnSpec(
        executable: '/bin/sh',
        arguments: ['-c', 'head -c $dumpBytes /dev/zero; echo FLOW-DONE'],
        flowControlled: true,
      ),
    );
    var flowReceived = 0;
    var sawMarker = false;
    final flowSub = terminals2.attach(flowInfo.id).listen((event) {
      if (event is PtyOutputEvent) {
        flowReceived += event.chunk.bytes.length;
        if (utf8
            .decode(event.chunk.bytes, allowMalformed: true)
            .contains('FLOW-DONE')) {
          sawMarker = true;
        }
        // Consumidor devolvendo crédito chunk a chunk (papel do coalescer).
        terminals2.ack(flowInfo.id, event.chunk.bytes.length);
      }
    });
    await _until(() => sawMarker);
    _check(
      'flow control: despejo completa com acks',
      flowReceived >= dumpBytes,
    );
    await flowSub.cancel();
    await terminals2.kill(flowInfo.id);

    // 9. Arquivos + Git remotos (Wave 3) num repo git temporário.
    final repo = await Directory.systemTemp.createTemp('wave3-repo-');
    await Process.run('git', ['-C', repo.path, 'init', '-q']);
    await Process.run('git', ['-C', repo.path, 'config', 'user.email', 't@t']);
    await Process.run('git', ['-C', repo.path, 'config', 'user.name', 'T']);

    final files = RemoteFileService(connection2);
    final git = RemoteGitService(connection2);

    // fs.write + fs.read roundtrip.
    final filePath = '${repo.path}/hello.txt';
    await files.write(filePath, Uint8List.fromList(utf8.encode('wave3-fs\n')));
    final readBack = utf8.decode(await files.read(filePath));
    _check('fs.write/read roundtrip', readBack.trim() == 'wave3-fs');

    // fs.list mostra o arquivo novo.
    final listing = await files.list(repo.path);
    _check('fs.list vê o arquivo', listing.any((e) => e.name == 'hello.txt'));

    // git.status = 1 arquivo untracked.
    final st1 = await git.status(repo.path);
    _check(
      'git.status untracked',
      st1.files.any((f) => f.path == 'hello.txt' && f.worktree == '?'),
    );

    // git.stage → aparece staged; git.commit → status limpo.
    await git.stage(repo.path, ['hello.txt']);
    final st2 = await git.status(repo.path);
    _check(
      'git.stage staged',
      st2.files.any((f) => f.path == 'hello.txt' && f.staged == 'A'),
    );
    await git.commit(repo.path, 'wave3 commit');
    final st3 = await git.status(repo.path);
    _check('git.commit limpa o status', st3.files.isEmpty);

    await repo.delete(recursive: true);

    // 10. Databases remotos (Wave 4): SQLite via anaki no servidor.
    final db = RemoteDbService(connection2);
    final dbFile = '${repo.path}-wave4.db';
    final conn = RemoteDbConnDescriptor(engine: 'sqlite', sqlitePath: dbFile);
    await db.query(
      conn,
      'CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)',
      dml: true,
    );
    await db.query(
      conn,
      "INSERT INTO items (name) VALUES ('wave4-db')",
      dml: true,
    );
    final result = await db.query(conn, 'SELECT id, name FROM items');
    final rows = result['rows'] as List;
    _check(
      'db.query remoto (sqlite via anaki no servidor)',
      rows.isNotEmpty && '${rows.first}'.contains('wave4-db'),
    );
    await File(dbFile).delete().catchError((_) => File(dbFile));

    await connection2.close();
    stdout.writeln('E2E OK');
  } catch (e, s) {
    failed = true;
    stderr.writeln('E2E FAILED: $e\n$s');
  } finally {
    server.kill();
    exit(failed ? 1 : 0);
  }
}

String _cockpitRoot() {
  // O script roda de cockpit/ (dart run tool/wave0/...) ou de tool/wave0.
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync() ||
      !Directory('${dir.path}/packages/cockpit_server').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('run from the cockpit/ folder');
    }
    dir = parent;
  }
  return dir.path;
}

String _text(BytesBuilder builder) =>
    utf8.decode(builder.toBytes(), allowMalformed: true);

void _check(String label, bool ok) {
  stdout.writeln('  ${ok ? 'PASS' : 'FAIL'}  $label');
  if (!ok) throw StateError(label);
}

Future<void> _until(bool Function() test) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
