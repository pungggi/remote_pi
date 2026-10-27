import 'dart:async';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
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
  group('ConnectionManager — provider-error propagation', () {
    test('announce seeds, unrelated meta preserves, false clears', () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);

      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
        model: 'claude-opus-4-8',
        providerError: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.roomsFor('epk_test').single.providerError, isTrue);

      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        model: 'gpt-4o',
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(
        cm.roomsFor('epk_test').single.providerError,
        isTrue,
        reason: 'a model-only patch must preserve the failure',
      );

      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        providerError: false,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.roomsFor('epk_test').single.providerError, isFalse);

      cm.dispose();
    });

    test('rooms snapshots carry the current provider-error state', () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);

      ch.pushControl(const RoomsSnapshot(
        peer: 'epk_test',
        rooms: [
          RoomInfo(roomId: 'r1', startedAt: 1, providerError: true),
        ],
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.roomsFor('epk_test').single.providerError, isTrue);

      ch.pushControl(const RoomsSnapshot(
        peer: 'epk_test',
        rooms: [
          RoomInfo(roomId: 'r1', startedAt: 1, providerError: false),
        ],
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.roomsFor('epk_test').single.providerError, isFalse);

      cm.dispose();
    });
  });
}
