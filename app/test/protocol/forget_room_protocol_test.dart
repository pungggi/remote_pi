// Plan/158 — forget_room protocol round-trip: the request encodes with the
// snake_case wire fields (delete_history only when asked) and the result
// parses with every field optional except the contract core, so an older PC
// replying without history fields never breaks the parse.

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ForgetRoomRequest (plan/158)', () {
    test('encodes room_id; omits delete_history when false', () {
      final m = ForgetRoomRequest(id: 'r1', roomId: 'roomA');
      expect(m.toJson(), {'type': 'forget_room_request', 'id': 'r1', 'room_id': 'roomA'});
    });

    test('carries delete_history when asked', () {
      final m = ForgetRoomRequest(id: 'r2', roomId: 'roomA', deleteHistory: true);
      expect(m.toJson()['delete_history'], isTrue);
    });
  });

  group('ForgetRoomResult parsing (plan/158)', () {
    test('parses the full reply', () {
      final c = ServerMessage.fromJson({
        'type': 'forget_room_result',
        'in_reply_to': 'r1',
        'ok': true,
        'message': 'The computer forgot this session.',
        'registry_removed': true,
        'history_removed': true,
        'history_note': 'deleted 2 transcript file(s)',
      });
      expect(c, isA<ForgetRoomResult>());
      final r = c as ForgetRoomResult;
      expect(r.inReplyTo, 'r1');
      expect(r.ok, isTrue);
      expect(r.registryRemoved, isTrue);
      expect(r.historyRemoved, isTrue);
      expect(r.historyNote, contains('2 transcript'));
    });

    test('tolerates a PC without history fields (idempotent core only)', () {
      final c = ServerMessage.fromJson({
        'type': 'forget_room_result',
        'in_reply_to': 'r2',
        'ok': true,
        'message': 'forgotten',
        'registry_removed': false,
      });
      expect(c, isA<ForgetRoomResult>());
      final r = c as ForgetRoomResult;
      expect(r.registryRemoved, isFalse);
      expect(r.historyRemoved, isNull);
      expect(r.historyNote, isNull);
    });

    test('ok defaults false and registry_removed defaults false', () {
      final c = ServerMessage.fromJson({
        'type': 'forget_room_result',
        'in_reply_to': 'r3',
        'message': 'boom',
      });
      expect(c, isA<ForgetRoomResult>());
      final r = c as ForgetRoomResult;
      expect(r.ok, isFalse);
      expect(r.registryRemoved, isFalse);
    });
  });
}
