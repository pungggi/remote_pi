// Plan/132 — `meta.run_done` parsing on RoomMetaUpdated (protocol layer).

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('meta.run_done parses turn_id + ended_at', () {
    final ctrl = ControlInbound.tryFromJson({
      'type': 'room_meta_updated',
      'peer': 'epkA',
      'room_id': 'r1',
      'meta': {
        'working': false,
        'run_done': {'turn_id': 'turn-42', 'ended_at': 1735689600000},
      },
    });
    expect(ctrl, isA<RoomMetaUpdated>());
    final u = ctrl! as RoomMetaUpdated;
    expect(u.working, isFalse);
    expect(u.runDone, isNotNull);
    expect(u.runDone!.turnId, 'turn-42');
    expect(u.runDone!.endedAtMs, 1735689600000);
  });

  test('run_done with null turn_id (terminal-initiated run) parses', () {
    final ctrl = ControlInbound.tryFromJson({
      'type': 'room_meta_updated',
      'peer': 'epkA',
      'room_id': 'r1',
      'meta': {
        'run_done': {'turn_id': null, 'ended_at': 42},
      },
    }) as RoomMetaUpdated?;
    expect(ctrl, isNotNull);
    expect(ctrl!.runDone, isNotNull);
    expect(ctrl.runDone!.turnId, isNull);
    expect(ctrl.runDone!.endedAtMs, 42);
  });

  test('absent run_done → null (nullable-as-absent, like working)', () {
    final ctrl = ControlInbound.tryFromJson({
      'type': 'room_meta_updated',
      'peer': 'epkA',
      'room_id': 'r1',
      'meta': {'working': true},
    }) as RoomMetaUpdated?;
    expect(ctrl!.runDone, isNull);
    expect(ctrl.working, isTrue);
  });

  test('malformed run_done (missing ended_at) → null, rest intact', () {
    final ctrl = ControlInbound.tryFromJson({
      'type': 'room_meta_updated',
      'peer': 'epkA',
      'room_id': 'r1',
      'meta': {
        'model': 'opus',
        'run_done': {'turn_id': 'x'},
      },
    }) as RoomMetaUpdated?;
    expect(ctrl!.runDone, isNull);
    expect(ctrl.model, 'opus');
  });

  test('RunDoneMarker equality covers (turnId, endedAtMs)', () {
    const a = RunDoneMarker(turnId: 't', endedAtMs: 1);
    const b = RunDoneMarker(turnId: 't', endedAtMs: 1);
    const c = RunDoneMarker(turnId: null, endedAtMs: 1);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == c, isFalse);
  });
}
