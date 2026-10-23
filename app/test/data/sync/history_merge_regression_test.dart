// Scratch repro for the (b1) device finding — plan/145 verification round.
// Proves: live-streamed text + later session_history must neither duplicate
// (single-block: re-key in place) nor lose blocks (multi-block: amsg ids).

import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
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

void main() {
  late Directory dir;
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('rp_b1_');
    await LocalBoxes.initForTest(dir.path);
  });
  tearDownAll(() async {
    await Hive.close();
    dir.delete(recursive: true);
  });

  Future<({ConnectionManager conn, _FakeChannel ch, SyncService sync, String epk})>
  setup(String epk) async {
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
    return (conn: conn, ch: ch, sync: sync, epk: epk);
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

  test('SINGLE-block turn: live stream + later history sync = exactly one row',
      () async {
    final s = await setup('epk_single');
    final now = DateTime.now().millisecondsSinceEpoch;
    s.ch.push(UserInput(id: 'u1', text: 'frage'));
    await _settle();
    s.ch.push(AgentChunk(inReplyTo: 't1', delta: 'antwort'));
    s.ch.push(AgentDone(inReplyTo: 't1', text: 'antwort'));
    await _settle();

    // Reconnect → history (new wire shape: amsg id).
    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: [
          UserInputEvt(ts: now, id: 'sync_$now', text: 'frage'),
          AgentMessageEvt(
            ts: now + 1,
            inReplyTo: 'sync_$now',
            id: 'amsg_${now + 1}',
            text: 'antwort',
          ),
        ],
        eos: true,
      ),
    );
    await _settle();

    final assistants =
        msgs(s.epk).where((r) => r.role == MsgRole.assistant).toList();
    expect(assistants, hasLength(1), reason: 'live + sync must not duplicate');
    expect(assistants.single.text, 'antwort');
    s.conn.dispose();
    s.sync.dispose();
  });

  test('MULTI-block turn ((b1) exact): wave1 live, waves 2+3 lost, sync after '
      '→ no dup, nothing lost', () async {
    final s = await setup('epk_multi');
    final now = DateTime.now().millisecondsSinceEpoch;
    s.ch.push(UserInput(id: 'u1', text: 'frage'));
    await _settle();
    // Wave 1 delivered live, finalized at the tool boundary…
    s.ch.push(AgentChunk(inReplyTo: 't1', delta: 'WELLE-1 '));
    s.ch.push(ToolRequest(toolCallId: 'c1', tool: 'bash', args: null));
    await _settle();
    // …flap: waves 2+3 never arrive. Reconnect → history with the fixed
    // mapper shape: unique amsg ids per block, shared in_reply_to.
    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: [
          UserInputEvt(ts: now, id: 'sync_$now', text: 'frage'),
          AgentMessageEvt(
            ts: now + 10,
            inReplyTo: 'sync_$now',
            id: 'amsg_${now + 10}',
            text: 'WELLE-1 ',
          ),
          ToolRequestEvt(ts: now + 20, toolCallId: 'c1', tool: 'bash', args: null),
          AgentMessageEvt(
            ts: now + 30,
            inReplyTo: 'sync_$now',
            id: 'amsg_${now + 30}',
            text: 'WELLE-2 ',
          ),
          ToolRequestEvt(ts: now + 40, toolCallId: 'c2', tool: 'bash', args: null),
          AgentMessageEvt(
            ts: now + 50,
            inReplyTo: 'sync_$now',
            id: 'amsg_${now + 50}',
            text: 'WELLE-3',
          ),
        ],
        eos: true,
      ),
    );
    await _settle();

    final rows = msgs(s.epk);
    final assistants =
        rows.where((r) => r.role == MsgRole.assistant).toList();
    final texts = assistants.map((r) => r.text).toList();
    expect(texts, ['WELLE-1 ', 'WELLE-2 ', 'WELLE-3'],
        reason: 'all three blocks, exactly once each, in order');
    // The live-streamed copy was re-keyed, not duplicated.
    expect(assistants.every((r) => r.id.startsWith('amsg_')), isTrue,
        reason: 'streamed agent_ row replaced by the authoritative sync row');
    s.conn.dispose();
    s.sync.dispose();
  });

  test('LEGACY ext (no amsg ids): single-block still dedups via text match',
      () async {
    final s = await setup('epk_legacy');
    final now = DateTime.now().millisecondsSinceEpoch;
    s.ch.push(UserInput(id: 'u1', text: 'frage'));
    await _settle();
    s.ch.push(AgentChunk(inReplyTo: 't1', delta: 'antwort'));
    s.ch.push(AgentDone(inReplyTo: 't1', text: 'antwort'));
    await _settle();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: [
          UserInputEvt(ts: now, id: 'sync_$now', text: 'frage'),
          AgentMessageEvt(ts: now + 1, inReplyTo: 'sync_$now', text: 'antwort'),
        ],
        eos: true,
      ),
    );
    await _settle();
    final assistants =
        msgs(s.epk).where((r) => r.role == MsgRole.assistant).toList();
    expect(assistants, hasLength(1));
    s.conn.dispose();
    s.sync.dispose();
  });
}
