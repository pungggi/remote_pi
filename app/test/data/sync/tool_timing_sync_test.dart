// Plan/172 — the app's derivation of row times and tool execution windows.
//
// Pins every row of the table in plan/172-message-timestamps.md:
//
//   value           live, new ext        live, old ext        replayed
//   user ts         echo ts wins         phone send time     UserMessage ts
//   assistant ts    first chunk ts       first chunk arrival AgentMessage ts
//   replyAt         reply_ts             null                 request event ts
//   startedAt       request ts           request arrival     ts − duration_ms
//   endedAt         result ts            result arrival       result event ts
//   durationMs      duration_ms          endedAt − startedAt duration_ms
//
// plus the one rule that keeps clocks apart: a live/replay merge takes the
// timing set of the richer side as a WHOLE, never a start from one clock with
// an end from the other.

import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
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

  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Stream<ControlInbound> get controlFrames => _control.stream;
  @override
  Future<void> send(ClientMessage msg) async => sent.add(msg);
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> close() async {
    await _ctrl.close();
    await _control.close();
  }

  void push(ServerMessage m) => _ctrl.add(m);
}

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

/// A Pi-clock instant far from the phone's own clock, so a test that mixes
/// the two up cannot pass by coincidence.
const int _pi = 1716234600000; // 2024-05-20T21:50:00Z

DateTime _piAt(int ms) => DateTime.fromMillisecondsSinceEpoch(_pi + ms);

void main() {
  late Directory dir;
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('rp_ts_');
    await LocalBoxes.initForTest(dir.path);
  });
  tearDownAll(() async {
    await Hive.close();
    dir.delete(recursive: true);
  });

  Future<({_FakeChannel ch, SyncService sync, String epk})> setup(
    String epk,
  ) async {
    final ch = _FakeChannel();
    final conn = ConnectionManager(
      factory: (_, _) async => ch,
      storage: _FakeStorage(),
      emitDebounce: Duration.zero,
    );
    final sync = SyncService(conn, LocalBoxes());
    conn.adopt(
      ch,
      PeerRecord(
        remoteEpk: epk,
        sessionName: 'Pi',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-01T00:00:00Z',
      ),
    );
    await _settle();
    return (ch: ch, sync: sync, epk: epk);
  }

  List<MessageRecord> msgs(String epk) {
    final box = LocalBoxes().openMsgsBox(epk, 'main');
    final out = [
      for (final v in box.values)
        MessageRecord.fromJson((v as Map).cast<String, dynamic>()),
    ];
    out.sort((a, b) => a.seq.compareTo(b.seq));
    return out;
  }

  MessageRecord toolRow(String epk, String id) =>
      msgs(epk).singleWhere((r) => r.role == MsgRole.tool && r.id == id);

  MessageRecord userRow(String epk, String id) =>
      msgs(epk).singleWhere((r) => r.role == MsgRole.user && r.id == id);

  group('live, current extension (Pi stamps its frames)', () {
    test('tool: start, end, duration and reply all on the Pi clock', () async {
      final s = await setup('epk_live_new');
      s.ch.push(
        ToolRequest(
          toolCallId: 'c1',
          tool: 'bash',
          args: null,
          ts: _pi + 7000,
          replyTs: _pi,
        ),
      );
      await _settle();
      s.ch.push(
        ToolResult(
          toolCallId: 'c1',
          result: 'ok',
          ts: _pi + 13821,
          durationMs: 6821,
        ),
      );
      await _settle();

      final t = toolRow(s.epk, 'c1').tool!;
      expect(t.replyAtMs, _pi);
      expect(t.startedAtMs, _pi + 7000);
      expect(t.endedAtMs, _pi + 13821);
      expect(t.durationMs, 6821);
      // The row time is the execution start (what a tool row always meant
      // for a live request).
      expect(toolRow(s.epk, 'c1').ts, _piAt(7000));
      s.sync.dispose();
    });

    test('tool still running: start + reply are known, no end yet', () async {
      final s = await setup('epk_live_running');
      s.ch.push(
        ToolRequest(
          toolCallId: 'c1',
          tool: 'bash',
          args: null,
          ts: _pi + 7000,
          replyTs: _pi,
        ),
      );
      await _settle();
      final t = toolRow(s.epk, 'c1').tool!;
      expect(t.status, ToolEventStatus.pending);
      expect(t.startedAtMs, _pi + 7000);
      expect(t.endedAtMs, isNull);
      expect(t.durationMs, isNull);
      s.sync.dispose();
    });

    test(
      'user echo replaces the optimistic phone time with the Pi time',
      () async {
        final s = await setup('epk_echo_new');
        await s.sync.sendMessage('list the files');
        final id = (s.ch.sent.single as UserMessage).id;
        await _settle();
        // Optimistic row: pending, on the phone's clock.
        expect(userRow(s.epk, id).pending, isTrue);
        expect(userRow(s.epk, id).ts.millisecondsSinceEpoch, isNot(_pi));

        s.ch.push(UserInput(id: id, text: 'list the files', ts: _pi));
        await _settle();
        final row = userRow(s.epk, id);
        expect(row.pending, isFalse);
        expect(row.ts, _piAt(0));
        s.sync.dispose();
      },
    );

    test('assistant row is stamped with the reply start (chunk ts), not the '
        'finalization time', () async {
      final s = await setup('epk_chunk_new');
      s.ch.push(UserInput(id: 'u1', text: 'q', ts: _pi));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'hel', ts: _pi + 900));
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'lo', ts: _pi + 900));
      await _settle();
      s.ch.push(AgentDone(inReplyTo: 'u1', text: 'hello'));
      await _settle();
      final reply = msgs(s.epk).singleWhere((r) => r.role == MsgRole.assistant);
      expect(reply.text, 'hello');
      expect(reply.ts, _piAt(900));
      s.sync.dispose();
    });
  });

  group('live, pre-172 extension (no stamps: phone arrival)', () {
    test(
      'tool: arrival-based window, self-consistent, no reply time',
      () async {
        final s = await setup('epk_live_old');
        final before = DateTime.now();
        s.ch.push(ToolRequest(toolCallId: 'c2', tool: 'bash', args: null));
        await _settle();
        s.ch.push(ToolResult(toolCallId: 'c2', result: 'ok'));
        await _settle();

        final row = toolRow(s.epk, 'c2');
        final t = row.tool!;
        expect(t.replyAtMs, isNull);
        expect(t.startedAtMs, row.ts.millisecondsSinceEpoch);
        expect(t.endedAtMs, isNotNull);
        expect(
          t.durationMs,
          t.endedAtMs! - t.startedAtMs!,
          reason: 'old extensions leave the app to measure end − start',
        );
        expect(t.durationMs, greaterThanOrEqualTo(0));
        expect(
          t.endedAtMs,
          greaterThanOrEqualTo(before.millisecondsSinceEpoch),
        );
        s.sync.dispose();
      },
    );

    test('user echo without ts keeps the optimistic phone time', () async {
      final s = await setup('epk_echo_old');
      await s.sync.sendMessage('hello');
      final id = (s.ch.sent.single as UserMessage).id;
      await _settle();
      final phoneTs = userRow(s.epk, id).ts;
      s.ch.push(UserInput(id: id, text: 'hello'));
      await _settle();
      final row = userRow(s.epk, id);
      expect(row.pending, isFalse);
      expect(row.ts, phoneTs);
      s.sync.dispose();
    });

    test(
      'assistant row without chunk ts uses the first chunk arrival',
      () async {
        final s = await setup('epk_chunk_old');
        final before = DateTime.now();
        s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'hi'));
        await _settle();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        s.ch.push(AgentDone(inReplyTo: 'u1', text: 'hi'));
        await _settle();
        final reply = msgs(
          s.epk,
        ).singleWhere((r) => r.role == MsgRole.assistant);
        // Finalization came >= 30ms after the first chunk: the row time must
        // be the EARLIER one (first chunk), never the agent_done arrival.
        expect(
          reply.ts.millisecondsSinceEpoch,
          greaterThanOrEqualTo(before.millisecondsSinceEpoch),
        );
        expect(
          DateTime.now().difference(reply.ts).inMilliseconds,
          greaterThanOrEqualTo(25),
        );
        s.sync.dispose();
      },
    );
  });

  group('replayed history', () {
    test('with duration_ms: start = ts − duration, exact', () async {
      final s = await setup('epk_hist_new');
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 0,
          events: [
            ToolRequestEvt(
              ts: _pi,
              toolCallId: 'h1',
              tool: 'bash',
              args: const {'command': 'ls'},
            ),
            ToolResultEvt(
              ts: _pi + 10000,
              toolCallId: 'h1',
              result: 'ok',
              durationMs: 2500,
            ),
          ],
          eos: true,
        ),
      );
      await _settle();

      final row = toolRow(s.epk, 'h1');
      final t = row.tool!;
      expect(row.ts, _piAt(0), reason: 'row time keeps its historical meaning');
      expect(t.replyAtMs, _pi);
      expect(t.startedAtMs, _pi + 7500);
      expect(t.endedAtMs, _pi + 10000);
      expect(t.durationMs, 2500);
      expect(t.status, ToolEventStatus.completed);
      s.sync.dispose();
    });

    test(
      'legacy session (no duration): start UNKNOWN, never the reply time',
      () async {
        final s = await setup('epk_hist_old');
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 0,
            events: [
              ToolRequestEvt(
                ts: _pi,
                toolCallId: 'h1',
                tool: 'bash',
                args: null,
              ),
              ToolResultEvt(ts: _pi + 10000, toolCallId: 'h1', result: 'ok'),
            ],
            eos: true,
          ),
        );
        await _settle();
        final t = toolRow(s.epk, 'h1').tool!;
        expect(t.replyAtMs, _pi);
        expect(t.startedAtMs, isNull);
        expect(t.endedAtMs, _pi + 10000);
        expect(t.durationMs, isNull);
        s.sync.dispose();
      },
    );

    test('result-only page: end + duration, name unknown', () async {
      final s = await setup('epk_hist_result_only');
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 0,
          events: [
            ToolResultEvt(
              ts: _pi + 10000,
              toolCallId: 'h9',
              result: 'ok',
              durationMs: 4000,
            ),
          ],
          eos: true,
        ),
      );
      await _settle();
      final t = toolRow(s.epk, 'h9').tool!;
      expect(t.tool, 'unknown');
      expect(t.startedAtMs, _pi + 6000);
      expect(t.endedAtMs, _pi + 10000);
      expect(t.durationMs, 4000);
      s.sync.dispose();
    });
  });

  group('live ↔ replay merge never mixes clocks', () {
    test(
      'phone-clock live start + Pi-clock replay window → the replay set',
      () async {
        final s = await setup('epk_mix_1');
        // Pre-172 extension: live request stamped on arrival (phone clock).
        s.ch.push(ToolRequest(toolCallId: 'm1', tool: 'bash', args: null));
        await _settle();
        final phoneStart = toolRow(s.epk, 'm1').tool!.startedAtMs;
        expect(phoneStart, isNot(_pi + 1000));

        // A replay (Pi clock) completes the call with a full window.
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 0,
            events: [
              ToolRequestEvt(
                ts: _pi,
                toolCallId: 'm1',
                tool: 'bash',
                args: null,
              ),
              ToolResultEvt(
                ts: _pi + 5000,
                toolCallId: 'm1',
                result: 'ok',
                durationMs: 4000,
              ),
            ],
            eos: true,
          ),
        );
        await _settle();

        final t = toolRow(s.epk, 'm1').tool!;
        expect(t.replyAtMs, _pi);
        expect(
          t.startedAtMs,
          _pi + 1000,
          reason: 'the replay window wins as a whole',
        );
        expect(t.endedAtMs, _pi + 5000);
        expect(t.durationMs, 4000);
        expect(t.status, ToolEventStatus.completed);
        s.sync.dispose();
      },
    );

    test(
      'a complete live window is kept over an equally rich replay',
      () async {
        final s = await setup('epk_mix_2');
        // Current extension, live: a complete Pi-clock window.
        s.ch.push(
          ToolRequest(
            toolCallId: 'm2',
            tool: 'bash',
            args: null,
            ts: _pi + 7000,
            replyTs: _pi,
          ),
        );
        await _settle();
        s.ch.push(
          ToolResult(
            toolCallId: 'm2',
            result: 'live',
            ts: _pi + 13821,
            durationMs: 6821,
          ),
        );
        await _settle();
        // The same call replayed: the Pi records its own end time, which can
        // differ from the broadcast instant by a few ms.
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 0,
            events: [
              ToolRequestEvt(
                ts: _pi,
                toolCallId: 'm2',
                tool: 'bash',
                args: null,
              ),
              ToolResultEvt(
                ts: _pi + 13825,
                toolCallId: 'm2',
                result: 'live',
                durationMs: 6821,
              ),
            ],
            eos: true,
          ),
        );
        await _settle();
        final t = toolRow(s.epk, 'm2').tool!;
        expect(t.startedAtMs, _pi + 7000);
        expect(t.endedAtMs, _pi + 13821, reason: 'tie → never downgrade');
        s.sync.dispose();
      },
    );
  });
}
