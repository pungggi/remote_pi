@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/data/terminal/sidecar/sidecar_terminal_connector.dart';
import 'package:cockpit/app/cockpit/data/terminal/sidecar/sidecar_terminal_gateway_factory.dart';
import 'package:cockpit/app/core/domain/entities/terminal_profile.dart';
import 'package:flutter_test/flutter_test.dart';

/// Integração da Wave 1 (plano 58): o gateway do app servido pelo sidecar
/// real. Requer `./tool/build-sidecar.sh`; sem os artefatos o teste é pulado —
/// o fallback in-process é coberto pelo uso normal do app.
void main() {
  // `tool/build-sidecar.sh` passou a empacotar via `dart build cli` em
  // `build/server-bundle/bin/` (o `build/wave0/` só guarda a dylib do PTY).
  // O caminho antigo fica como fallback pra bundle gerado por versão anterior.
  final binary =
      [
        File('build/server-bundle/bin/cockpit-server'),
        File('build/wave0/cockpit-server'),
      ].firstWhere(
        (f) => f.existsSync(),
        orElse: () => File('build/wave0/cockpit-server'),
      );

  test('terminal via sidecar: eco, ack e kill', () async {
    if (!binary.existsSync()) {
      markTestSkipped(
        'binário do cockpit-server ausente; rode tool/build-sidecar.sh',
      );
      return;
    }

    final connector = SidecarTerminalConnector();
    addTearDown(connector.dispose);

    final gateway = SidecarTerminalGatewayFactory(connector).create();
    final collected = StringBuffer();
    var chunks = 0;

    gateway.start(
      workingDirectory: Directory.systemTemp.path,
      profile: const TerminalProfile(
        id: 'login-shell',
        label: 'zsh',
        executable: '/bin/zsh',
        args: ['-f'],
      ),
      extraEnv: const {'WAVE1_MARKER': 'sidecar'},
    );
    final sub = gateway.output.listen((data) {
      chunks++;
      collected.write(utf8.decode(data, allowMalformed: true));
      gateway.acknowledgeOutput(); // papel do coalescer: crédito por chunk.
    });

    // write antes do backend pronto exercita a fila de operações.
    gateway.write(utf8.encode('echo wave1-\$WAVE1_MARKER-\$((40+2))\n'));

    await _until(() => collected.toString().contains('wave1-sidecar-42'));
    expect(chunks, greaterThan(0));

    gateway.resize(40, 120);
    gateway.write(utf8.encode('stty size\n'));
    await _until(() => collected.toString().contains('40 120'));

    await gateway.kill();
    await sub.cancel();
  }, timeout: const Timeout(Duration(minutes: 1)));

  // Regressão dos "terminais espelhados": dois `open()` no mesmo instante (o
  // que o restore de um workspace com dois panes faz) casavam com a MESMA
  // `pty.opened`, porque a resposta era buscada só pelo tipo. Os dois panes
  // adotavam um `sessionId` só, liam o mesmo PTY e o segundo ficava órfão.
  // Com o `rid` de correlação, cada gateway fica com a SUA sessão.
  test('dois terminais abertos ao mesmo tempo não compartilham PTY', () async {
    if (!binary.existsSync()) {
      markTestSkipped(
        'binário do cockpit-server ausente; rode tool/build-sidecar.sh',
      );
      return;
    }

    final connector = SidecarTerminalConnector();
    addTearDown(connector.dispose);
    final factory = SidecarTerminalGatewayFactory(connector);

    const profile = TerminalProfile(
      id: 'login-shell',
      label: 'zsh',
      executable: '/bin/zsh',
      args: ['-f'],
    );

    final gateways = [factory.create(), factory.create()];
    final buffers = [StringBuffer(), StringBuffer()];
    final subs = [
      for (var i = 0; i < gateways.length; i++)
        gateways[i].output.listen((data) {
          buffers[i].write(utf8.decode(data, allowMalformed: true));
          gateways[i].acknowledgeOutput();
        }),
    ];
    addTearDown(() async {
      for (final sub in subs) {
        await sub.cancel();
      }
    });

    // Sem await entre os dois: é a simultaneidade que provocava a corrida.
    for (final gateway in gateways) {
      gateway.start(
        workingDirectory: Directory.systemTemp.path,
        profile: profile,
      );
    }

    // Cada terminal recebe uma marca própria; nenhuma pode vazar pro outro.
    gateways[0].write(utf8.encode('echo marca-\$((1+0))-um\n'));
    gateways[1].write(utf8.encode('echo marca-\$((1+1))-dois\n'));

    await _until(() => buffers[0].toString().contains('marca-1-um'));
    await _until(() => buffers[1].toString().contains('marca-2-dois'));

    expect(
      buffers[0].toString(),
      isNot(contains('marca-2-dois')),
      reason: 'saída do segundo terminal apareceu no primeiro (espelho)',
    );
    expect(
      buffers[1].toString(),
      isNot(contains('marca-1-um')),
      reason: 'saída do primeiro terminal apareceu no segundo (espelho)',
    );

    // Fechar um não pode derrubar o outro: com o PTY compartilhado, o kill
    // levava os dois.
    await gateways[0].kill();
    gateways[1].write(utf8.encode('echo ainda-vivo\n'));
    await _until(() => buffers[1].toString().contains('ainda-vivo'));

    await gateways[1].kill();
  }, timeout: const Timeout(Duration(minutes: 1)));
}

Future<void> _until(bool Function() test) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condição não satisfeita a tempo');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
