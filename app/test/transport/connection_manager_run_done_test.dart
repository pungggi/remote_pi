// Plan/132 — ConnectionManager forwards `meta.run_done` markers to
// runDoneStream for EVERY subscribed room (before any room-cache dedup and
// independent of the room being cached yet).

import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

PeerRecord _fakePeer() => const PeerRecord(
      remoteEpk: 'epk_test',
      sessionName: 'pi',
      relayUrl: 'ws://localhost',
      pairedAt: '2026-01-01T00:00:00Z',
    );

class _FakeStorage extends PairingStorage {
  final List<PeerRecord> peers;
  _FakeStorage(this.peers);

  @override
  Future<List<PeerRecord>> listPeers() async => peers;

  @override
  Future<void> savePeer(PeerRecord r) async {}

  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {}

  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => const [];

  @override
  Future<void> deleteRooms(String epk) async {}
}

class _ControllableChannel implements IChannel, IControlLink {
  final _serverCtrl = StreamController<ServerMessage>.broadcast();
  final _controlCtrl = StreamController<ControlInbound>.broadcast();

  @override
  Stream<ServerMessage> get serverMessages => _serverCtrl.stream;

  @override
  Stream<ControlInbound> get controlFrames => _controlCtrl.stream;

  @override
  Future<void> send(ClientMessage msg) async {}

  @override
  void sendControl(Map<String, dynamic> json) {}

  @override
  Future<void> close() async {
    await _serverCtrl.close();
    await _controlCtrl.close();
  }

  void pushControl(ControlInbound m) => _controlCtrl.add(m);

  // Avoid analyzer "unused" on the import.
  // ignore: unused_element
  Uint8List _placeholder() => Uint8List(0);
}

Future<ConnectionManager> _connected(_ControllableChannel ch) async {
  final cm = ConnectionManager(
    factory: (_, _) async => ch,
    storage: _FakeStorage([_fakePeer()]),
    emitDebounce: Duration.zero,
  );
  await cm.connectTo(_fakePeer());
  await Future<void>.delayed(const Duration(milliseconds: 10));
  return cm;
}

void main() {
  test('room_meta_updated with run_done emits on runDoneStream', () async {
    final ch = _ControllableChannel();
    final cm = await _connected(ch);
    final received = <RunDoneEvent>[];
    final sub = cm.runDoneStream.listen(received.add);

    ch.pushControl(const RoomMetaUpdated(
      peer: 'epk_test',
      roomId: 'r1',
      working: false,
      runDone: RunDoneMarker(turnId: 'turn-9', endedAtMs: 1735689600000),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(received.length, 1);
    expect(received.single.epk, toStandardB64('epk_test'));
    expect(received.single.roomId, 'r1');
    expect(received.single.marker.turnId, 'turn-9');
    expect(received.single.marker.endedAtMs, 1735689600000);

    await sub.cancel();
    cm.dispose();
  });

  test('marker fires even for a room with NO state change (dedup bypass)',
      () async {
    final ch = _ControllableChannel();
    final cm = await _connected(ch);
    final received = <RunDoneEvent>[];
    final sub = cm.runDoneStream.listen(received.add);

    // Same working value twice — the room-cache dedup would absorb the
    // second frame, but the marker is an event and must ride both.
    const frame = RoomMetaUpdated(
      peer: 'epk_test',
      roomId: 'r1',
      working: true,
      runDone: RunDoneMarker(turnId: 'a', endedAtMs: 1),
    );
    ch.pushControl(frame);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    ch.pushControl(const RoomMetaUpdated(
      peer: 'epk_test',
      roomId: 'r1',
      working: true,
      runDone: RunDoneMarker(turnId: 'b', endedAtMs: 2),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(received.length, 2);
    expect(received.map((e) => e.marker.turnId), ['a', 'b']);

    await sub.cancel();
    cm.dispose();
  });

  test('marker fires for a room never announced (no cache entry)', () async {
    final ch = _ControllableChannel();
    final cm = await _connected(ch);
    final received = <RunDoneEvent>[];
    final sub = cm.runDoneStream.listen(received.add);

    ch.pushControl(const RoomMetaUpdated(
      peer: 'epk_test',
      roomId: 'never-cached',
      runDone: RunDoneMarker(turnId: null, endedAtMs: 7),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(received.length, 1);
    expect(received.single.roomId, 'never-cached');
    expect(received.single.marker.turnId, isNull);

    await sub.cancel();
    cm.dispose();
  });

  test('meta update WITHOUT run_done emits nothing', () async {
    final ch = _ControllableChannel();
    final cm = await _connected(ch);
    final received = <RunDoneEvent>[];
    final sub = cm.runDoneStream.listen(received.add);

    ch.pushControl(const RoomMetaUpdated(
      peer: 'epk_test',
      roomId: 'r1',
      working: true,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(received, isEmpty);

    await sub.cancel();
    cm.dispose();
  });
}
