// Plan/137 — ConnectionManager turns a relay `route_error` control frame
// into (a) an event on routeErrorStream and (b) an offline presence flip for
// the destination peer, so the active chat can fail pending steers instead
// of spinning forever.

import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

PeerRecord _fakePeer() => const PeerRecord(
      remoteEpk: 'epk_route',
      sessionName: 'pi',
      relayUrl: 'ws://localhost',
      pairedAt: '2026-01-01T00:00:00Z',
    );

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => [_fakePeer()];

  @override
  Future<PeerRecord?> loadPeer(String epk) async =>
      epk == _fakePeer().remoteEpk ? _fakePeer() : null;

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

void main() {
  test('route_error fires the stream and flips presence offline', () async {
    final ch = _ControllableChannel();
    final cm = ConnectionManager(
      factory: (_, _) async => ch,
      storage: _FakeStorage(),
      emitDebounce: Duration.zero,
    );
    await cm.connectTo(_fakePeer());
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Seed online presence for the destination peer.
    ch.pushControl(const PeerOnline(peer: 'epk_dest'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(cm.presenceFor('epk_dest'), isA<PresenceOnline>());

    final events = <RouteErrorEvent>[];
    final sub = cm.routeErrorStream.listen(events.add);

    ch.pushControl(const RouteError(peer: 'epk_dest', room: 'roomA'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(events, hasLength(1));
    // ConnectionManager canonicalizes the destination to standard base64
    // (url-safe `_` → `/`).
    expect(events.single.epk, 'epk/dest');
    expect(events.single.roomId, 'roomA');
    expect(cm.presenceFor('epk_dest'), isA<PresenceOffline>(),
        reason: 'unroutable destination → chat banner reacts');

    await sub.cancel();
    cm.dispose();
  });

  test('a route_error for another peer does not touch the active room',
      () async {
    final ch = _ControllableChannel();
    final cm = ConnectionManager(
      factory: (_, _) async => ch,
      storage: _FakeStorage(),
      emitDebounce: Duration.zero,
    );
    await cm.connectTo(_fakePeer());
    await Future<void>.delayed(const Duration(milliseconds: 10));

    ch.pushControl(const PeerOnline(peer: 'epk_other'));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    final events = <RouteErrorEvent>[];
    final sub = cm.routeErrorStream.listen(events.add);

    ch.pushControl(const RouteError(peer: 'epk_other', room: 'roomB'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // The event still fires (consumers filter by (epk, room) themselves —
    // SyncService only acts on the ACTIVE room).
    expect(events, hasLength(1));
    // Presence flipped for THAT peer only.
    expect(cm.presenceFor('epk_other'), isA<PresenceOffline>());

    await sub.cancel();
    cm.dispose();
  });
}
