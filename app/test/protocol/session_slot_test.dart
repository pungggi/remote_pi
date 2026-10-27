// Plan/149 — session slot wire parsing: gh_ref / gh_suggestion / stats on
// room_announced, the rooms snapshot and room_meta_updated; display labels;
// set_session_ref request/reply shapes retained for client compatibility.

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('plan/149 room_announced carries the session slot', () {
    test('flat fields parse (post-relay-flatten)', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epkA',
        'room_id': 'r1',
        'started_at': 1700000000000,
        'gh_ref': {
          'pr': {
            'number': 70,
            'url': 'https://github.com/o/r/pull/70',
            'state': 'OPEN',
          },
          'source': 'gh',
        },
        'gh_suggestion': {
          'issue': {'number': 12, 'url': 'https://github.com/o/r/issues/12'},
          'source': 'chat',
        },
        'stats': {'turns': 3, 'user_msgs': 7},
      });
      final r = c! as RoomAnnounced;
      expect(r.ghRef?.pr?.number, 70);
      expect(r.ghRef?.pr?.state, 'OPEN');
      expect(r.ghRef?.source, 'gh');
      expect(r.ghSuggestion?.issue?.number, 12);
      expect(r.stats, const SessionStats(turns: 3, userMsgs: 7));
    });

    test('nested under meta parse too (pre-flatten relay)', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epkA',
        'room_id': 'r1',
        'started_at': 1700000000000,
        'meta': {
          'gh_ref': {
            'issue': {'number': 12},
            'source': 'manual',
          },
          'stats': {'turns': 1, 'user_msgs': 2},
        },
      });
      final r = c! as RoomAnnounced;
      expect(r.ghRef?.issue?.number, 12);
      expect(r.ghSuggestion, isNull);
      expect(r.stats?.turns, 1);
      expect(r.stats?.userMsgs, 2);
    });
  });

  group('plan/149 RoomInfo round-trips the slot', () {
    test('fromJson/toJson', () {
      final r = RoomInfo.fromJson({
        'room_id': 'r1',
        'started_at': 1700000000000,
        'gh_ref': {
          'pr': {'number': 70, 'url': 'https://github.com/o/r/pull/70'},
          'source': 'manual',
        },
        'stats': {'turns': 5, 'user_msgs': 9},
      });
      expect(r.ghRef?.pr?.number, 70);
      expect(r.stats?.turns, 5);
      final j = r.toJson();
      expect((j['gh_ref'] as Map)['pr'], isNotNull);
      expect((j['stats'] as Map)['user_msgs'], 9);
    });

    test('copyWith unset-sentinel distinguishes keep vs clear', () {
      final r = RoomInfo.fromJson({
        'room_id': 'r1',
        'started_at': 1,
        'gh_ref': {
          'pr': {'number': 70},
          'source': 'manual',
        },
        'stats': {'turns': 1, 'user_msgs': 1},
      });
      // Omitted → keep.
      expect(r.copyWith(name: 'x').ghRef?.pr?.number, 70);
      expect(r.copyWith().stats?.turns, 1);
      // Explicit null → clear.
      expect(r.copyWith(ghRef: null).ghRef, isNull);
      expect(r.copyWith(stats: null).stats, isNull);
    });
  });

  group('plan/149 room_meta_updated has-flag semantics', () {
    RoomMetaUpdated parse(Map<String, dynamic> meta) =>
        ControlInbound.tryFromJson({
              'type': 'room_meta_updated',
              'peer': 'epkA',
              'room_id': 'r1',
              'meta': meta,
            })!
            as RoomMetaUpdated;

    test('present-but-null gh_ref is a clear (hasGhRef, value null)', () {
      final u = parse({'gh_ref': null});
      expect(u.hasGhRef, isTrue);
      expect(u.ghRef, isNull);
    });

    test('absent gh_ref preserves (hasGhRef false)', () {
      final u = parse({'model': 'gpt-4o'});
      expect(u.hasGhRef, isFalse);
      expect(u.ghRef, isNull);
    });

    test('stats + gh_suggestion parse with flags', () {
      final u = parse({
        'stats': {'turns': 2, 'user_msgs': 4},
        'gh_suggestion': {
          'pr': {'number': 9},
          'source': 'chat',
        },
      });
      expect(u.hasStats, isTrue);
      expect(u.stats?.turns, 2);
      expect(u.hasGhSuggestion, isTrue);
      expect(u.ghSuggestion?.pr?.number, 9);
    });
  });

  group('plan/149 GhRef display label', () {
    test('label prefers the PR slot', () {
      expect(GhRef(pr: const GhRefSlot(number: 70)).label, 'PR #70');
      expect(GhRef(issue: const GhRefSlot(number: 12)).label, '#12');
      expect(const GhRef().label, '');
    });
  });

  group('plan/149 set_session_ref wire shapes', () {
    test('request serializes gh_ref + optional cwd', () {
      final req = SetSessionRefRequest(
        id: 'ref-1',
        roomId: 'r1',
        ghRef: GhRef(
          pr: const GhRefSlot(
            number: 70,
            url: 'https://github.com/o/r/pull/70',
          ),
        ),
      );
      final j = req.toJson();
      expect(j['type'], 'set_session_ref_request');
      expect(j['room_id'], 'r1');
      expect((j['gh_ref'] as Map)['pr'], isNotNull);
      expect(j.containsKey('cwd'), isFalse);
    });

    test('clear request serializes gh_ref null and passes cwd', () {
      final req = SetSessionRefRequest(
        id: 'ref-2',
        roomId: 'r1',
        ghRef: null,
        cwd: 'C:\\proj',
      );
      final j = req.toJson();
      expect(j['gh_ref'], isNull);
      expect(j['cwd'], 'C:\\proj');
    });

    test('result parses ok + message', () {
      final msg = ServerMessage.fromJson({
        'type': 'set_session_ref_result',
        'in_reply_to': 'ref-1',
        'ok': false,
        'message': 'unknown room (never registered on this PC)',
      });
      final r = msg as SetSessionRefResult;
      expect(r.inReplyTo, 'ref-1');
      expect(r.ok, isFalse);
      expect(r.message, contains('unknown room'));
    });
  });
}
