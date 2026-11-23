// Plan/170 — ConnectionManager.pendingAskStream device-room contract:
// frames forwarded ONLY while the channel is parked in the device room
// (review #117, r2): an out-of-room pending_ask is out-of-contract noise
// from a misbehaving PC and must not badge arbitrary rooms.

import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _FakeChannel implements IChannel {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final List<ClientMessage> sent = [];

  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Future<void> send(ClientMessage msg) async => sent.add(msg);
  @override
  Future<void> close() async {
    await _ctrl.close();
  }

  void push(ServerMessage m) => _ctrl.add(m);
}

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('rp_pa_guard_');
    await LocalBoxes.initForTest(dir.path);
  });
  tearDownAll(() async {
    await Hive.close();
  });

  test('pending_ask outside the device room is dropped; in it, forwarded',
      () async {
    final ch = _FakeChannel();
    final conn = ConnectionManager(
      factory: (_, _) async => ch,
      storage: _FakeStorage(),
      emitDebounce: Duration.zero,
    );
    addTearDown(conn.dispose);

    conn.adopt(
      ch,
      PeerRecord(
        remoteEpk: 'epkG',
        sessionName: 'Pi',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-01T00:00:00Z',
      ),
    );
    await _settle();
    // adopt() parks the channel in the default room ('main'), NOT device.
    expect(conn.activeRoomId, 'main');

    final events = <PendingAskEvent>[];
    final sub = conn.pendingAskStream.listen(events.add);
    addTearDown(sub.cancel);

    // Out-of-contract: a pending_ask on a non-device connection must not
    // reach the consumer (no badges for arbitrary rooms).
    ch.push(PendingAsk(roomId: 'rX', flowId: 'f1', open: true, ts: 1));
    await _settle();
    expect(events, isEmpty);

    // Parked in the device room (Home/Projects home base) → forwarded,
    // attributed to the channel's peer, room taken from the frame.
    conn.switchRoom(kDeviceRoom);
    ch.push(PendingAsk(roomId: 'rX', flowId: 'f1', open: true, ts: 2));
    await _settle();
    expect(events, hasLength(1));
    expect(events.single.epk, 'epkG');
    expect(events.single.roomId, 'rX');
    expect(events.single.flowId, 'f1');
    expect(events.single.open, isTrue);

    // Leaving the device room closes the window again.
    conn.switchRoom('rX');
    ch.push(PendingAsk(roomId: 'rX', flowId: 'f2', open: true, ts: 3));
    await _settle();
    expect(events, hasLength(1));
  });
}
