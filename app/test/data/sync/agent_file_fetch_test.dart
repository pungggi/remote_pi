// Plan/158 — the agent_file chunked fetch loop in SyncService (window = 1):
// metadata refs persisted from live + history frames, payload assembly,
// typed error mapping (gone / changed / busy), watchdog resend, and the
// MessageRecord round-trip (bytes stay OUT of the persisted row).

import 'dart:async';
import 'dart:convert';
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
    _dir = Directory.systemTemp.createTempSync('rp_v2_afetch_');
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
    Duration chunkTimeout = const Duration(milliseconds: 60),
    Duration busyDelay = const Duration(milliseconds: 40),
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
      agentFileChunkTimeout: chunkTimeout,
      agentFileBusyDelay: busyDelay,
    );
    final epk = 'epk_afetch_${++_counter}';
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

  List<MessageRecord> messages(String epk) {
    final box = LocalBoxes().openMsgsBox(epk, 'main');
    final out = [
      for (final v in box.values)
        MessageRecord.fromJson((v as Map).cast<String, dynamic>()),
    ];
    out.sort((a, b) => a.seq.compareTo(b.seq));
    return out;
  }

  group('live agent_file_ref', () {
    test('persists a metadata-only assistant row (no bytes anywhere)', () async {
      final s = await setup();
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      s.ch.push(AgentFileRef(
        id: 'f1',
        inReplyTo: '',
        fileId: 'f1',
        ts: 1700000000000,
        kind: 'pdf',
        mime: 'application/pdf',
        name: 'report.pdf',
        bytes: 12582912, // 12 MiB — beyond the old 10 MiB inline cap
        caption: 'Q3 report',
      ));
      await _settle();

      final rows = messages(s.epk);
      expect(rows, hasLength(1));
      final r = rows.single;
      expect(r.role, MsgRole.assistant);
      expect(r.id, 'f1');
      expect(r.file, isNotNull);
      expect(r.file!.data, isNull, reason: 'metadata-only: no base64 row');
      expect(r.file!.fileId, 'f1');
      expect(r.file!.name, 'report.pdf');
      expect(r.file!.bytes, 12582912);
      expect(r.file!.kind, 'pdf');
      expect(r.text, 'Q3 report');
      expect(
        r.ts,
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

      final msg = r.toChatMessage() as AgentFileMsg;
      expect(msg.fileId, 'f1');
      expect(msg.data, isNull);
      expect(msg.name, 'report.pdf');
      expect(msg.bytes, 12582912);
    });

    test('re-delivered ref dedupes (one row only)', () async {
      final s = await setup();
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      for (var i = 0; i < 2; i++) {
        s.ch.push(AgentFileRef(
          id: 'f_dup',
          inReplyTo: '',
          fileId: 'f_dup',
          kind: 'text',
          name: 'notes.txt',
        ));
        await _settle();
      }
      expect(messages(s.epk), hasLength(1));
    });
  });

  group('history agent_file_ref', () {
    test('event maps to the same metadata-only row shape', () async {
      final s = await setup();
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      s.ch.push(SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: const [
          AgentFileRefEvt(
            ts: 1700000001000,
            fileId: 'f_hist',
            kind: 'markdown',
            mime: 'text/markdown',
            name: 'plan.md',
            bytes: 2048,
            caption: 'the plan',
            allowNetwork: false,
          ),
        ],
        eos: true,
      ));
      await _settle();

      final rows = messages(s.epk);
      expect(rows, hasLength(1));
      final r = rows.single;
      expect(r.id, 'f_hist');
      expect(r.file!.data, isNull);
      expect(r.file!.name, 'plan.md');
      expect(r.file!.bytes, 2048);
      final msg = r.toChatMessage() as AgentFileMsg;
      expect(msg.caption, 'the plan');
    });

    test('live ref and replayed history ref dedupe to ONE row', () async {
      final s = await setup();
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      s.ch.push(AgentFileRef(
        id: 'f_both',
        inReplyTo: '',
        fileId: 'f_both',
        ts: 1700000002000,
        kind: 'text',
        name: 'same.txt',
      ));
      await _settle();
      s.ch.push(SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: const [
          AgentFileRefEvt(ts: 1700000002000, fileId: 'f_both', kind: 'text'),
        ],
        eos: true,
      ));
      await _settle();
      expect(messages(s.epk), hasLength(1));
    });
  });

  group('fetchAgentFile loop', () {
    test('happy path: two chunks assemble in order, window = 1', () async {
      final s = await setup();
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      const chunk1 = 'SGVsbG8=';
      const chunk2 = 'IHBpIQ==';

      final progress = <int>[];
      final future = s.sync.fetchAgentFile(
        'f_ok',
        onProgress: (received, total) => progress.add(received),
      );
      await _settle();

      final fetches = s.ch.sent.whereType<AgentFileFetch>().toList();
      expect(fetches, hasLength(1));
      expect(fetches.single.fileId, 'f_ok');
      expect(fetches.single.offset, 0);

      s.ch.push(AgentFilePayload(
        inReplyTo: fetches.single.id,
        fileId: 'f_ok',
        offset: 0,
        total: 9,
        data: chunk1,
        more: true,
      ));
      await _settle();

      // Window = 1: the next request only goes out after the first chunk.
      final second =
          s.ch.sent.whereType<AgentFileFetch>().toList().last;
      expect(second.offset, 5, reason: 'offset advances by "Hello".length');

      s.ch.push(AgentFilePayload(
        inReplyTo: second.id,
        fileId: 'f_ok',
        offset: 5,
        total: 9,
        data: chunk2,
        more: false,
      ));

      final bytes = await future;
      expect(utf8.decode(bytes), 'Hello pi!');
      expect(progress, [5, 9]);
    });

    test('gone / not_found → AgentFileGoneException', () async {
      final s = await setup();
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      final future = s.sync.fetchAgentFile('f_gone');
      await _settle();
      s.ch.push(AgentFileError(
        inReplyTo: '',
        fileId: 'f_gone',
        code: 'gone',
      ));
      await expectLater(future, throwsA(isA<AgentFileGoneException>()));
    });

    test('changed → AgentFileChangedException', () async {
      final s = await setup();
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      final future = s.sync.fetchAgentFile('f_changed');
      await _settle();
      s.ch.push(AgentFileError(
        inReplyTo: '',
        fileId: 'f_changed',
        code: 'changed',
      ));
      await expectLater(future, throwsA(isA<AgentFileChangedException>()));
    });

    test('busy auto-retries once after the busy delay, then succeeds',
        () async {
      final s = await setup(busyDelay: const Duration(milliseconds: 40));
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      final future = s.sync.fetchAgentFile('f_busy');
      await _settle();

      s.ch.push(AgentFileError(
        inReplyTo: '',
        fileId: 'f_busy',
        code: 'busy',
      ));
      // Not yet: the retry delay has not elapsed.
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(s.ch.sent.whereType<AgentFileFetch>(), hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 60));
      final fetches = s.ch.sent.whereType<AgentFileFetch>().toList();
      expect(fetches, hasLength(2), reason: 'busy triggered one auto-retry');
      expect(fetches.last.offset, 0);

      s.ch.push(AgentFilePayload(
        inReplyTo: fetches.last.id,
        fileId: 'f_busy',
        offset: 0,
        total: 2,
        data: 'aGk=',
        more: false,
      ));
      expect(utf8.decode(await future), 'hi');
    });

    test('second busy surfaces (no infinite auto-retry)', () async {
      final s = await setup(busyDelay: const Duration(milliseconds: 40));
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      final future = s.sync.fetchAgentFile('f_busy2');
      await _settle();
      s.ch.push(AgentFileError(inReplyTo: '', fileId: 'f_busy2', code: 'busy'));
      await Future<void>.delayed(const Duration(milliseconds: 70));
      s.ch.push(AgentFileError(inReplyTo: '', fileId: 'f_busy2', code: 'busy'));
      await expectLater(
        future,
        throwsA(isA<AgentFileUnavailableException>()),
      );
    });

    test('silent chunk loss: watchdog re-requests the same offset', () async {
      final s = await setup(chunkTimeout: const Duration(milliseconds: 60));
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      final future = s.sync.fetchAgentFile('f_watch');
      await _settle();
      expect(s.ch.sent.whereType<AgentFileFetch>(), hasLength(1));

      // Nothing arrives for one watchdog period → same offset re-requested.
      // Elapsed = 30ms settle + 70ms ≈ 100ms: period 1 (60ms) fired, period 2
      // (120ms) has not → exactly one re-send.
      await Future<void>.delayed(const Duration(milliseconds: 70));
      final fetches = s.ch.sent.whereType<AgentFileFetch>().toList();
      expect(fetches, hasLength(2));
      expect(fetches.last.offset, 0);

      s.ch.push(AgentFilePayload(
        inReplyTo: fetches.last.id,
        fileId: 'f_watch',
        offset: 0,
        total: 2,
        data: 'b2s=',
        more: false,
      ));
      expect(utf8.decode(await future), 'ok');
    });

    test('out-of-order/duplicate chunk is dropped; correct one completes',
        () async {
      // Long watchdog: the test pushes frames by hand and must not race the
      // resend timer.
      final s = await setup(
        chunkTimeout: const Duration(seconds: 30),
      );
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      final future = s.sync.fetchAgentFile('f_dup_chunk');
      await _settle();
      final first = s.ch.sent.whereType<AgentFileFetch>().single;

      // Wrong offset (stale replay) — must be ignored, not appended.
      s.ch.push(AgentFilePayload(
        inReplyTo: first.id,
        fileId: 'f_dup_chunk',
        offset: 999,
        total: 5,
        data: 'aGVsbG8=',
        more: true,
      ));
      await _settle();
      expect(
        s.ch.sent.whereType<AgentFileFetch>(),
        hasLength(1),
        reason: 'no next request for a dropped chunk',
      );

      s.ch.push(AgentFilePayload(
        inReplyTo: first.id,
        fileId: 'f_dup_chunk',
        offset: 0,
        total: 5,
        data: 'aGVsbG8=',
        more: false,
      ));
      expect(utf8.decode(await future), 'hello');
    });

    test('send failure (teardown race) is swallowed; watchdog recovers',
        () async {
      final s = await setup(chunkTimeout: const Duration(milliseconds: 60));
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      s.ch.failNextSends = 1;
      final future = s.sync.fetchAgentFile('f_sendfail');
      await _settle();
      expect(s.ch.sent.whereType<AgentFileFetch>(), isEmpty,
          reason: 'the first send was rejected by the channel');

      // The watchdog re-requests on the (now healthy) channel. Total elapsed
      // = 30ms settle + 40ms ≈ 70ms: one watchdog period (60ms) has passed →
      // exactly one re-send; the second period (120ms) has not.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final fetches = s.ch.sent.whereType<AgentFileFetch>().toList();
      expect(fetches, hasLength(1));

      s.ch.push(AgentFilePayload(
        inReplyTo: fetches.last.id,
        fileId: 'f_sendfail',
        offset: 0,
        total: 3,
        data: 'eWVz',
        more: false,
      ));
      expect(utf8.decode(await future), 'yes');
    });

    test('attempt budget exhausted → timed-out failure', () async {
      final s = await setup(chunkTimeout: const Duration(milliseconds: 40));
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      final future = s.sync.fetchAgentFile('f_dead');
      // initial + 2 resends, each after 40ms — silence throughout.
      await expectLater(
        future.timeout(const Duration(seconds: 2)),
        throwsA(
          isA<AgentFileUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
      // initial + 2 watchdog resends, then stop.
      expect(s.ch.sent.whereType<AgentFileFetch>().length, 3);
    });

    test('concurrent callers share one transfer', () async {
      final s = await setup();
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      final f1 = s.sync.fetchAgentFile('f_share');
      final f2 = s.sync.fetchAgentFile('f_share');
      await _settle();
      expect(s.ch.sent.whereType<AgentFileFetch>(), hasLength(1));

      final first = s.ch.sent.whereType<AgentFileFetch>().single;
      s.ch.push(AgentFilePayload(
        inReplyTo: first.id,
        fileId: 'f_share',
        offset: 0,
        total: 4,
        data: 'c2FtZQ==',
        more: false,
      ));
      expect(identical(await f1, await f2), isTrue);
    });

    test('stray payload after completion does not crash', () async {
      final s = await setup();
      addTearDown(() {
        s.conn.dispose();
        s.sync.dispose();
      });

      final future = s.sync.fetchAgentFile('f_stray');
      await _settle();
      final first = s.ch.sent.whereType<AgentFileFetch>().single;
      s.ch.push(AgentFilePayload(
        inReplyTo: first.id,
        fileId: 'f_stray',
        offset: 0,
        total: 2,
        data: 'aGk=',
        more: false,
      ));
      expect(utf8.decode(await future), 'hi');
      s.ch.push(AgentFilePayload(
        inReplyTo: first.id,
        fileId: 'f_stray',
        offset: 2,
        total: 2,
        data: 'IQ==',
        more: false,
      ));
      await _settle(); // no unhandled async error
    });

    test('fetch without a live channel fails immediately', () async {
      // No channel ever adopted → _conn.channel is null (offline path).
      final conn = ConnectionManager(
        factory: (_, _) async => _FakeChannel(),
        storage: _FakeStorage(),
        emitDebounce: Duration.zero,
      );
      final sync = SyncService(conn, LocalBoxes());
      addTearDown(() {
        conn.dispose();
        sync.dispose();
      });
      await _settle();
      await expectLater(
        sync.fetchAgentFile('f_off'),
        throwsA(isA<AgentFileUnavailableException>()),
      );
    });
  });

  group('MessageRecord ref round-trip', () {
    test('toJson/fromJson keeps fileId/name/bytes and drops nothing', () {
      final r = MessageRecord(
        id: 'f_rt',
        seq: 0,
        role: MsgRole.assistant,
        text: 'cap',
        file: const MessageFile(
          kind: 'pdf',
          data: null,
          mime: 'application/pdf',
          fileId: 'f_rt',
          name: 'report.pdf',
          bytes: 12582912,
        ),
        ts: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final restored = MessageRecord.fromJson(r.toJson());
      expect(restored.file, r.file);
      final msg = restored.toChatMessage() as AgentFileMsg;
      expect(msg.fileId, 'f_rt');
      expect(msg.name, 'report.pdf');
      expect(msg.bytes, 12582912);
      expect(msg.data, isNull);
    });
  });
}
