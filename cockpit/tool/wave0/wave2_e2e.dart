// Wave 2 (plano 58) — E2E MANUAL do transporte SSH. Requer um host real
// alcançável por `ssh <target>` sem senha interativa (chave/agent).
//
// Uso (da pasta cockpit/):
//   ./tool/build-sidecar.sh
//   dart run tool/wave0/wave2_e2e.dart jacob@imac.local
//
// O script faz o fluxo completo do RemoteHostConnector, standalone:
// 1. instala o cockpit-server no host via ssh (binário local → stdin → arquivo)
// 2. inicia o servidor remoto (nohup, --exit-on-idle 0)
// 3. abre túnel UDS→UDS e fala o protocolo: shell remoto, eco, detach,
//    reattach com scrollback (a sessão sobrevive à queda do túnel).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cockpit_core/cockpit_core.dart';
import 'package:cockpit_remote/cockpit_remote.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('uso: dart run tool/wave0/wave2_e2e.dart <user@host>');
    exit(2);
  }
  final target = args.first;
  final root = Directory.current.path;
  final binary = '$root/build/wave0/cockpit-server';
  final dylib = '$root/build/wave0/libcockpit_pty.dylib';
  if (!File(binary).existsSync()) {
    stderr.writeln('rode ./tool/build-sidecar.sh antes');
    exit(2);
  }

  var failed = false;
  Process? tunnel;
  try {
    // 1. Install server via ssh (mesmo mecanismo do RemoteHostConnector).
    await _push(target, binary, '~/.cockpit/bin/cockpit-server');
    await _push(target, dylib, '~/.cockpit/bin/libcockpit_pty.dylib');
    _check('install server (binário + dylib via ssh)', true);

    // 2. (Re)inicia o servidor remoto.
    // [c]ockpit: o padrão não pode casar com a própria linha deste comando
    // (pkill -f mataria o shell remoto que o executa).
    await _ssh(target, 'pkill -f "[c]ockpit-server --socket" || true');
    await _ssh(
      target,
      'COCKPIT_PTY_DYLIB=\$HOME/.cockpit/bin/libcockpit_pty.dylib '
      'nohup \$HOME/.cockpit/bin/cockpit-server '
      '--socket \$HOME/.cockpit/cockpit-server.sock --exit-on-idle 0 '
      '>/dev/null 2>&1 & echo ok',
    );
    _check('servidor remoto iniciado', true);

    // 3. Túnel. Forward streamlocal exige path REMOTO ABSOLUTO (não resolve
    // relativo nem ~): resolvemos a home remota antes.
    final homeResult = await Process.run('ssh', [
      '-o',
      'BatchMode=yes',
      target,
      r'printf %s "$HOME"',
    ]);
    final remoteHome = (homeResult.stdout as String).trim();
    final remoteSock = '$remoteHome/.cockpit/cockpit-server.sock';
    final localSock =
        '${Directory.systemTemp.path}/wave2-${DateTime.now().millisecondsSinceEpoch}.sock';
    tunnel = await Process.start('ssh', [
      '-N',
      '-o',
      'BatchMode=yes',
      '-o',
      'ExitOnForwardFailure=yes',
      '-o',
      'StreamLocalBindUnlink=yes',
      '-L',
      '$localSock:$remoteSock',
      target,
    ]);
    unawaited(tunnel.stderr.transform(utf8.decoder).forEach(stderr.write));
    await _until(() => File(localSock).existsSync());

    // 4. Protocolo pelo túnel (retry: o servidor recém-iniciado pode ainda
    // não ter feito bind quando o forward tenta o primeiro connect).
    final connection = await _connectRetry(localSock);
    _check('handshake pelo túnel (server ${connection.serverVersion})', true);
    final terminals = RemoteTerminalService(connection);

    final info = await terminals.open(
      const PtySpawnSpec(executable: '/bin/sh', arguments: []),
    );
    final collected = BytesBuilder();
    final sub = terminals.attach(info.id).listen((e) {
      if (e is PtyOutputEvent) collected.add(e.chunk.bytes);
    });
    await terminals.write(
      info.id,
      Uint8List.fromList(utf8.encode('echo wave2-remoto \$(hostname)\n')),
    );
    await _until(
      () => utf8
          .decode(collected.toBytes(), allowMalformed: true)
          .contains('wave2-remoto'),
    );
    stdout.writeln(
      '  saída remota: '
      '${utf8.decode(collected.toBytes(), allowMalformed: true).trim().split('\n').last}',
    );
    _check('shell remoto via túnel', true);

    // 5. Mata o TÚNEL (queda de rede); sessão deve sobreviver no host.
    await sub.cancel();
    await connection.close();
    tunnel.kill();
    await Future<void>.delayed(const Duration(seconds: 1));

    final localSock2 = '$localSock-2';
    tunnel = await Process.start('ssh', [
      '-N',
      '-o',
      'BatchMode=yes',
      '-o',
      'StreamLocalBindUnlink=yes',
      '-L',
      '$localSock2:$remoteSock',
      target,
    ]);
    await _until(() => File(localSock2).existsSync());
    final connection2 = await _connectRetry(localSock2);
    final terminals2 = RemoteTerminalService(connection2);
    final sessions = await terminals2.sessions();
    _check(
      'sessão sobreviveu à queda do túnel',
      sessions.any((s) => s.id == info.id),
    );
    final replayed = BytesBuilder();
    final sub2 = terminals2.attach(info.id, fromOffset: 0).listen((e) {
      if (e is PtyOutputEvent) replayed.add(e.chunk.bytes);
    });
    await _until(
      () => utf8
          .decode(replayed.toBytes(), allowMalformed: true)
          .contains('wave2-remoto'),
    );
    _check('reattach remoto com scrollback', true);

    await sub2.cancel();
    await terminals2.kill(info.id);
    await connection2.close();
    stdout.writeln('WAVE2 E2E OK');
  } catch (e, s) {
    failed = true;
    stderr.writeln('WAVE2 E2E FAILED: $e\n$s');
  } finally {
    tunnel?.kill();
    exit(failed ? 1 : 0);
  }
}

Future<RemoteConnection> _connectRetry(String socketPath) async {
  Object? last;
  for (var i = 0; i < 15; i++) {
    try {
      return await RemoteConnection.connect(socketPath);
    } catch (e) {
      last = e;
      await Future<void>.delayed(Duration(milliseconds: 150 + i * 100));
    }
  }
  throw StateError('connect pelo túnel falhou: $last');
}

Future<void> _push(String target, String local, String remote) async {
  final process = await Process.start('ssh', [
    '-o',
    'BatchMode=yes',
    target,
    'mkdir -p ~/.cockpit/bin && cat > $remote && chmod +x $remote',
  ]);
  process.stdin.add(await File(local).readAsBytes());
  await process.stdin.close();
  final code = await process.exitCode;
  if (code != 0) throw StateError('push $remote falhou ($code)');
}

Future<void> _ssh(String target, String command) async {
  final result = await Process.run('ssh', [
    '-o',
    'BatchMode=yes',
    target,
    command,
  ]);
  if (result.exitCode != 0) {
    throw StateError('ssh "$command" falhou: ${result.stderr}');
  }
}

void _check(String label, bool ok) {
  stdout.writeln('  ${ok ? 'PASS' : 'FAIL'}  $label');
  if (!ok) throw StateError(label);
}

Future<void> _until(bool Function() test) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
