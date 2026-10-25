// Saída de PTY em rajada sai em LOTES (um `pty.output` por janela), sem
// atrasar chunk isolado e sem reordenar o `pty.exited`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cockpit_core/cockpit_core.dart';
import 'package:cockpit_protocol/cockpit_protocol.dart';
import 'package:cockpit_server/cockpit_server.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

void main() {
  group('PtyOutputCoalescer', () {
    test('chunk isolado sai na hora; rajada vira um lote por janela', () {
      fakeAsync((async) {
        final out = <(int, Uint8List)>[];
        final c = PtyOutputCoalescer(
          (o, b) => out.add((o, b)),
          window: const Duration(milliseconds: 8),
        );
        c.add(0, Uint8List.fromList([1]));
        expect(out, hasLength(1)); // tecla: zero atraso
        c.add(1, Uint8List.fromList([2, 3]));
        c.add(3, Uint8List.fromList([4]));
        expect(out, hasLength(1)); // dentro da janela: acumula
        async.elapse(const Duration(milliseconds: 8));
        expect(out, hasLength(2));
        expect(out[1].$1, 1);
        expect(out[1].$2, [2, 3, 4]);
        // janela reaberta após o lote; sem nada novo ela fecha e volta a ocioso
        async.elapse(const Duration(milliseconds: 8));
        c.add(4, Uint8List.fromList([5]));
        expect(out, hasLength(3));
        c.dispose();
      });
    });

    test('flush despeja o pendente antes do próximo evento', () {
      fakeAsync((async) {
        final out = <int>[];
        final c = PtyOutputCoalescer((o, b) => out.add(b.length));
        c.add(0, Uint8List(1));
        c.add(1, Uint8List(10));
        c.flush();
        expect(out, [1, 10]);
        c.dispose();
      });
    });
  });

  test(
    'servidor entrega rajada em poucos lotes e o exited por último',
    () async {
      final dir = Directory.systemTemp.createTempSync('cockpit-coalesce');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/cockpit-server.sock';
      final terminals = _ChattyTerminals();
      final server = RemoteServer(terminals, _Fake(), _Fake(), _Fake());
      await server.bind(path);
      addTearDown(server.close);

      final client = await LocalEndpoint.connect(path);
      addTearDown(client.socket.destroy);
      final messages = const RemoteMessageCodec()
          .decodeStream(client.socket)
          .asBroadcastStream();
      final ack = messages.first;
      client.socket.add(
        _line(const Hello(version: protocolVersion, client: 't')),
      );
      await ack;
      client.socket.add(_line(const PtyOpen(executable: '/bin/sh')));
      client.socket.add(_line(const PtyAttach(sessionId: 's1')));
      await client.socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      const chunks = 200;
      terminals.spew(chunks);
      terminals.exit(0);

      final received = <RemoteMessage>[];
      await for (final m in messages) {
        received.add(m);
        if (m is PtyExited) break;
      }
      final outputs = received.whereType<PtyOutput>().toList();
      final total = outputs.fold<int>(0, (n, o) => n + o.bytes.length);
      expect(total, chunks * 1024);
      expect(outputs.length, lessThan(chunks ~/ 10));
      // Offsets contíguos: cada lote começa onde o anterior terminou.
      var expectedOffset = 0;
      for (final o in outputs) {
        expect(o.offset, expectedOffset);
        expectedOffset += o.bytes.length;
      }
      expect(received.last, isA<PtyExited>());
    },
  );
}

List<int> _line(RemoteMessage m) =>
    utf8.encode(const RemoteMessageCodec().encode(m));

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

  void exit(int code) => _live.add(PtyExitEvent(code));

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
