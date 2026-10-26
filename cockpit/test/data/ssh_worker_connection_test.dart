// A conexão SSH do mobile roda numa isolate própria (ver SshWorkerConnection).
// Sem servidor SSH nos testes, cobrimos o que dá pra provar offline: a isolate
// sobe, o erro tipado atravessa de volta igual ao da conexão direta, e o
// ciclo de vida (done/close) fecha sem vazar isolate.
import 'dart:io';

import 'package:cockpit/app/cockpit/data/remote/dartssh_host_connection.dart';
import 'package:cockpit/app/cockpit/data/remote/ssh_worker_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('porta fechada: falha com DartSshException vinda da isolate', () async {
    // Porta garantidamente fechada: abre um listener e solta.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final conn = SshWorkerConnection(
      SshEndpoint('nobody', '127.0.0.1', port),
      verifyHostKey: (_) async => true,
    );
    await expectLater(
      conn.connect(),
      throwsA(
        isA<DartSshException>().having(
          (e) => e.code,
          'code',
          'ssh_connect_failed',
        ),
      ),
    );
    await conn.close();
    await conn.done;
  });

  test('operações antes de connect falham tipadas', () async {
    final conn = SshWorkerConnection(
      const SshEndpoint('nobody', '127.0.0.1', 1),
      verifyHostKey: (_) async => true,
    );
    expect(
      () => conn.runDetailed('true'),
      throwsA(
        isA<DartSshException>().having(
          (e) => e.code,
          'code',
          'ssh_not_connected',
        ),
      ),
    );
    await conn.close();
  });

  test('erro de handshake atravessa a isolate com detail', () async {
    // Servidor TCP falso que fala o banner SSH e some: o dartssh2 chega até o
    // handshake e falha antes da host key — o que prova aqui é só que o caminho
    // de erro genérico atravessa a isolate com detail preenchido.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {
      s.write('SSH-2.0-fake\r\n');
      s.destroy();
    });
    addTearDown(server.close);
    final conn = SshWorkerConnection(
      SshEndpoint('nobody', '127.0.0.1', server.port),
      verifyHostKey: (_) async => false,
    );
    await expectLater(
      conn.connect(),
      throwsA(
        isA<DartSshException>().having((e) => e.detail, 'detail', isNotNull),
      ),
    );
    await conn.close();
  });
}
