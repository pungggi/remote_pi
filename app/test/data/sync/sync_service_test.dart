// Plan/31 — SyncService is the single DB writer. Drives it through a fake
// channel adopted into a real ConnectionManager and asserts box contents.

import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _FakeChannel implements IChannel, IControlLink {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final _control = StreamController<ControlInbound>.broadcast();
  final List<ClientMessage> sent = [];

  /// Review #1 (PR #45) test hook: the next N `send` calls reject, mocking a
  /// channel that dies mid-teardown (close() racing the exposed handle).
  int failNextSends = 0;

  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Stream<ControlInbound> get controlFrames => _control.stream;
  @override
  Future<void> send(ClientMessage msg) async {
    if (failNextSends > 0) {
      failNextSends--;
      throw StateError('channel closing');
    }
    sent.add(msg);
  }
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> close() async {
    await _ctrl.close();
    await _control.close();
  }

  void push(ServerMessage m) => _ctrl.add(m);
  void pushControl(ControlInbound m) => _control.add(m);
}

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

int _counter = 0;

late Directory _dir;

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  setUpAll(() async {
    _dir = Directory.systemTemp.createTempSync('rp_v2_sync_');
    await LocalBoxes.initForTest(_dir.path);
  });
  tearDownAll(() async {
    await Hive.close();
    await _dir.delete(recursive: true);
  });

  Future<
    ({ConnectionManager conn, _FakeChannel ch, SyncService sync, String epk})
  >
  setup({
    Duration pendingSendTimeout = const Duration(seconds: 20),
    int? localHistoryMax,
    Duration syncRetryDelay = const Duration(seconds: 6),
  }) async {
    final ch = _FakeChannel();
    final conn = ConnectionManager(
      factory: (_, _) async => ch,
      storage: _FakeStorage(),
      emitDebounce: Duration.zero,
    );
    final boxes = LocalBoxes();
    final sync = SyncService(
      conn,
      boxes,
      pendingSendTimeout: pendingSendTimeout,
      localHistoryMax: localHistoryMax,
      syncRetryDelay: syncRetryDelay,
    );
    final epk = 'epk_sync_${++_counter}';
    conn.adopt(
      ch,
      PeerRecord(
        remoteEpk: epk,
        sessionName: 'Pi',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-01T00:00:00Z',
      ),
    );
    await _settle(); // _onlineActivated → activate(epk) settles
    return (conn: conn, ch: ch, sync: sync, epk: epk);
  }

  List<MessageRecord> messages(String epk) {
    final box = LocalBoxes().openMsgsBox(epk, 'main');
    final out = [
      for (final v in box.values)
        MessageRecord.fromJson((v as Map).cast<String, dynamic>()),
    ];
    out.sort((a, b) => a.seq.compareTo(b.seq));
    return out;
  }

  SessionIndexRecord? index(String epk) {
    final raw = LocalBoxes().sessionsIndexBox().get('$epk:main');
    return raw is Map
        ? SessionIndexRecord.fromJson(raw.cast<String, dynamic>())
        : null;
  }

  test(
    'user_message echo writes one MessageRecord + updates the index',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'hi'));
      await _settle();

      final m = messages(s.epk);
      expect(m, hasLength(1));
      expect(m.first.role, MsgRole.user);
      expect(m.first.text, 'hi');
      expect(m.first.pending, isFalse);
      expect(index(s.epk)?.status, SessionActivity.working);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('optimistic send + echo dedupe → exactly one record', () async {
    final s = await setup();
    await s.sync.sendMessage('hello');
    await _settle();
    expect(messages(s.epk), hasLength(1));
    expect(messages(s.epk).first.pending, isTrue);

    final id = (s.ch.sent.whereType<UserMessage>().last).id;
    s.ch.push(UserInput(id: id, text: 'hello'));
    await _settle();

    final m = messages(s.epk);
    expect(m, hasLength(1), reason: 'echo dedupes by id — no duplicate');
    expect(m.first.pending, isFalse);
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'steer send keeps active working target and sets streaming behavior on wire',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'primary'));
      await _settle();

      await s.sync.sendMessage(
        'refine this',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      );
      await _settle();

      final sent = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'refine this',
      );
      expect(sent.streamingBehavior, UserMessageStreamingBehavior.steer);
      final steerRow = messages(s.epk).singleWhere((r) => r.id == sent.id);
      expect(steerRow.pending, isTrue);
      expect(steerRow.steering, isTrue);
      expect((steerRow.toChatMessage() as UserMsg).steering, isTrue);
      expect(s.sync.workingReplyTo, 'u1');
      expect(s.sync.streaming, isNotNull);
      expect(s.sync.streaming!.inReplyTo, 'u1');
      expect(s.sync.isWorking, isTrue);

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('steer echo confirms row without replacing working turn', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'u1', text: 'primary'));
    await _settle();
    expect(s.sync.workingReplyTo, 'u1');

    await s.sync.sendMessage(
      'refine this',
      streamingBehavior: UserMessageStreamingBehavior.steer,
    );
    await _settle();
    final sent = s.ch.sent.whereType<UserMessage>().lastWhere(
      (m) => m.text == 'refine this',
    );

    s.ch.push(
      UserInput(
        id: sent.id,
        text: 'refine this',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      ),
    );
    await _settle();

    expect(s.sync.workingReplyTo, 'u1');
    expect(s.sync.streaming, isNotNull);
    expect(s.sync.streaming!.inReplyTo, 'u1');
    expect(s.sync.isWorking, isTrue);
    final rows = messages(s.epk);
    expect(rows, hasLength(2));
    var steerRow = rows.where((r) => r.id == sent.id).single;
    expect(steerRow.pending, isFalse);
    expect(steerRow.steering, isTrue, reason: 'echo only means accepted');
    expect((steerRow.toChatMessage() as UserMsg).steering, isTrue);
    expect(index(s.epk)?.status, SessionActivity.working);
    expect(index(s.epk)?.lastMessagePreview, 'refine this');

    s.ch.push(SteerConsumed(id: sent.id));
    await _settle();

    steerRow = messages(s.epk).where((r) => r.id == sent.id).single;
    expect(steerRow.pending, isFalse);
    expect(
      steerRow.steering,
      isFalse,
      reason: 'actual queue delivery clears label',
    );
    expect((steerRow.toChatMessage() as UserMsg).steering, isFalse);

    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'plan/127: followUp send keeps active working target and sets wire behavior',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'primary'));
      await _settle();

      await s.sync.sendMessage(
        'then also run the tests',
        streamingBehavior: UserMessageStreamingBehavior.followUp,
      );
      await _settle();

      final sent = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'then also run the tests',
      );
      expect(sent.streamingBehavior, UserMessageStreamingBehavior.followUp);
      final row = messages(s.epk).singleWhere((r) => r.id == sent.id);
      expect(row.pending, isTrue);
      expect(row.followUp, isTrue);
      expect((row.toChatMessage() as UserMsg).followUp, isTrue);
      // Like steer, a follow-up does not start a fresh turn / cursor.
      expect(s.sync.workingReplyTo, 'u1');
      expect(s.sync.streaming, isNotNull);
      expect(s.sync.streaming!.inReplyTo, 'u1');

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'plan/127: followUp echo confirms row without replacing working turn',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'primary'));
      await _settle();
      expect(s.sync.workingReplyTo, 'u1');

      await s.sync.sendMessage(
        'then also run the tests',
        streamingBehavior: UserMessageStreamingBehavior.followUp,
      );
      await _settle();
      final sent = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'then also run the tests',
      );

      s.ch.push(
        UserInput(
          id: sent.id,
          text: 'then also run the tests',
          streamingBehavior: UserMessageStreamingBehavior.followUp,
        ),
      );
      await _settle();

      // Echo only confirms the row; the active streaming bubble / cancel
      // target are untouched (the follow-up's own turn streams later).
      expect(s.sync.workingReplyTo, 'u1');
      expect(s.sync.streaming, isNotNull);
      expect(s.sync.streaming!.inReplyTo, 'u1');
      final rows = messages(s.epk);
      expect(rows, hasLength(2));
      final row = rows.where((r) => r.id == sent.id).single;
      expect(row.pending, isFalse);
      expect(row.followUp, isTrue);

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'plan/127: foreign-device followUp echo carries the marker (cross-owner)',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'primary'));
      await _settle();

      // Another paired owner sent a follow-up; the echo reaches this device,
      // which has no local optimistic row for it. It must still render as a
      // follow-up bubble (clock marker), not a normal one.
      s.ch.push(
        UserInput(
          id: 'fu-foreign',
          text: 'queued from the other phone',
          streamingBehavior: UserMessageStreamingBehavior.followUp,
        ),
      );
      await _settle();

      final row = messages(s.epk).singleWhere((r) => r.id == 'fu-foreign');
      expect(row.pending, isFalse);
      expect(row.followUp, isTrue, reason: 'foreign echo must carry the marker');
      expect((row.toChatMessage() as UserMsg).followUp, isTrue);

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'plan/127: session_history reconnect preserves the followUp marker',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'primary'));
      await _settle();

      await s.sync.sendMessage(
        'then also run the tests',
        streamingBehavior: UserMessageStreamingBehavior.followUp,
      );
      await _settle();
      final sent = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'then also run the tests',
      );
      s.ch.push(
        UserInput(
          id: sent.id,
          text: 'then also run the tests',
          streamingBehavior: UserMessageStreamingBehavior.followUp,
        ),
      );
      await _settle();
      expect(
        messages(s.epk).singleWhere((r) => r.id == sent.id).followUp,
        isTrue,
        reason: 'precondition: marker set before reconnect',
      );

      // Reconnect/reload: Pi's session_history user events carry no
      // streaming_behavior, so the follow-up would otherwise rebuild as a
      // plain row and the marker would be wiped.
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync-reconnect',
          sessionStartedAt: 0,
          events: [
            UserInputEvt(ts: 1, id: 'u1', text: 'primary'),
            UserInputEvt(ts: 2, id: sent.id, text: 'then also run the tests'),
          ],
          eos: true,
        ),
      );
      await _settle();

      final row = messages(s.epk).singleWhere((r) => r.id == sent.id);
      expect(
        row.followUp,
        isTrue,
        reason: 'history reconcile must preserve the followUp marker',
      );
      expect((row.toChatMessage() as UserMsg).followUp, isTrue);

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'steer_consumed clears one steering label, not every queued steer',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'primary'));
      await _settle();

      await s.sync.sendMessage(
        'first steer',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      );
      await s.sync.sendMessage(
        'second steer',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      );
      await _settle();
      final first = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'first steer',
      );
      final second = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'second steer',
      );
      for (final sent in [first, second]) {
        s.ch.push(
          UserInput(
            id: sent.id,
            text: sent.text,
            streamingBehavior: UserMessageStreamingBehavior.steer,
          ),
        );
      }
      await _settle();
      expect(
        messages(s.epk).where((r) => r.id == first.id).single.steering,
        isTrue,
      );
      expect(
        messages(s.epk).where((r) => r.id == second.id).single.steering,
        isTrue,
      );

      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'working'));
      await _settle();
      expect(
        messages(s.epk).where((r) => r.id == first.id).single.steering,
        isTrue,
      );
      expect(
        messages(s.epk).where((r) => r.id == second.id).single.steering,
        isTrue,
      );

      s.ch.push(SteerConsumed(id: first.id));
      await _settle();

      expect(
        messages(s.epk).where((r) => r.id == first.id).single.steering,
        isFalse,
      );
      expect(
        messages(s.epk).where((r) => r.id == second.id).single.steering,
        isTrue,
      );
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('agent_done clears only its steering label as a fallback', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'u1', text: 'primary'));
    await _settle();

    await s.sync.sendMessage(
      'first steer',
      streamingBehavior: UserMessageStreamingBehavior.steer,
    );
    await s.sync.sendMessage(
      'second steer',
      streamingBehavior: UserMessageStreamingBehavior.steer,
    );
    await _settle();
    final first = s.ch.sent.whereType<UserMessage>().lastWhere(
      (m) => m.text == 'first steer',
    );
    final second = s.ch.sent.whereType<UserMessage>().lastWhere(
      (m) => m.text == 'second steer',
    );
    for (final sent in [first, second]) {
      s.ch.push(
        UserInput(
          id: sent.id,
          text: sent.text,
          streamingBehavior: UserMessageStreamingBehavior.steer,
        ),
      );
    }
    await _settle();
    expect(
      messages(s.epk).where((r) => r.id == first.id).single.steering,
      isTrue,
    );
    expect(
      messages(s.epk).where((r) => r.id == second.id).single.steering,
      isTrue,
    );

    s.ch.push(AgentDone(inReplyTo: first.id));
    await _settle();

    expect(
      messages(s.epk).where((r) => r.id == first.id).single.steering,
      isFalse,
    );
    expect(
      messages(s.epk).where((r) => r.id == second.id).single.steering,
      isTrue,
    );
    s.conn.dispose();
    s.sync.dispose();
  });

  test('streaming delta does NOT write to the DB (#7)', () async {
    final s = await setup();
    final before = messages(s.epk).length;
    s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'partial...'));
    await _settle();
    expect(messages(s.epk).length, before, reason: 'no row for a delta');
    expect(s.sync.streaming, isNotNull);
    expect(s.sync.streaming!.buffer, 'partial...');
    s.conn.dispose();
    s.sync.dispose();
  });

  test('agent_done finalizes the streamed message + flips to idle', () async {
    final s = await setup();
    s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'done text'));
    await _settle();
    s.ch.push(AgentDone(inReplyTo: 'r1'));
    await _settle();

    final assistant = messages(
      s.epk,
    ).where((m) => m.role == MsgRole.assistant).toList();
    expect(assistant, hasLength(1));
    expect(assistant.first.text, 'done text');
    expect(s.sync.streaming, isNull);
    expect(index(s.epk)?.status, SessionActivity.idle);
    s.conn.dispose();
    s.sync.dispose();
  });

  test('cancel sends a Cancel frame for the active turn target', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'u1', text: 'hi'));
    await _settle();

    await s.sync.cancel('u1');
    await _settle();

    final cancel = s.ch.sent.whereType<Cancel>().single;
    expect(cancel.targetId, 'u1');
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'cancelled stops the turn but preserves confirmed user history',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'keep this'));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'partial'));
      s.ch.push(Cancelled(inReplyTo: 'cancel-1', targetId: 'u1'));
      await _settle();

      final rows = messages(s.epk);
      expect(
        rows.where((m) => m.id == 'u1' && m.role == MsgRole.user),
        hasLength(1),
      );
      expect(rows.singleWhere((m) => m.id == 'u1').pending, isFalse);
      expect(s.sync.streaming, isNull);
      expect(s.sync.isWorking, isFalse);
      expect(index(s.epk)?.status, SessionActivity.idle);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('cancelled removes a still-pending optimistic user row', () async {
    final s = await setup();
    await s.sync.sendMessage('stop before echo');
    await _settle();
    final id = (s.ch.sent.whereType<UserMessage>().last).id;
    expect(messages(s.epk).single.pending, isTrue);

    s.ch.push(Cancelled(inReplyTo: 'cancel-1', targetId: id));
    await _settle();

    expect(messages(s.epk), isEmpty);
    expect(s.sync.streaming, isNull);
    expect(s.sync.isWorking, isFalse);
    expect(index(s.epk)?.status, SessionActivity.idle);
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'server error persists streamed partial text, then shows the error',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'hi'));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'partial'));
      s.ch.push(
        ErrorMessage(
          inReplyTo: 'cancel-1',
          code: 'internal_error',
          message: 'No active Pi context to abort',
        ),
      );
      await _settle();

      expect(s.sync.streaming, isNull);
      expect(s.sync.isWorking, isFalse);
      expect(index(s.epk)?.status, SessionActivity.idle);
      // PR #34 review — the streamed tail must survive the error (finalized
      // as an assistant row in seq order before the ⚠ bubble), not vanish
      // with the discarded flush timer.
      final texts = messages(
        s.epk,
      ).where((m) => m.role == MsgRole.assistant).map((m) => m.text).toList();
      expect(texts.first, 'partial');
      expect(texts.last, startsWith('⚠ internal_error:'));
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('isWorking spans the whole turn (echo → agent_done)', () async {
    final s = await setup();
    expect(s.sync.isWorking, isFalse);
    final flags = <bool>[];
    final sub = s.sync.workingStream.listen(flags.add);

    s.ch.push(UserInput(id: 'u1', text: 'hi'));
    await _settle();
    expect(s.sync.isWorking, isTrue, reason: 'working from the echo');

    s.ch.push(AgentDone(inReplyTo: 'u1'));
    await _settle();
    expect(s.sync.isWorking, isFalse, reason: 'idle after agent_done');
    expect(flags, [true, false]);

    await sub.cancel();
    s.conn.dispose();
    s.sync.dispose();
  });

  test('switching sessions resets the in-memory turn state — working/streaming '
      'do NOT leak into the next chat (plan/32)', () async {
    final s = await setup();

    // Session 1 is mid-turn: working flag + streaming buffer populated.
    s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'thinking...'));
    await _settle();
    expect(s.sync.isWorking, isTrue);
    expect(s.sync.streaming, isNotNull);
    expect(s.sync.workingReplyTo, 'r1');

    final flags = <bool>[];
    final sub = s.sync.workingStream.listen(flags.add);

    // Switch the writer to a DIFFERENT session (what the chat does on a
    // tablet session switch). Must clear the in-memory signals.
    await s.sync.activate('epk_other_session', 'main');
    await _settle();

    expect(
      s.sync.isWorking,
      isFalse,
      reason: 'chat 2 must not inherit chat 1 working',
    );
    expect(
      s.sync.streaming,
      isNull,
      reason: 'chat 1 streaming buffer must not show in chat 2',
    );
    expect(s.sync.workingReplyTo, isNull);
    expect(
      flags,
      contains(false),
      reason: 'listeners are notified the flag cleared',
    );

    // The previous session's DURABLE index must stay "working" — the Pi
    // may still be mid-turn and Home reflects it (relay broadcast + DB).
    // Clearing the in-memory signals must NOT idle the box row.
    expect(
      index(s.epk)?.status,
      SessionActivity.working,
      reason: 'switching away must not idle chat 1 in the DB',
    );

    await sub.cancel();
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'cursor: streaming is seeded EMPTY at turn start, before any chunk',
    () async {
      final s = await setup();
      expect(s.sync.streaming, isNull);

      // Optimistic send seeds the thinking cursor (online).
      await s.sync.sendMessage('hi');
      await _settle();
      expect(s.sync.streaming, isNotNull, reason: 'cursor during thinking');
      expect(s.sync.streaming!.buffer, isEmpty);

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'cursor: foreign echo seeds it; a text-less turn clears it on done',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u9', text: 'from terminal'));
      await _settle();
      expect(s.sync.streaming, isNotNull, reason: 'cursor before any chunk');
      expect(s.sync.streaming!.buffer, isEmpty);

      // Turn produces no text (e.g. only tool calls) → done still clears it.
      s.ch.push(AgentDone(inReplyTo: 'u9'));
      await _settle();
      expect(s.sync.streaming, isNull, reason: 'done clears the cursor');
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('cursor: a chunk appends onto the seeded empty buffer', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'u1', text: 'hi'));
    await _settle();
    s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'tok'));
    await _settle();
    expect(s.sync.streaming!.buffer, 'tok', reason: 'appended, not replaced');
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'sequential: text → tool → text renders in chronological order',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'go'));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'let me check'));
      await _settle(); // 16ms flush settles into the streaming buffer
      s.ch.push(ToolRequest(toolCallId: 'tc1', tool: 'Read', args: {}));
      await _settle();
      s.ch.push(ToolResult(toolCallId: 'tc1', result: {'ok': true}));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'all done'));
      await _settle();
      s.ch.push(AgentDone(inReplyTo: 'u1'));
      await _settle();

      final m = messages(s.epk);
      expect(
        m.map((r) => r.role),
        [MsgRole.user, MsgRole.assistant, MsgRole.tool, MsgRole.assistant],
        reason: 'pre-tool text, then tool, then post-tool text — in order',
      );
      expect(m[1].text, 'let me check');
      expect(m[2].tool?.tool, 'Read');
      expect(m[3].text, 'all done');
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('re-applying an IDENTICAL SessionHistory is idempotent — no box churn, '
      'so the relay re-sending history on every reconnect no longer tears the '
      'list down and rebuilds it (plan/32 flicker fix)', () async {
    final s = await setup();
    final read = SessionReadRepository(LocalBoxes());
    var emits = 0;
    final sub = read.watchMessages(s.epk, 'main').listen((_) => emits++);
    await _settle();

    SessionHistory hist(String inReplyTo) => SessionHistory(
      inReplyTo: inReplyTo,
      sessionStartedAt: 0,
      events: const [
        UserInputEvt(ts: 1, id: 'u1', text: 'hi'),
        AgentMessageEvt(ts: 2, inReplyTo: 'a1', text: 'hello'),
        ToolRequestEvt(ts: 3, toolCallId: 'c1', tool: 'Read', args: null),
      ],
      eos: true,
    );

    s.ch.push(hist('sync1'));
    await _settle();
    final afterFirst = emits;
    expect(afterFirst, greaterThan(1), reason: 'first apply populates rows');
    expect(messages(s.epk).map((r) => r.role), [
      MsgRole.user,
      MsgRole.assistant,
      MsgRole.tool,
    ]);

    // Relay re-delivers the SAME history (different in_reply_to, identical
    // events) — the reconcile must write nothing → no watch event → no emit.
    s.ch.push(hist('sync2'));
    await _settle();
    expect(
      emits,
      afterFirst,
      reason: 'identical re-apply must not emit (no list rebuild/flicker)',
    );

    await sub.cancel();
    s.conn.dispose();
    s.sync.dispose();
  });

  // ── Plan/128: durable append-only merge ─────────────────────────────────

  test(
    'plan/128: an EMPTY session_history with an UNCHANGED session does NOT '
    'wipe the local box (the offline / Pi-restart disappear bug)',
    () async {
      final s = await setup();
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 1000,
          events: const [
            UserInputEvt(ts: 1, id: 'u1', text: 'hi'),
            AgentMessageEvt(ts: 2, inReplyTo: 'a1', text: 'hello'),
          ],
          eos: true,
        ),
      );
      await _settle();
      expect(messages(s.epk), hasLength(2));

      // Pi process restarted → server buffer wiped → relay re-delivers EMPTY
      // history with the SAME session_started_at. The old substitutive code
      // deleted every local row; the merge must be a no-op.
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync2',
          sessionStartedAt: 1000,
          events: const [],
          eos: true,
        ),
      );
      await _settle();
      expect(
        messages(s.epk),
        hasLength(2),
        reason: 'empty history, same session → local rows preserved',
      );

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'plan/128: a legacy Pi (session_started_at == 0) returning empty history '
    'does NOT wipe the local box',
    () async {
      final s = await setup();
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 1000,
          events: const [UserInputEvt(ts: 1, id: 'u1', text: 'hi')],
          eos: true,
        ),
      );
      await _settle();
      expect(messages(s.epk), hasLength(1));

      // Legacy/no-session Pi echoes session_started_at: 0 + empty events.
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync2',
          sessionStartedAt: 0,
          events: const [],
          eos: true,
        ),
      );
      await _settle();
      expect(
        messages(s.epk),
        hasLength(1),
        reason: 'session_started_at == 0 → never treat as a new session',
      );

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'plan/128: a genuine session_started_at change clears the box and seeds '
    'the new conversation (new session started on the Pi)',
    () async {
      final s = await setup();
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 1000,
          events: const [UserInputEvt(ts: 1, id: 'old1', text: 'old turn')],
          eos: true,
        ),
      );
      await _settle();
      expect(messages(s.epk).map((r) => r.id), ['old1']);

      // User started a NEW session on the Pi → fresh session_started_at.
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync2',
          sessionStartedAt: 2000,
          events: const [UserInputEvt(ts: 10, id: 'new1', text: 'new turn')],
          eos: true,
        ),
      );
      await _settle();

      final m = messages(s.epk);
      expect(
        m.map((r) => r.id),
        ['new1'],
        reason: 'old conversation cleared; only the new session remains',
      );
      expect(index(s.epk)?.sessionStartedAt?.millisecondsSinceEpoch, 2000);

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'plan/128 (review C1): a Pi RESTART restamps session_started_at but re-sends '
    'OVERLAPPING rows ⇒ NO wipe (durability preserved)',
    () async {
      final s = await setup();
      s.ch.push(
        SessionHistory(
          inReplyTo: 's1',
          sessionStartedAt: 1000,
          events: const [
            UserInputEvt(ts: 1, id: 'u1', text: 'one'),
            AgentMessageEvt(ts: 2, inReplyTo: 'a1', text: 'r1'),
            UserInputEvt(ts: 3, id: 'u2', text: 'two'),
          ],
          eos: true,
        ),
      );
      await _settle();
      expect(messages(s.epk).map((r) => r.id), ['u1', 'a1', 'u2']);

      // Pi restarts: fresh session_started_at (Date.now()), SAME transcript.
      // The newest-page sync re-sends u2 (overlap) + a brand-new u3.
      s.ch.push(
        SessionHistory(
          inReplyTo: 's2',
          sessionStartedAt: 9999,
          events: const [
            UserInputEvt(ts: 3, id: 'u2', text: 'two'), // OVERLAP ⇒ not a new session
            UserInputEvt(ts: 4, id: 'u3', text: 'three'),
          ],
          eos: true,
        ),
      );
      await _settle();
      expect(
        messages(s.epk).map((r) => r.id),
        ['u1', 'a1', 'u2', 'u3'],
        reason: 'restart re-sends an overlapping row ⇒ no wipe; u1/a1 survive',
      );
      expect(
        index(s.epk)?.sessionStartedAt?.millisecondsSinceEpoch,
        9999,
        reason: 'stored session_started_at still advances',
      );
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'plan/128 (review C5): a result-only page then a request page merge into '
    'one COMPLETE tool row (name+args+result)',
    () async {
      final s = await setup();
      // Newest page has ONLY the result (no request) ⇒ 'unknown' tool row.
      s.ch.push(
        SessionHistory(
          inReplyTo: 's1',
          sessionStartedAt: 1000,
          events: const [
            ToolResultEvt(ts: 2, toolCallId: 'tc1', result: '42'),
          ],
          eos: true,
        ),
      );
      await _settle();
      var t = messages(s.epk).firstWhere((r) => r.id == 'tc1');
      expect(t.tool?.tool, 'unknown', reason: 'result-only page ⇒ unknown name');
      expect(t.tool?.result, '42');

      // Older page brings the request ⇒ merge fills in the name + args.
      s.ch.push(
        SessionHistory(
          inReplyTo: 's2',
          sessionStartedAt: 1000,
          events: const [
            ToolRequestEvt(
              ts: 1,
              toolCallId: 'tc1',
              tool: 'bash',
              args: {'cmd': 'ls'},
            ),
          ],
          eos: true,
        ),
      );
      await _settle();
      t = messages(s.epk).firstWhere((r) => r.id == 'tc1');
      expect(t.tool?.tool, 'bash', reason: 'request filled in the tool name');
      expect(t.tool?.args, {'cmd': 'ls'});
      expect(t.tool?.result, '42', reason: 'result preserved across the merge');
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'plan/128: a growing server window MERGES — existing rows keep their seq '
    'and rows that scrolled off the server window are kept locally '
    '(durability)',
    () async {
      final s = await setup();
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 1000,
          events: const [
            UserInputEvt(ts: 1, id: 'u1', text: 'one'),
            AgentMessageEvt(ts: 2, inReplyTo: 'a1', text: 'resp1'),
          ],
          eos: true,
        ),
      );
      await _settle();
      final u1seq = messages(s.epk).firstWhere((r) => r.id == 'u1').seq;
      expect(u1seq, 0);

      // Server window grew by one turn; u1/a1 still present. Merge must NOT
      // re-seq the existing rows.
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync2',
          sessionStartedAt: 1000,
          events: const [
            UserInputEvt(ts: 1, id: 'u1', text: 'one'),
            AgentMessageEvt(ts: 2, inReplyTo: 'a1', text: 'resp1'),
            UserInputEvt(ts: 3, id: 'u2', text: 'two'),
            AgentMessageEvt(ts: 4, inReplyTo: 'a2', text: 'resp2'),
          ],
          eos: true,
        ),
      );
      await _settle();

      final m = messages(s.epk);
      expect(m.map((r) => r.id), ['u1', 'a1', 'u2', 'a2']);
      expect(
        m.firstWhere((r) => r.id == 'u1').seq,
        u1seq,
        reason: 'existing rows keep their storage identity',
      );

      // Server window slid: u1 dropped server-side, but u1 must SURVIVE
      // locally (durability) while u3 appends.
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync3',
          sessionStartedAt: 1000,
          events: const [
            AgentMessageEvt(ts: 2, inReplyTo: 'a1', text: 'resp1'),
            UserInputEvt(ts: 3, id: 'u2', text: 'two'),
            AgentMessageEvt(ts: 4, inReplyTo: 'a2', text: 'resp2'),
            UserInputEvt(ts: 5, id: 'u3', text: 'three'),
          ],
          eos: true,
        ),
      );
      await _settle();
      expect(
        messages(s.epk).map((r) => r.id),
        ['u1', 'a1', 'u2', 'a2', 'u3'],
        reason: 'u1 (dropped server-side) is kept locally; u3 appends',
      );

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'plan/128: a history replay confirms a pending user send (clears '
    'pending, no duplicate)',
    () async {
      final s = await setup();
      await s.sync.sendMessage('hi');
      await _settle();
      final sent = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'hi',
      );
      expect(
        messages(s.epk).firstWhere((r) => r.id == sent.id).pending,
        isTrue,
        reason: 'precondition: optimistic row is pending',
      );

      // Relay replays history that includes our send → pending must clear and
      // no duplicate row may appear.
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 1000,
          events: [UserInputEvt(ts: 1, id: sent.id, text: 'hi')],
          eos: true,
        ),
      );
      await _settle();

      final rows = messages(s.epk).where((r) => r.id == sent.id).toList();
      expect(rows, hasLength(1), reason: 'no duplicate');
      expect(rows.first.pending, isFalse, reason: 'history replay confirms send');

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'switching the writer to a new session: a late frame from the OLD '
    "connection is dropped — it neither writes the new box nor appears in the "
    "new session's read projection (plan/32f session-switch bleed)",
    () async {
      final s = await setup(); // bound to s.epk (peer A)
      s.ch.push(UserInput(id: 'a1', text: 'from chat1'));
      await _settle();
      expect(messages(s.epk), hasLength(1));

      // Switch the writer to chat 2 (epkB) WITHOUT a new channel — simulates
      // the window where the chat calls activate(epkB) before switchTo tears
      // the old peer's channel down. _activeEpk moves; the old channel (origin
      // = peer A) is still draining.
      const epkB = 'epk_chat2_zzz';
      final read = SessionReadRepository(LocalBoxes());
      final seenLens = <int>[];
      final sub = read
          .watchMessages(epkB, 'main')
          .listen((rows) => seenLens.add(rows.length));
      await s.sync.activate(epkB, 'main');
      await _settle();

      // Straggler frame on the OLD (peer A) channel.
      s.ch.push(UserInput(id: 'late', text: 'late chat1'));
      await _settle();

      expect(
        messages(epkB),
        isEmpty,
        reason: 'old-connection frame must not bleed into the new box',
      );
      expect(
        seenLens.every((n) => n == 0),
        isTrue,
        reason: "chat 2's projection never shows chat 1 rows",
      );
      expect(
        messages(s.epk),
        hasLength(1),
        reason: 'chat 1 box keeps exactly its own row (late frame dropped)',
      );

      await sub.cancel();
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('compaction ServerMessage writes a system row that projects to a '
      'CompactionMsg system bubble (plan/32)', () async {
    final s = await setup();
    s.ch.push(
      Compaction(
        summary: 'recapped the thread',
        tokensBefore: 12000,
        ts: 1700000000000,
      ),
    );
    await _settle();

    final m = messages(s.epk);
    expect(m, hasLength(1));
    expect(m.first.role, MsgRole.compaction);
    expect(m.first.text, 'recapped the thread');
    expect(m.first.tokensBefore, 12000);
    // Projects to the domain system-bubble message.
    expect(m.first.toChatMessage(), isA<CompactionMsg>());

    s.conn.dispose();
    s.sync.dispose();
  });

  test('compaction event in session_history reconstructs the system row on '
      're-sync (plan/32)', () async {
    final s = await setup();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: const [
          UserInputEvt(ts: 1, id: 'u1', text: 'hi'),
          AgentMessageEvt(ts: 2, inReplyTo: 'a1', text: 'hello'),
          CompactionEvt(ts: 3, summary: 'compacted', tokensBefore: 5000),
        ],
        eos: true,
      ),
    );
    await _settle();

    final m = messages(s.epk);
    expect(m.map((r) => r.role), [
      MsgRole.user,
      MsgRole.assistant,
      MsgRole.compaction,
    ]);
    expect(m.last.text, 'compacted');
    expect(m.last.tokensBefore, 5000);
    expect(m.last.toChatMessage(), isA<CompactionMsg>());

    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'clearActiveSession wipes rows, index, and in-memory turn state',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'hi'));
      await _settle();
      expect(messages(s.epk), hasLength(1));
      expect(s.sync.isWorking, isTrue);
      expect(s.sync.streaming, isNotNull);

      await s.sync.clearActiveSession();
      await _settle();
      expect(messages(s.epk), isEmpty);
      expect(index(s.epk), isNull);
      expect(s.sync.isWorking, isFalse);
      expect(s.sync.streaming, isNull);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'relay working=false clears stale active-chat local working state',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'hi'));
      await _settle();
      expect(s.sync.isWorking, isTrue);

      s.ch.pushControl(
        RoomAnnounced(peer: s.epk, roomId: 'main', startedAt: 1),
      );
      s.ch.pushControl(
        RoomMetaUpdated(
          peer: s.epk,
          roomId: 'main',
          working: true,
          hasModel: false,
          hasThinking: false,
        ),
      );
      await _settle();
      expect(s.sync.isWorking, isTrue);

      s.ch.pushControl(
        RoomMetaUpdated(
          peer: s.epk,
          roomId: 'main',
          working: false,
          hasModel: false,
          hasThinking: false,
        ),
      );
      await _settle();
      expect(s.conn.isRoomWorking(s.epk, 'main'), isFalse);
      expect(s.sync.isWorking, isFalse);
      expect(s.sync.streaming, isNull);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  // ── Plan/128 step 6: local retention cap (default off) ──────────────────
  group('plan/128 step 6: local retention cap', () {
    List<SessionHistoryEvent> userEvents(int n) => [
      for (var i = 1; i <= n; i++) UserInputEvt(ts: i, id: 'u$i', text: 'm$i'),
    ];

    test(
      'cap set: once the box exceeds cap+headroom, the OLDEST rows (by ts) '
      'are evicted down to cap; newest kept',
      () async {
        // cap=10 ⇒ headroom = max(1, 1) = 1 ⇒ trigger when box.length > 11.
        final s = await setup(localHistoryMax: 10);
        s.ch.push(
          SessionHistory(
            inReplyTo: 's1',
            sessionStartedAt: 1000,
            events: userEvents(12),
            eos: true,
          ),
        );
        await _settle();
        // 12 landed → evict the 2 oldest by ts (u1, u2) → cap (10) kept.
        expect(
          messages(s.epk).map((r) => r.id),
          [for (var i = 3; i <= 12; i++) 'u$i'],
        );
        s.conn.dispose();
        s.sync.dispose();
      },
    );

    test(
      'cap default OFF (null): the box grows without bound — no eviction',
      () async {
        final s = await setup(); // no localHistoryMax
        s.ch.push(
          SessionHistory(
            inReplyTo: 's1',
            sessionStartedAt: 1000,
            events: userEvents(12),
            eos: true,
          ),
        );
        await _settle();
        expect(
          messages(s.epk).map((r) => r.id),
          [for (var i = 1; i <= 12; i++) 'u$i'],
        );
        s.conn.dispose();
        s.sync.dispose();
      },
    );

    test(
      'cap hysteresis: at exactly cap+headroom nothing is evicted (no '
      'one-row-at-a-time thrash)',
      () async {
        // cap=10, headroom=1 ⇒ boundary at 11. 11 rows ⇒ no eviction.
        final s = await setup(localHistoryMax: 10);
        s.ch.push(
          SessionHistory(
            inReplyTo: 's1',
            sessionStartedAt: 1000,
            events: userEvents(11),
            eos: true,
          ),
        );
        await _settle();
        expect(
          messages(s.epk).length,
          11,
          reason: 'at cap+headroom (11), no eviction yet',
        );
        s.conn.dispose();
        s.sync.dispose();
      },
    );

    test(
      'eviction cleans the dedupe index: a re-sent evicted id re-appends '
      'at a FRESH seq (no stale-slot resurrection)',
      () async {
        final s = await setup(localHistoryMax: 10);
        // 12 → evict the 2 oldest by ts (u1, u2) → box u3..u12 (10), _nextSeq=12.
        s.ch.push(
          SessionHistory(
            inReplyTo: 's1',
            sessionStartedAt: 1000,
            events: userEvents(12),
            eos: true,
          ),
        );
        await _settle();
        expect(
          messages(s.epk).map((r) => r.id),
          [for (var i = 3; i <= 12; i++) 'u$i'],
        );
        // Re-sync sends the EVICTED u1 back. With _idToSeq cleaned, u1
        // re-appends at a fresh seq (12); without cleanup it would resurrect
        // at the vacant seq 0. Box is now 11 (== cap+headroom) ⇒ no eviction.
        s.ch.push(
          SessionHistory(
            inReplyTo: 's2',
            sessionStartedAt: 1000,
            events: [
              UserInputEvt(ts: 1, id: 'u1', text: 'm1'),
              ...[
                for (var i = 3; i <= 12; i++)
                  UserInputEvt(ts: i, id: 'u$i', text: 'm$i'),
              ],
            ],
            eos: true,
          ),
        );
        await _settle();
        final m = messages(s.epk);
        expect(
          m.any((r) => r.id == 'u1'),
          isTrue,
          reason: 'evicted u1 re-appended when the server re-sent it',
        );
        expect(
          m.firstWhere((r) => r.id == 'u1').seq,
          greaterThanOrEqualTo(12),
          reason: 'fresh seq, not the resurrected stale slot (0)',
        );
        expect(
          m.length,
          11,
          reason: 'box at cap+headroom; no over-eviction',
        );
        s.conn.dispose();
        s.sync.dispose();
      },
    );
  });

  // Plan/32 safety net — a sent message whose echo never comes back must not
  // spin forever; the optimistic bubble is removed SILENTLY after the timeout.
  group('no-echo send timeout', () {
    const short = Duration(milliseconds: 60);

    test(
      '(a) pending bubble is removed silently when no echo arrives',
      () async {
        final s = await setup(pendingSendTimeout: short);
        await s.sync.sendMessage('hello');
        await _settle();
        expect(messages(s.epk), hasLength(1), reason: 'optimistic pending row');
        expect(messages(s.epk).first.pending, isTrue);
        expect(s.sync.isWorking, isTrue);
        expect(s.sync.streaming, isNotNull, reason: 'thinking cursor seeded');

        // No echo — wait past the timeout window.
        await Future<void>.delayed(const Duration(milliseconds: 140));
        await _settle();

        expect(
          messages(s.epk),
          isEmpty,
          reason: 'bubble removed, no failed state',
        );
        expect(
          s.sync.isWorking,
          isFalse,
          reason: 'working cleared for this id',
        );
        expect(s.sync.streaming, isNull, reason: 'thinking cursor cleared');
        expect(index(s.epk)?.status, SessionActivity.idle);
        expect(s.sync.debugPendingSendTimerCount, 0);
        s.conn.dispose();
        s.sync.dispose();
      },
    );

    test(
      '(b) echo within the window confirms the row and cancels the timer',
      () async {
        final s = await setup(pendingSendTimeout: short);
        await s.sync.sendMessage('hello');
        await _settle();
        expect(s.sync.debugPendingSendTimerCount, 1, reason: 'timer armed');
        final id = s.ch.sent.whereType<UserMessage>().last.id;

        // Echo arrives promptly → confirms + disarms.
        s.ch.push(UserInput(id: id, text: 'hello'));
        await _settle();
        expect(messages(s.epk), hasLength(1));
        expect(
          messages(s.epk).first.pending,
          isFalse,
          reason: 'confirmed by echo',
        );
        expect(
          s.sync.debugPendingSendTimerCount,
          0,
          reason: 'echo cancelled timer',
        );

        // Wait PAST the timeout — the cancelled timer must NOT remove the row.
        await Future<void>.delayed(const Duration(milliseconds: 140));
        await _settle();
        expect(
          messages(s.epk),
          hasLength(1),
          reason: 'row survives the window',
        );
        expect(messages(s.epk).first.pending, isFalse);
        s.conn.dispose();
        s.sync.dispose();
      },
    );

    test(
      '(c) timers are cancelled on session switch and on dispose (no leak)',
      () async {
        // Session switch path.
        final s = await setup(pendingSendTimeout: short);
        await s.sync.sendMessage('one');
        await _settle();
        expect(s.sync.debugPendingSendTimerCount, 1);

        await s.sync.activate('epk_switch_target', 'main');
        await _settle();
        expect(
          s.sync.debugPendingSendTimerCount,
          0,
          reason: 'session switch cancels + clears pending timers',
        );

        // dispose path (fresh service so the switch above doesn't mask it).
        final s2 = await setup(pendingSendTimeout: short);
        await s2.sync.sendMessage('two');
        await _settle();
        expect(s2.sync.debugPendingSendTimerCount, 1);
        s2.sync.dispose();
        expect(
          s2.sync.debugPendingSendTimerCount,
          0,
          reason: 'dispose cancels + clears pending timers',
        );

        s.conn.dispose();
        s.sync.dispose();
        s2.conn.dispose();
      },
    );

    test('(d) an offline (held-pending) send is reaped too', () async {
      // No channel ever adopted → sendMessage takes the offline path. Decision:
      // held-pending is reaped 20s after its ts as well (nothing spins forever).
      final conn = ConnectionManager(
        factory: (_, _) async => _FakeChannel(),
        storage: _FakeStorage(),
      );
      final sync = SyncService(conn, LocalBoxes(), pendingSendTimeout: short);
      final epk = 'epk_offline_${++_counter}';
      await sync.activate(epk, 'main');
      await _settle();

      await sync.sendMessage('typed while offline');
      await _settle();
      expect(messages(epk), hasLength(1), reason: 'held pending row written');
      expect(messages(epk).first.pending, isTrue);
      expect(
        sync.debugPendingSendTimerCount,
        1,
        reason: 'reaper armed offline',
      );

      await Future<void>.delayed(const Duration(milliseconds: 140));
      await _settle();
      expect(
        messages(epk),
        isEmpty,
        reason: 'offline bubble reaped (decision)',
      );
      conn.dispose();
      sync.dispose();
    });

    test(
      '(e) returning to a session reaps a bubble already past the window',
      () async {
        // Quick exit then return: the live timer is cancelled on switch-away,
        // but _loadIndex re-arms on return using the saved ts → an already-stale
        // row fires immediately. Covers app-restart + quick-switch orphans.
        final s = await setup(pendingSendTimeout: short);
        await s.sync.sendMessage('hi');
        await _settle();
        expect(messages(s.epk), hasLength(1));

        // Leave quickly → live timer cancelled; row stays pending in the box.
        await s.sync.activate('epk_away_${++_counter}', 'main');
        await _settle();
        expect(
          s.sync.debugPendingSendTimerCount,
          0,
          reason: 'timers cleared on switch',
        );
        expect(
          messages(s.epk),
          hasLength(1),
          reason: 'orphaned row still in box',
        );

        // Time passes beyond the window while away from the session.
        await Future<void>.delayed(const Duration(milliseconds: 140));
        expect(
          messages(s.epk),
          hasLength(1),
          reason: 'no live timer reaps it while away',
        );

        // Return → load re-arms by ts → already stale → reaped on arrival.
        await s.sync.activate(s.epk, 'main');
        await _settle();
        expect(
          messages(s.epk),
          isEmpty,
          reason: 'stale pending reaped on return',
        );
        s.conn.dispose();
        s.sync.dispose();
      },
    );
  });

  group('sync reliability (2026-08-21): retry lost replies + auto gap-fill', () {
    test('unanswered session_sync is re-sent with the same id, stops on eos',
        () async {
      final s = await setup(syncRetryDelay: const Duration(milliseconds: 25));
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      // Poll for the ORIGINAL auto-sync request (debounced ~200ms after
      // adopt) — don't sleep a fixed 400ms first, or the whole retry budget
      // (3 × 25ms) is spent before we can intervene.
      var waited = 0;
      List<SessionSync> first = [];
      while ((first = s.ch.sent.whereType<SessionSync>().toList()).isEmpty &&
          waited < 200) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        waited++;
      }
      expect(first, isNotEmpty);
      final id = first.first.id;

      // Review #2 (PR #45): poll until the FIRST retry lands — strictly
      // before the 3-attempt budget is exhausted — so the later freeze can
      // only be explained by the eos reply, never by budget exhaustion.
      // 5ms polls can never skip past a 25ms tick.
      var polls = 0;
      while (s.ch.sent.whereType<SessionSync>().length < 2 && polls < 100) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        polls++;
      }
      final countAtEos = s.ch.sent.whereType<SessionSync>().length;
      expect(countAtEos, 2); // original + exactly one retry so far
      expect(
        s.ch.sent.whereType<SessionSync>().map((m) => m.id).toSet(),
        {id},
      );

      // Terminal reply received while budget remains → no further retries.
      s.ch.push(SessionHistory(
        inReplyTo: id,
        sessionStartedAt: 1,
        events: const [],
        eos: true,
      ));
      await Future<void>.delayed(
        const Duration(milliseconds: 200),
      ); // ≫ 25ms period
      expect(s.ch.sent.whereType<SessionSync>().length, countAtEos);
    });

    test('retry hitting a dying channel neither crashes nor burns an attempt',
        () async {
      final s = await setup(syncRetryDelay: const Duration(milliseconds: 25));
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 400));
      final id = s.ch.sent.whereType<SessionSync>().first.id;

      // The next retry tick sends into a channel mid-teardown: it rejects.
      // Pre-fix this surfaced as an unhandled async error (test-zone crash).
      s.ch.failNextSends = 1;
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // A later tick re-sent the SAME request on the healthy channel — the
      // failed attempt didn't count, so the budget still allows it.
      final retries =
          s.ch.sent.whereType<SessionSync>().where((m) => m.id == id).length;
      expect(retries, greaterThanOrEqualTo(1));

      s.ch.push(SessionHistory(
        inReplyTo: id,
        sessionStartedAt: 1,
        events: const [],
        eos: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    test('newest page with no local overlap auto-pages older until overlap',
        () async {
      final s = await setup();
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      // Auto sync → newest page is ALL NEW to the empty box + a cursor →
      // gap-fill must issue a loadMore with that cursor.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final req1 = s.ch.sent.whereType<SessionSync>().first;
      s.ch.push(SessionHistory(
        inReplyTo: req1.id,
        sessionStartedAt: 1,
        events: const [
          UserInputEvt(ts: 10, id: 'new1', text: 'hello'),
          AgentMessageEvt(ts: 11, inReplyTo: 'new1', text: 'world'),
        ],
        eos: true,
        nextBefore: 'cursor1',
      ));
      await _settle();
      final loadMores = s.ch
          .sent
          .whereType<SessionSync>()
          .where((m) => m.before != null)
          .toList();
      expect(loadMores, isNotEmpty);
      expect(loadMores.first.before, 'cursor1');

      // Next older page OVERLAPS local (event we already merged) → stop,
      // even though the server still offers another cursor.
      s.ch.push(SessionHistory(
        inReplyTo: loadMores.first.id,
        sessionStartedAt: 1,
        events: const [
          UserInputEvt(ts: 5, id: 'new1', text: 'hello'),
        ],
        eos: true,
        nextBefore: 'cursor2',
      ));
      await _settle();
      final count = s.ch
          .sent
          .whereType<SessionSync>()
          .where((m) => m.before != null)
          .length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        s.ch
            .sent
            .whereType<SessionSync>()
            .where((m) => m.before != null)
            .length,
        count,
      );
      // And the missed events actually landed locally.
      expect(messages(s.epk).map((m) => m.id), containsAll(['new1']));
    });

    test('page with local overlap does not auto-loadMore', () async {
      final s = await setup();
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      // Seed local with one event (no cursor → no gap-fill).
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final req1 = s.ch.sent.whereType<SessionSync>().first;
      s.ch.push(SessionHistory(
        inReplyTo: req1.id,
        sessionStartedAt: 1,
        events: const [UserInputEvt(ts: 10, id: 'seed', text: 'hi')],
        eos: true,
      ));
      await _settle();
      expect(
        s.ch.sent.whereType<SessionSync>().where((m) => m.before != null),
        isEmpty,
      );

      // Re-sync whose page OVERLAPS (contains 'seed') + a cursor → no auto
      // loadMore: nothing was missed.
      s.sync.requestSync();
      await _settle();
      final req2 = s.ch.sent.whereType<SessionSync>().last;
      s.ch.push(SessionHistory(
        inReplyTo: req2.id,
        sessionStartedAt: 1,
        events: const [
          UserInputEvt(ts: 10, id: 'seed', text: 'hi'),
          AgentMessageEvt(ts: 12, inReplyTo: 'seed', text: 'answer'),
        ],
        eos: true,
        nextBefore: 'cursorX',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        s.ch.sent.whereType<SessionSync>().where((m) => m.before != null),
        isEmpty,
      );
    });
  });

  // PR #49 review — a duplicated/replayed `select` received AFTER its flow
  // completed must not be written back as the current request. Answering
  // such a stale sheet only produces pi-ask's `flow_not_found` warning,
  // which keeps the sheet open (stuck modal on out-of-order delivery).
  // The channel deliberately exempts every extension_ui_request from its
  // replay LRU (the bridge re-sends still-pending requests with the same id
  // on every session_sync — chat re-entry catch-up), so the stale-drop lives
  // HERE, where the completing notify is observed.
  group('extension_ui_request stale replay (PR #49 review)', () {
    ExtensionUiRequest select(String id) => ExtensionUiRequest(
          id: id,
          method: ExtensionUiMethod.select,
          title: 'Pick one',
          options: const ['Alpha', 'Beta'],
          ask: AskEnrichmentWire(flowId: id, source: 'tool'),
        );

    ExtensionUiRequest resolved(String id) => ExtensionUiRequest(
          id: id,
          method: ExtensionUiMethod.notify,
          message: 'Clarification resolved.',
        );

    test('replayed select for a resolved flow does not resurrect the sheet',
        () async {
      final s = await setup();
      final events = <String>[];
      final sub = s.sync.extensionUiRequestStream.listen(
        (r) => events.add(r.id),
      );

      s.ch.push(select('flow-1'));
      await _settle();
      expect(s.sync.currentExtensionUiRequest?.id, 'flow-1');

      // Completed notify (same id, info type) resolves the flow.
      s.ch.push(resolved('flow-1'));
      await _settle();
      expect(s.sync.currentExtensionUiRequest, isNull);

      // Out-of-order duplicate of the original select — must NOT resurrect
      // the current request NOR ping the live stream.
      s.ch.push(select('flow-1'));
      await _settle();
      expect(s.sync.currentExtensionUiRequest, isNull,
          reason: 'stale replay must not re-open the sheet');
      expect(events, ['flow-1', 'flow-1'],
          reason: 'stale replay must not emit on the live stream');

      await sub.cancel();
    });

    test('session_sync replay of a still-pending flow re-surfaces the sheet',
        () async {
      final s = await setup();
      final req = select('flow-2');
      s.ch.push(req);
      await _settle();
      expect(s.sync.currentExtensionUiRequest?.id, 'flow-2');

      // Session switch drops the current request (plan/129) — the pending
      // ask belongs to the chat we just left.
      await s.sync.activate(s.epk, 'other');
      expect(s.sync.currentExtensionUiRequest, isNull);

      // Re-entering re-fires session_sync; the bridge re-sends the SAME
      // request (same id, flow still awaiting an answer). It must deliver.
      s.ch.push(req);
      await _settle();
      expect(s.sync.currentExtensionUiRequest?.id, 'flow-2',
          reason: 'pending replay (chat re-entry catch-up) must deliver');
    });

    // PR #50 review 2 — superseding is NOT resolving: the bridge supports
    // several active flows and session_sync replays every open one
    // (pendingRequests returns ALL active flows, oldest-first). A
    // still-pending replaced flow must stay presentable and answerable once
    // the newer one closes; only a TERMINAL notify retires an id.
    test('still-pending superseded flow resurfaces after the newer one closes',
        () async {
      final s = await setup();
      s.ch.push(select('flow-a'));
      await _settle();
      s.ch.push(select('flow-b'));
      await _settle();
      expect(s.sync.currentExtensionUiRequest?.id, 'flow-b');

      // Newer flow resolves — its terminal notify clears the sheet.
      s.ch.push(resolved('flow-b'));
      await _settle();
      expect(s.sync.currentExtensionUiRequest, isNull);

      // session_sync replays the STILL-PENDING older flow — must deliver.
      // (Marking flow-a resolved at replacement made it unanswerable forever
      // — the reviewer's exact scenario.)
      s.ch.push(select('flow-a'));
      await _settle();
      expect(s.sync.currentExtensionUiRequest?.id, 'flow-a');
    });

    // PR #50 review 2 (multi-flow terminal) — an unmatched terminal notify
    // retires only ITS flow; the current sheet is untouched.
    test('terminal notify for a non-current flow leaves the current sheet',
        () async {
      final s = await setup();
      s.ch.push(select('flow-a'));
      await _settle();
      s.ch.push(select('flow-b'));
      await _settle();

      s.ch.push(resolved('flow-a')); // terminal for the non-current flow
      await _settle();
      expect(s.sync.currentExtensionUiRequest?.id, 'flow-b');

      // And flow-a's replay is now properly retired (it saw a terminal).
      s.ch.push(select('flow-a'));
      await _settle();
      expect(s.sync.currentExtensionUiRequest?.id, 'flow-b');
    });

    // PR #50 review 1 — a terminal notify must be remembered even when it
    // matches NO open sheet: reordering can deliver it after a room switch
    // cleared the current request. If the id went unrecorded there, the
    // later replayed select would reopen the same stuck sheet.
    test('terminal notify after a room switch still retires the flow',
        () async {
      final s = await setup();
      s.ch.push(select('flow-1'));
      await _settle();
      expect(s.sync.currentExtensionUiRequest?.id, 'flow-1');

      await s.sync.activate(s.epk, 'other'); // room switch clears current
      expect(s.sync.currentExtensionUiRequest, isNull);

      s.ch.push(resolved('flow-1')); // unmatched terminal — still recorded
      await _settle();

      s.ch.push(select('flow-1')); // stale replay
      await _settle();
      expect(s.sync.currentExtensionUiRequest, isNull,
          reason: 'resolved flow must stay retired across a room switch');
    });

    // PR #50 review 1 (reordering variant) — the completion can also arrive
    // BEFORE its request. A select whose flow already saw a terminal notify
    // is always stale (the bridge never re-sends completed flows).
    test('terminal notify arriving before its request drops the later replay',
        () async {
      final s = await setup();
      s.ch.push(resolved('flow-x')); // reordering: completion first
      await _settle();
      s.ch.push(select('flow-x')); // the out-of-order duplicate
      await _settle();
      expect(s.sync.currentExtensionUiRequest, isNull,
          reason: 'a select whose flow already resolved is always stale');
    });

    test('warning notify keeps the flow open and replayable (retry semantics)',
        () async {
      final s = await setup();
      s.ch.push(select('flow-3'));
      await _settle();

      s.ch.push(const ExtensionUiRequest(
        id: 'flow-3',
        method: ExtensionUiMethod.notify,
        message: 'Unknown option value.',
        notifyType: 'warning',
      ));
      await _settle();
      expect(s.sync.currentExtensionUiRequest?.id, 'flow-3',
          reason: 'warning keeps the flow open for retry');

      // A same-id re-delivery while merely rejected (NOT resolved) still
      // delivers — this is the retry path the 2026-08-22 fix protected.
      s.ch.push(select('flow-3'));
      await _settle();
      expect(s.sync.currentExtensionUiRequest?.id, 'flow-3');
    });
  });
}
