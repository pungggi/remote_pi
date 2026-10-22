// Plan/145 — delivery ledger (app side): ordered apply of stamped frames,
// gap hold + report, journal-replay drain, dup drop, epoch re-baseline,
// history currentSeq baseline, tail report timer, sync_needed, hold escape.
//
// Harness mirrors sync_service_test.dart: a fake channel adopted into a real
// ConnectionManager, real Hive boxes in a temp dir.

import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/codec.dart';
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
  Future<void> send(ClientMessage msg) async {
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
}

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

int _counter = 0;
late Directory _dir;

const _epoch = 1111;

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

/// A stamped broadcast frame (what the plan/145 pi-extension emits).
AgentChunk stampedChunk(int seq, String delta, {int epoch = _epoch}) =>
    AgentChunk(inReplyTo: 't1', delta: delta)
      ..ledgerSeq = seq
      ..ledgerEpoch = epoch;

void main() {
  setUpAll(() async {
    _dir = Directory.systemTemp.createTempSync('rp_ledger_');
    await LocalBoxes.initForTest(_dir.path);
  });
  tearDownAll(() async {
    await Hive.close();
    await _dir.delete(recursive: true);
  });

  Future<({ConnectionManager conn, _FakeChannel ch, SyncService sync, String epk})>
  setup({
    String? epkOverride,
    Duration holdEscape = const Duration(seconds: 5),
    Duration tailEvery = const Duration(seconds: 15),
  }) async {
    final ch = _FakeChannel();
    final conn = ConnectionManager(
      factory: (_, _) async => ch,
      storage: _FakeStorage(),
      emitDebounce: Duration.zero,
    );
    final sync = SyncService(
      conn,
      LocalBoxes(),
      ledgerHoldEscapeAfter: holdEscape,
      ledgerTailReportEvery: tailEvery,
    );
    final epk = epkOverride ?? 'epk_ledger_${++_counter}';
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
    return (conn: conn, ch: ch, sync: sync, epk: epk);
  }

  group('protocol', () {
    test('decodeServer attaches the stamp; absent keys stay null', () {
      final stamped = decodeServer(
        '{"type":"agent_chunk","in_reply_to":"t","delta":"x",'
        '"seq":5,"epoch":42}',
      );
      expect(stamped.ledgerSeq, 5);
      expect(stamped.ledgerEpoch, 42);

      final plain = decodeServer(
        '{"type":"agent_chunk","in_reply_to":"t","delta":"x"}',
      );
      expect(plain.ledgerSeq, isNull);
      expect(plain.ledgerEpoch, isNull);
    });

    test('decodeServer maps sync_needed; ReportSeq encodes the wire shape', () {
      final m = decodeServer('{"type":"sync_needed","reason":"epoch"}');
      expect(m, isA<SyncNeeded>());
      expect((m as SyncNeeded).reason, 'epoch');

      final r = ReportSeq(id: 'r1', seq: 7, epoch: 42);
      expect(r.toJson(), {
        'type': 'report_seq',
        'id': 'r1',
        'seq': 7,
        'epoch': 42,
      });
    });

    test('SessionHistory parses current_seq (absent on pre-145 Pis)', () {
      final h = decodeServer(
        '{"type":"session_history","in_reply_to":"s1",'
        '"session_started_at":1111,"events":[],"eos":true,'
        '"current_seq":23}',
      );
      expect(h, isA<SessionHistory>());
      expect((h as SessionHistory).currentSeq, 23);

      final legacy = decodeServer(
        '{"type":"session_history","in_reply_to":"s1",'
        '"session_started_at":1111,"events":[],"eos":true}',
      );
      expect((legacy as SessionHistory).currentSeq, isNull);
    });
  });

  group('ordered apply', () {
    test('in-order stamped chunks apply and advance the cursor', () async {
      final s = await setup();
      s.ch.push(stampedChunk(1, 'a'));
      s.ch.push(stampedChunk(2, 'b'));
      await _settle();
      expect(s.sync.streaming?.buffer, 'ab');
      expect(s.sync.ledgerContig, 2);
      expect(s.sync.ledgerEpoch, _epoch);
      expect(s.sync.ledgerStats['stamped'], 2);
      s.sync.dispose();
      s.conn.dispose();
    });

    test('unstamped frames bypass the gate (pre-145 Pi)', () async {
      final s = await setup();
      s.ch.push(AgentChunk(inReplyTo: 't1', delta: 'a'));
      s.ch.push(AgentChunk(inReplyTo: 't1', delta: 'b'));
      await _settle();
      expect(s.sync.streaming?.buffer, 'ab');
      expect(s.sync.ledgerEpoch, isNull, reason: 'no stamped frame seen');
      expect(s.sync.ledgerStats['stamped'], 0);
      s.sync.dispose();
      s.conn.dispose();
    });

    test('gap holds the ahead frame, reports, and the replay completes in '
        'order', () async {
      final s = await setup();
      s.ch.push(stampedChunk(1, 'a'));
      s.ch.push(stampedChunk(3, 'c')); // 2 lost in transit
      await _settle();
      expect(s.sync.streaming?.buffer, 'a', reason: 'seq 3 held behind gap');
      expect(s.sync.ledgerHeldCount, 1);
      expect(s.sync.ledgerStats['gapsDetected'], 1);
      final reports = s.ch.sent.whereType<ReportSeq>().toList();
      expect(reports, hasLength(1));
      expect(reports.single.seq, 1, reason: 'reports the contiguous cursor');
      expect(reports.single.epoch, _epoch);

      // The Pi's journal replay re-delivers 2 (and 3, which the dup rule
      // drops — the held copy applies first).
      s.ch.push(stampedChunk(2, 'b'));
      await _settle();
      expect(s.sync.streaming?.buffer, 'abc');
      expect(s.sync.ledgerContig, 3);
      expect(s.sync.ledgerHeldCount, 0);
      expect(s.sync.ledgerStats['heldApplied'], 1);

      s.ch.push(stampedChunk(3, 'c')); // replay's copy of 3 → dup
      await _settle();
      expect(s.sync.streaming?.buffer, 'abc', reason: 'no double-apply');
      expect(s.sync.ledgerStats['dupsDropped'], 1);
      s.sync.dispose();
      s.conn.dispose();
    });

    test('duplicate stamped frames never double-apply chunk text', () async {
      final s = await setup();
      s.ch.push(stampedChunk(1, 'a'));
      s.ch.push(stampedChunk(1, 'a'));
      s.ch.push(stampedChunk(1, 'a'));
      await _settle();
      expect(s.sync.streaming?.buffer, 'a');
      expect(s.sync.ledgerStats['dupsDropped'], 2);
      s.sync.dispose();
      s.conn.dispose();
    });

    test('epoch change re-baselines on the frame itself', () async {
      final s = await setup();
      s.ch.push(stampedChunk(2, 'x')); // adopt: contig 1, applies
      s.ch.push(stampedChunk(1, 'y', epoch: 2222)); // restart → re-baseline
      await _settle();
      expect(s.sync.streaming?.buffer, 'xy');
      expect(s.sync.ledgerEpoch, 2222);
      expect(s.sync.ledgerContig, 1);
      s.sync.dispose();
      s.conn.dispose();
    });
  });

  group('history baseline', () {
    test('current_seq re-baselines the cursor and drains contiguous held',
        () async {
      final s = await setup();
      s.ch.push(stampedChunk(1, 'a'));
      s.ch.push(stampedChunk(3, 'c')); // held behind the gap
      await _settle();
      expect(s.sync.ledgerHeldCount, 1);

      // The sync snapshot covers everything through seq 2 → cursor jumps,
      // and the held seq-3 frame becomes contiguous.
      s.ch.push(
        SessionHistory(
          inReplyTo: 's1',
          sessionStartedAt: _epoch,
          events: const [],
          eos: true,
          currentSeq: 2,
        ),
      );
      await _settle();
      expect(s.sync.ledgerContig, 3);
      expect(s.sync.ledgerHeldCount, 0);
      expect(s.sync.streaming?.buffer, 'ac');
      s.sync.dispose();
      s.conn.dispose();
    });

    test('history from a moved epoch re-baselines wholesale', () async {
      final s = await setup();
      s.ch.push(stampedChunk(5, 'x'));
      await _settle();
      s.ch.push(
        SessionHistory(
          inReplyTo: 's1',
          sessionStartedAt: 9999, // Pi restarted
          events: const [],
          eos: true,
          currentSeq: 7,
        ),
      );
      await _settle();
      expect(s.sync.ledgerEpoch, 9999);
      expect(s.sync.ledgerContig, 7);
      // The next stamped frame of the new epoch applies cleanly.
      s.ch.push(stampedChunk(8, 'y', epoch: 9999));
      await _settle();
      expect(s.sync.streaming?.buffer, 'xy');
      s.sync.dispose();
      s.conn.dispose();
    });
  });

  group('cold-start resume (persistence)', () {
    test('process death mid-stream: same-epoch resume detects the hole and '
        'the journal replay heals in order', () async {
      final s = await setup();
      // Turn 1 applies 1..3 and ENDS (agent_done = the safe point).
      s.ch.push(stampedChunk(1, 'a'));
      s.ch.push(stampedChunk(2, 'b'));
      s.ch.push(stampedChunk(3, 'c'));
      s.ch.push(AgentDone(inReplyTo: 't1')..ledgerSeq = 4..ledgerEpoch = _epoch);
      await _settle();
      expect(s.sync.ledgerContig, 4);

      // ── process death: everything in-memory is gone ──
      final s2 = await setup(epkOverride: s.epk);
      // Fresh SyncService, same boxes/room, same epoch (Pi stayed alive).
      // Frame 6 arrives live — frames 5 (and the tail of 4) were lost while
      // the app was dead/reconnecting.
      s2.ch.push(stampedChunk(6, 'f'));
      await _settle();
      // NOT adopted as contig=5: the persisted cursor (4) keeps 5 a GAP.
      expect(s2.sync.ledgerContig, 4, reason: 'persisted cursor resumed');
      expect(s2.sync.ledgerHeldCount, 1, reason: 'seq 6 held behind the hole');
      final reports = s2.ch.sent.whereType<ReportSeq>().toList();
      expect(reports, isNotEmpty);
      expect(reports.last.seq, 4);

      // The Pi's journal replay fills 5 → held 6 applies in order.
      s2.ch.push(stampedChunk(5, 'e'));
      await _settle();
      expect(s2.sync.streaming?.buffer, 'ef');
      expect(s2.sync.ledgerContig, 6);
      s2.sync.dispose();
      s2.conn.dispose();
      s.sync.dispose();
      s.conn.dispose();
    });

    test('epoch moved on the Pi: adopt, do not resume the stale cursor',
        () async {
      final s = await setup();
      s.ch.push(stampedChunk(2, 'x'));
      s.ch.push(AgentDone(inReplyTo: 't1')..ledgerSeq = 3..ledgerEpoch = _epoch);
      await _settle();

      final s2 = await setup(epkOverride: s.epk);
      // Pi restarted while the app was dead → new epoch, seq restarts at 1.
      s2.ch.push(stampedChunk(1, 'y', epoch: 9999));
      await _settle();
      expect(s2.sync.ledgerContig, 1, reason: 'new epoch adopts, no resume');
      expect(s2.sync.ledgerEpoch, 9999);
      s2.sync.dispose();
      s2.conn.dispose();
      s.sync.dispose();
      s.conn.dispose();
    });
  });

  group('healers', () {
    test('sync_needed requests a full session_sync', () async {
      final s = await setup();
      // Let the online-edge sync fire, then watch for a NEW one.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final before = s.ch.sent.whereType<SessionSync>().length;
      s.ch.push(SyncNeeded(reason: 'overflow'));
      await _settle();
      expect(
        s.ch.sent.whereType<SessionSync>().length,
        greaterThan(before),
      );
      expect(s.sync.ledgerStats['syncNeeded'], 1);
      s.sync.dispose();
      s.conn.dispose();
    });

    test('tail report fires only while foregrounded + baselined', () async {
      final s = await setup(tailEvery: const Duration(milliseconds: 50));
      // No baseline yet → the timer (even when foregrounded) stays quiet.
      s.sync.setChatForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(s.ch.sent.whereType<ReportSeq>(), isEmpty);

      s.ch.push(stampedChunk(1, 'a'));
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 130));
      final reports = s.ch.sent.whereType<ReportSeq>().toList();
      expect(
        reports.length,
        greaterThanOrEqualTo(2),
        reason: 'periodic tail reports while the chat is open',
      );
      expect(reports.last.seq, 1);

      // Foreground off → no further reports.
      s.sync.setChatForeground(false);
      final count = s.ch.sent.whereType<ReportSeq>().length;
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(s.ch.sent.whereType<ReportSeq>().length, count);
      s.sync.dispose();
      s.conn.dispose();
    });

    test('hold escape applies held frames and requests a full sync', () async {
      final s = await setup(holdEscape: const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final syncsBefore = s.ch.sent.whereType<SessionSync>().length;

      s.ch.push(stampedChunk(1, 'a'));
      s.ch.push(stampedChunk(3, 'c')); // replay never comes
      await _settle();
      expect(s.sync.streaming?.buffer, 'a');

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(s.sync.streaming?.buffer, 'ac', reason: 'escape applied the held frame');
      expect(s.sync.ledgerStats['holdEscapes'], 1);
      expect(s.sync.ledgerContig, 3);
      expect(
        s.ch.sent.whereType<SessionSync>().length,
        greaterThan(syncsBefore),
        reason: 'escape heals the hole via a full sync',
      );
      s.sync.dispose();
      s.conn.dispose();
    });
  });
}
