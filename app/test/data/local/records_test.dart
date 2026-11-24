// Plan/31 — record roundtrips + volatile runtime wipe on boot.

import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/domain/session_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  group('record roundtrips', () {
    test('MessageRecord (user + image) survives toJson/fromJson', () {
      final r = MessageRecord(
        id: 'u1',
        seq: 3,
        role: MsgRole.user,
        text: 'hello',
        image: const MessageImage(data: 'QUJD', mime: 'image/jpeg'),
        ts: DateTime.fromMillisecondsSinceEpoch(1700),
        pending: true,
        steering: true,
      );
      final back = MessageRecord.fromJson(r.toJson());
      expect(back.id, 'u1');
      expect(back.seq, 3);
      expect(back.role, MsgRole.user);
      expect(back.text, 'hello');
      expect(back.image?.data, 'QUJD');
      expect(back.pending, isTrue);
      expect(back.steering, isTrue);
      // Projects to the domain UserMsg the UI renders.
      final msg = back.toChatMessage() as UserMsg;
      expect(msg.status, UserMsgStatus.pending);
      expect(msg.steering, isTrue);
      expect(msg.image, isNotNull);
    });

    test('plan/127: MessageRecord (user follow-up) survives roundtrip', () {
      final r = MessageRecord(
        id: 'u-followup',
        seq: 5,
        role: MsgRole.user,
        text: 'then also run the tests',
        ts: DateTime.fromMillisecondsSinceEpoch(1700),
        followUp: true,
      );
      final back = MessageRecord.fromJson(r.toJson());
      expect(back.followUp, isTrue);
      expect(back.steering, isFalse);
      final msg = back.toChatMessage() as UserMsg;
      expect(msg.followUp, isTrue);
      expect(msg.steering, isFalse);
    });

    test('MessageRecord (tool) survives roundtrip', () {
      final r = MessageRecord(
        id: 'tc1',
        seq: 0,
        role: MsgRole.tool,
        ts: DateTime.fromMillisecondsSinceEpoch(1),
        tool: const ToolEventData(
          toolCallId: 'tc1',
          tool: 'Bash',
          args: {'cmd': 'ls'},
          status: ToolEventStatus.completed,
          result: {'exit': 0},
        ),
      );
      final back = MessageRecord.fromJson(r.toJson());
      expect(back.tool?.tool, 'Bash');
      expect(back.tool?.status, ToolEventStatus.completed);
      final evt = back.toChatMessage() as ToolEvent;
      expect(evt.toolCallId, 'tc1');
      expect(evt.status, ToolEventStatus.completed);
    });

    // --- Plan/172 — tool execution window on the persisted row ---------------

    test(
      'plan/172: the execution window survives the roundtrip + projects',
      () {
        final r = MessageRecord(
          id: 'tc1',
          seq: 0,
          role: MsgRole.tool,
          ts: DateTime.fromMillisecondsSinceEpoch(1200),
          tool: const ToolEventData(
            toolCallId: 'tc1',
            tool: 'Bash',
            status: ToolEventStatus.completed,
            replyAtMs: 1000,
            startedAtMs: 1200,
            endedAtMs: 8021,
            durationMs: 6821,
          ),
        );
        final back = MessageRecord.fromJson(r.toJson());
        expect(back.tool?.replyAtMs, 1000);
        expect(back.tool?.startedAtMs, 1200);
        expect(back.tool?.endedAtMs, 8021);
        expect(back.tool?.durationMs, 6821);

        final evt = back.toChatMessage() as ToolEvent;
        expect(evt.ts, DateTime.fromMillisecondsSinceEpoch(1200));
        expect(evt.replyAt, DateTime.fromMillisecondsSinceEpoch(1000));
        expect(evt.startedAt, DateTime.fromMillisecondsSinceEpoch(1200));
        expect(evt.endedAt, DateTime.fromMillisecondsSinceEpoch(8021));
        expect(evt.durationMs, 6821);
      },
    );

    test(
      'plan/172: a pre-172 row decodes with no window and stays identical',
      () {
        // Exactly what a pre-172 build wrote: no timing keys at all.
        final back = MessageRecord.fromJson({
          'id': 'tc1',
          'seq': 0,
          'role': 'tool',
          'text': '',
          'tool': {
            'tool_call_id': 'tc1',
            'tool': 'Bash',
            'args': null,
            'status': 'completed',
            'result': 'ok',
            'error': null,
          },
          'ts': 5,
          'pending': false,
        });
        expect(back.tool?.timingFieldCount, 0);
        // Re-serializing adds nothing: unknown values are omitted, not null.
        final toolJson = back.toJson()['tool'] as Map<String, dynamic>;
        expect(
          toolJson.keys,
          isNot(
            anyElement(
              isIn(['reply_at', 'started_at', 'ended_at', 'duration_ms']),
            ),
          ),
        );

        // The legacy row time still reaches the domain as the fallback stamp.
        final evt = back.toChatMessage() as ToolEvent;
        expect(evt.ts, DateTime.fromMillisecondsSinceEpoch(5));
        expect(evt.replyAt, isNull);
        expect(evt.startedAt, isNull);
        expect(evt.endedAt, isNull);
        expect(evt.durationMs, isNull);
      },
    );

    test('plan/172: every variant projects the row time into the domain', () {
      final ts = DateTime.fromMillisecondsSinceEpoch(777);
      MessageRecord rec(MsgRole role) =>
          MessageRecord(id: 'x', seq: 0, role: role, text: 't', ts: ts);
      expect((rec(MsgRole.user).toChatMessage() as UserMsg).ts, ts);
      expect((rec(MsgRole.assistant).toChatMessage() as AssistantMsg).ts, ts);
      expect((rec(MsgRole.compaction).toChatMessage() as CompactionMsg).ts, ts);
      // copyWith keeps the row time unless the Pi's echo supplies one.
      final u = rec(MsgRole.user);
      expect(u.copyWith(pending: false).ts, ts);
      expect(
        u.copyWith(ts: DateTime.fromMillisecondsSinceEpoch(9)).ts,
        DateTime.fromMillisecondsSinceEpoch(9),
      );
    });

    test('SessionIndexRecord survives roundtrip', () {
      final r = SessionIndexRecord(
        epk: 'epk1',
        roomId: 'main',
        displayName: 'proj',
        status: SessionActivity.working,
        lastMessageAt: DateTime.fromMillisecondsSinceEpoch(99),
        lastMessagePreview: 'hi',
        sessionStartedAt: DateTime.fromMillisecondsSinceEpoch(10),
      );
      final back = SessionIndexRecord.fromJson(r.toJson());
      expect(back, r);
      expect(back.status, SessionActivity.working);
    });

    test('RuntimeRecord survives roundtrip', () {
      const r = RuntimeRecord(
        connection: RuntimeConnection.online,
        presence: RuntimePresence.alive,
      );
      final back = RuntimeRecord.fromJson(r.toJson());
      expect(back, r);
    });
  });

  group('volatile runtime wipe (#3)', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('rp_v2_wipe_');
    });
    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test('runtime box opens EMPTY after a simulated restart', () async {
      await LocalBoxes.initForTest(dir.path);
      final boxes = LocalBoxes();
      // Seed runtime as if a prior run left an "online" record.
      await boxes.runtimeBox().put(
        'epk1:main',
        const RuntimeRecord(connection: RuntimeConnection.online).toJson(),
      );
      expect(boxes.runtimeBox().isEmpty, isFalse);

      // "Restart": re-init wipes the volatile box.
      await LocalBoxes.initForTest(dir.path);
      expect(
        boxes.runtimeBox().isEmpty,
        isTrue,
        reason: 'runtime must never survive a boot (#3)',
      );
    });
  });
}
