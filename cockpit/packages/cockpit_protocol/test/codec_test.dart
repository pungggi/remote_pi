import 'dart:convert';
import 'dart:typed_data';

import 'package:cockpit_protocol/cockpit_protocol.dart';
import 'package:test/test.dart';

void main() {
  const codec = RemoteMessageCodec();

  test('roundtrip das mensagens principais', () {
    final messages = <RemoteMessage>[
      const Hello(version: 1, client: 'test'),
      const HelloAck(version: 1, server: '0.1.0'),
      const PtyOpen(
        executable: '/bin/zsh',
        arguments: ['-l'],
        rows: 30,
        columns: 100,
      ),
      const PtyOpened(sessionId: 's1', pid: 42),
      // Correlação request/response: o `rid` precisa sobreviver ao roundtrip,
      // senão dois opens simultâneos voltam a casar com a mesma resposta.
      const PtyOpen(rid: 7, executable: '/bin/zsh'),
      const PtyOpened(sessionId: 's2', pid: 43, rid: 7),
      const PtyList(rid: 8),
      const PtySessions(sessions: [], rid: 8),
      const RemoteError(code: 'spawn_failed', rid: 9),
      PtyInput(sessionId: 's1', bytes: Uint8List.fromList([1, 2, 3])),
      PtyOutput(sessionId: 's1', offset: 7, bytes: Uint8List.fromList([9, 8])),
      const PtyResize(sessionId: 's1', rows: 40, columns: 120),
      const PtyAttach(sessionId: 's1', fromOffset: 128),
      const PtyExited(sessionId: 's1', exitCode: 0),
      const RemoteError(code: 'session_not_found', sessionId: 's9'),
    ];

    for (final message in messages) {
      final line = codec.encode(message);
      expect(line, endsWith('\n'));
      final decoded = codec.decodeLine(line.trim());
      expect(decoded.runtimeType, message.runtimeType);
      expect(jsonEncode(decoded.toJson()), jsonEncode(message.toJson()));
    }
  });

  test(
    'decodeStream separa por linha, inclusive linhas coladas num chunk',
    () async {
      final chunk = utf8.encode(
        '${codec.encode(const PtyList())}${codec.encode(const Hello(version: 1, client: 'x'))}',
      );
      final messages = await codec.decodeStream(Stream.value(chunk)).toList();
      expect(messages, hasLength(2));
      expect(messages.first, isA<PtyList>());
      expect(messages.last, isA<Hello>());
    },
  );

  test('tipo desconhecido vira FormatException', () {
    expect(() => codec.decodeLine('{"t":"nope"}'), throwsFormatException);
  });
}
