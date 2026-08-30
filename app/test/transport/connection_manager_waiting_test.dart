// Plan/134 — ConnectionManager propagates `meta.waiting_for_input` from
// `room_announced` / `room_meta_updated` / `rooms` into
// RoomInfo.waitingForInput, exposes it via `isRoomWaitingForInput`, and
// emits TRANSITIONS on waitingForInputStream (live meta updates only —
// never announce/snapshot replays).

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
  group('ConnectionManager — Plan/134 waiting_for_input propagation', () {
    test('RoomAnnounced with waiting_for_input seeds the flag + getter',
        () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);

      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
        waitingForInput: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(cm.roomsFor('epk_test').single.waitingForInput, isTrue);
      expect(cm.isRoomWaitingForInput('epk_test', 'r1'), isTrue);

      cm.dispose();
    });

    test('waiting-only meta update sets the flag WITHOUT touching working',
        () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);

      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
        working: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // Prompt opens mid-turn: waiting=true rides, working stays true.
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        waitingForInput: true,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(cm.isRoomWaitingForInput('epk_test', 'r1'), isTrue);
      expect(cm.isRoomWorking('epk_test', 'r1'), isTrue,
          reason: 'the turn stays open while the prompt blocks');

      // Prompt answered: waiting=false, working still true.
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        waitingForInput: false,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(cm.isRoomWaitingForInput('epk_test', 'r1'), isFalse);
      expect(cm.isRoomWorking('epk_test', 'r1'), isTrue);

      cm.dispose();
    });

    test('model-only update preserves a previously-set waiting=true',
        () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);

      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        waitingForInput: true,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        model: 'gpt-4o',
        hasModel: true,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(cm.isRoomWaitingForInput('epk_test', 'r1'), isTrue,
          reason: 'absent waiting_for_input in a meta update must not clear');
      expect(cm.roomsFor('epk_test').single.model, 'gpt-4o');

      cm.dispose();
    });

    test('rooms snapshot carries waiting_for_input per room', () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);

      ch.pushControl(const RoomsSnapshot(
        peer: 'epk_test',
        rooms: [
          RoomInfo(roomId: 'r1', startedAt: 1, waitingForInput: true),
          RoomInfo(roomId: 'r2', startedAt: 1, waitingForInput: false),
        ],
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(cm.isRoomWaitingForInput('epk_test', 'r1'), isTrue);
      expect(cm.isRoomWaitingForInput('epk_test', 'r2'), isFalse);

      cm.dispose();
    });

    test('isRoomWaitingForInput is false when the WS is offline', () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);

      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        waitingForInput: true,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.isRoomWaitingForInput('epk_test', 'r1'), isTrue);

      await cm.disconnect();
      expect(cm.isRoomWaitingForInput('epk_test', 'r1'), isFalse);

      cm.dispose();
    });
  });

  group('ConnectionManager — Plan/134 waiting transitions', () {
    test('live meta update emits a rising AND a falling edge', () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);
      final received = <WaitingForInputEvent>[];
      final sub = cm.waitingForInputStream.listen(received.add);

      // Cache the room first (idle, not waiting) so the state write lands.
      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(received, isEmpty,
          reason: 'the announce itself is a replay, not a transition');

      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        waitingForInput: true,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        waitingForInput: false,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(received.length, 2);
      expect(received[0].epk, toStandardB64('epk_test'));
      expect(received[0].roomId, 'r1');
      expect(received[0].waiting, isTrue);
      expect(received[1].waiting, isFalse);

      await sub.cancel();
      cm.dispose();
    });

    test(
        'app-open replays (room_announced / rooms snapshot) emit NO transition',
        () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);
      final received = <WaitingForInputEvent>[];
      final sub = cm.waitingForInputStream.listen(received.add);

      // A fresh app sees waiting=true arrive via announce…
      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
        waitingForInput: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // …and via the rooms snapshot after a reconnect.
      ch.pushControl(const RoomsSnapshot(
        peer: 'epk_test',
        rooms: [RoomInfo(roomId: 'r1', startedAt: 1, waitingForInput: true)],
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(received, isEmpty,
          reason: 'replays must not re-fire the notification');

      await sub.cancel();
      cm.dispose();
    });

    test('non-transition meta update (same flag) emits nothing', () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);
      final received = <WaitingForInputEvent>[];
      final sub = cm.waitingForInputStream.listen(received.add);

      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        waitingForInput: true,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // A model swap while still waiting: waiting stays true.
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        model: 'gpt-4o',
        waitingForInput: true,
        hasModel: true,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(received.length, 1, reason: 'only the initial rising edge');

      await sub.cancel();
      cm.dispose();
    });

    test('rising edge fires for a room never announced (no cache entry)',
        () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);
      final received = <WaitingForInputEvent>[];
      final sub = cm.waitingForInputStream.listen(received.add);

      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'never-cached',
        waitingForInput: true,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(received.length, 1);
      expect(received.single.roomId, 'never-cached');
      expect(received.single.waiting, isTrue);

      await sub.cancel();
      cm.dispose();
    });
  });
}
