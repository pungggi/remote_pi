// Tests for the new room-related control frames (plan 17).

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ControlInbound — rooms (plan 17)', () {
    test('room_announced parses with name + cwd', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epk_A',
        'room_id': 'room-uuid-1',
        'name': 'work',
        'cwd': '/Users/jacob/projects/app',
        'started_at': 1700000000000,
      });
      expect(c, isA<RoomAnnounced>());
      final r = c! as RoomAnnounced;
      expect(r.peer, 'epk_A');
      expect(r.roomId, 'room-uuid-1');
      expect(r.name, 'work');
      expect(r.cwd, '/Users/jacob/projects/app');
      expect(r.startedAt, 1700000000000);
    });

    test('room_announced tolerates missing name + cwd', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epk_A',
        'room_id': 'main',
        'started_at': 1700000000000,
      });
      expect(c, isA<RoomAnnounced>());
      final r = c! as RoomAnnounced;
      expect(r.name, isNull);
      expect(r.cwd, isNull);
    });

    test('room_ended parses', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_ended',
        'peer': 'epk_A',
        'room_id': 'room-uuid-1',
        'since_ts': 1700000010000,
      });
      expect(c, isA<RoomEnded>());
      final r = c! as RoomEnded;
      expect(r.roomId, 'room-uuid-1');
      expect(r.sinceTs, 1700000010000);
    });

    test('rooms snapshot parses with nested RoomInfo list', () {
      final c = ControlInbound.tryFromJson({
        'type': 'rooms',
        'peer': 'epk_A',
        'rooms': [
          {
            'room_id': 'r1',
            'name': 'one',
            'cwd': '/one',
            'started_at': 1000,
          },
          {
            'room_id': 'r2',
            'started_at': 2000,
          },
        ],
      });
      expect(c, isA<RoomsSnapshot>());
      final r = c! as RoomsSnapshot;
      expect(r.peer, 'epk_A');
      expect(r.rooms, hasLength(2));
      expect(r.rooms[0].roomId, 'r1');
      expect(r.rooms[0].cwd, '/one');
      expect(r.rooms[1].name, isNull);
      expect(r.rooms[1].cwd, isNull);
    });

    test(
      'room_announced parses optional `model` (plan 18)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_announced',
          'peer': 'epk_A',
          'room_id': 'r1',
          'started_at': 1700000000000,
          'model': 'claude-sonnet-4.5',
        });
        expect(c, isA<RoomAnnounced>());
        expect((c! as RoomAnnounced).model, 'claude-sonnet-4.5');
      },
    );

    test(
      'room_meta_updated parses with model (plan 18)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'epk_A',
          'room_id': 'r1',
          'meta': {'model': 'gpt-4o'},
        });
        expect(c, isA<RoomMetaUpdated>());
        final r = c! as RoomMetaUpdated;
        expect(r.peer, 'epk_A');
        expect(r.roomId, 'r1');
        expect(r.model, 'gpt-4o');
      },
    );

    test(
      'room_meta_updated parses waiting_for_input (plan 134; nullable-as-absent)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'epk_A',
          'room_id': 'r1',
          'meta': {
            'working': true,
            'waiting_for_input': true,
          },
        });
        final r = c! as RoomMetaUpdated;
        expect(r.working, isTrue);
        expect(r.waitingForInput, isTrue);

        // Absent key → null (preserve current), not false.
        final absent = ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'epk_A',
          'room_id': 'r1',
          'meta': {'model': 'gpt-4o'},
        })! as RoomMetaUpdated;
        expect(absent.waitingForInput, isNull);

        // Explicit false → cleared.
        final cleared = ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'epk_A',
          'room_id': 'r1',
          'meta': {'waiting_for_input': false},
        })! as RoomMetaUpdated;
        expect(cleared.waitingForInput, isFalse);
      },
    );

    test(
      'room_announced parses waiting_for_input flat OR nested under meta (plan 134)',
      () {
        final flat = ControlInbound.tryFromJson({
          'type': 'room_announced',
          'peer': 'epk_A',
          'room_id': 'r1',
          'started_at': 1700000000000,
          'waiting_for_input': true,
        })! as RoomAnnounced;
        expect(flat.waitingForInput, isTrue);

        final nested = ControlInbound.tryFromJson({
          'type': 'room_announced',
          'peer': 'epk_A',
          'room_id': 'r1',
          'started_at': 1700000000000,
          'meta': {'waiting_for_input': true},
        })! as RoomAnnounced;
        expect(nested.waitingForInput, isTrue);

        // Legacy relay without the field → null (preserve convention).
        final legacy = ControlInbound.tryFromJson({
          'type': 'room_announced',
          'peer': 'epk_A',
          'room_id': 'r1',
          'started_at': 1700000000000,
        })! as RoomAnnounced;
        expect(legacy.waitingForInput, isNull);
      },
    );

    test(
      'room_meta_updated tolerates missing meta / model (clears value)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'epk_A',
          'room_id': 'r1',
        });
        expect(c, isA<RoomMetaUpdated>());
        expect((c! as RoomMetaUpdated).model, isNull);
      },
    );

    test('RoomInfo serializes + parses model round-trip', () {
      const r = RoomInfo(
        roomId: 'r1',
        startedAt: 100,
        name: 'work',
        cwd: '/x',
        model: 'claude-sonnet-4.5',
      );
      final back = RoomInfo.fromJson(r.toJson());
      expect(back, r);
      expect(back.model, 'claude-sonnet-4.5');
    });

    test('RoomInfo round-trips waiting_for_input (plan 134; persisted cache)',
        () {
      const r = RoomInfo(
        roomId: 'r1',
        startedAt: 100,
        working: true,
        waitingForInput: true,
      );
      final json = r.toJson();
      expect(json['waiting_for_input'], isTrue,
          reason: 'always serialized so the persisted cache keeps the badge');
      final back = RoomInfo.fromJson(json);
      expect(back.waitingForInput, isTrue);
      expect(back, r);

      // Legacy JSON without the key defaults to false.
      expect(
        RoomInfo.fromJson({
          'room_id': 'r1',
          'started_at': 100,
        }).waitingForInput,
        isFalse,
      );
    });

    test('outbound subscribe_rooms helper has correct shape', () {
      expect(subscribeRoomsFrame(['a', 'b']), {
        'type': 'subscribe_rooms',
        'peers': ['a', 'b'],
      });
      expect(unsubscribeRoomsFrame(['a']), {
        'type': 'unsubscribe_rooms',
        'peers': ['a'],
      });
      expect(roomsCheckFrame(['a']), {
        'type': 'rooms_check',
        'peers': ['a'],
      });
    });

    test('route_error parses (plan/137) and defaults room to main', () {
      final c = ControlInbound.tryFromJson({
        'type': 'route_error',
        'peer': 'epk_A',
        'room': 'aB12CD34eF56',
      });
      expect(c, isA<RouteError>());
      final r = c! as RouteError;
      expect(r.peer, 'epk_A');
      expect(r.room, 'aB12CD34eF56');

      // A legacy/omitted room means the Pi's default room.
      final legacy = ControlInbound.tryFromJson({
        'type': 'route_error',
        'peer': 'epk_A',
      });
      expect((legacy! as RouteError).room, 'main');
    });
  });
}
