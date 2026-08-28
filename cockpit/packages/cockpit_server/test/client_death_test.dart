// Um cliente que some no meio da saída de PTY NÃO pode derrubar o servidor.
//
// Antes deste guardrail, a escrita no socket morto virava
// `SocketException: Write failed (Broken pipe)` NÃO TRATADA e matava o
// processo inteiro — levando junto os terminais de todos os workspaces
// daquele sidecar. Reproduzido em produção; este teste é a trava.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cockpit_core/cockpit_core.dart';
import 'package:cockpit_protocol/cockpit_protocol.dart';
import 'package:cockpit_server/cockpit_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cockpit-death');
    path = '${dir.path}/cockpit-server.sock';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('cliente que morre no meio do stream não derruba o servidor', () async {
    final terminals = _ChattyTerminals();
    final server = RemoteServer(terminals, _Fake(), _Fake(), _Fake());
    await server.bind(path);
    addTearDown(server.close);

    // Cliente 1: abre, anexa e some no meio da enxurrada de saída.
    final victim = await LocalEndpoint.connect(path);
    await _handshake(victim.socket);
    victim.socket.add(_line(const PtyOpen(executable: '/bin/sh')));
    victim.socket.add(_line(const PtyAttach(sessionId: 's1')));
    await victim.socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    terminals.spew(2000); // servidor escreve muito no socket...
    victim.socket.destroy(); // ...e o cliente evapora no meio disso.

    // O servidor tem que continuar de pé e atendendo QUEM MAIS chegar.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final survivor = await LocalEndpoint.connect(path);
    addTearDown(survivor.socket.destroy);
    final ack = await _handshake(survivor.socket);
    expect(ack, isA<HelloAck>());
  });
}

Future<RemoteMessage> _handshake(Socket socket) async {
  final first = const RemoteMessageCodec().decodeStream(socket).first;
  socket.add(_line(const Hello(version: protocolVersion, client: 'test')));
  await socket.flush();
  return first.timeout(const Duration(seconds: 5));
}

List<int> _line(RemoteMessage m) =>
    utf8.encode(const RemoteMessageCodec().encode(m));

/// Terminal falso que despeja saída sob demanda — o que enche o socket.
class _ChattyTerminals implements TerminalService {
  final _live = StreamController<PtyEvent>.broadcast();
  var _offset = 0;

  void spew(int chunks) {
    final payload = Uint8List.fromList(List<int>.filled(1024, 0x41));
    for (var i = 0; i < chunks; i++) {
      _live.add(
        PtyOutputEvent(PtyOutputChunk(offset: _offset, bytes: payload)),
      );
      _offset += payload.length;
    }
  }

  @override
  Future<PtySessionInfo> open(PtySpawnSpec spec) async => const PtySessionInfo(
    id: 's1',
    pid: 1,
    executable: '/bin/sh',
    rows: 24,
    columns: 80,
    scrollbackLength: 0,
  );

  @override
  Stream<PtyEvent> attach(String id, {int fromOffset = 0}) => _live.stream;

  @override
  Future<void> ack(String id, int bytes) async {}

  @override
  Future<void> dispose() async => _live.close();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Fake implements FileService, GitService, DbService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
