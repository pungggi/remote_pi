// PR #67 review fix — stale `context_usage` across a model switch.
//
// The tile pairs the model name with `context_usage.contextWindow`
// (`new-model · 200k`) and paints the fill bar from its tokens. A
// model-only `room_meta_update` (what `_setCurrentModel` publishes on
// `model_select`) used to PRESERVE the previous model's cached usage, so
// the new model wore the old window until the next response. These tests
// pin the three merge rules that prevent that:
//   * live update: model change without fresh usage → clear
//   * live update: explicit `context_usage: null` (extension tombstone)
//     → clear; same-model republish → preserve
//   * rooms snapshot: local usage survives only when it belongs to the
//     model the snapshot displays (offline-during-switch window)

import 'dart:async';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeChannel implements IChannel, IControlLink {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final _controlCtrl = StreamController<ControlInbound>.broadcast();
  final List<ClientMessage> sent = [];

  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;

  @override
  Stream<ControlInbound> get controlFrames => _controlCtrl.stream;

  @override
  Future<void> send(ClientMessage msg) async {
    sent.add(msg);
  }

  @override
  void sendControl(Map<String, dynamic> json) {}

  @override
  Future<void> close() async {
    await _ctrl.close();
    await _controlCtrl.close();
  }

  void push(ServerMessage m) => _ctrl.add(m);
  void pushControl(ControlInbound m) => _controlCtrl.add(m);
}

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

const _epk = 'epk_usage';

Future<({ConnectionManager cm, _FakeChannel ch})> _setup() async {
  final ch = _FakeChannel();
  final cm = ConnectionManager(
    factory: (_, _) async => ch,
    storage: _FakeStorage(),
    emitDebounce: Duration.zero,
  );
  cm.adopt(
    ch,
    const PeerRecord(
      remoteEpk: _epk,
      sessionName: 'pi',
      relayUrl: 'ws://localhost',
      pairedAt: '2026-01-01T00:00:00Z',
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 5));
  return (cm: cm, ch: ch);
}

/// Announce the room with a model, then push a usage update — the state
/// the tile renders before the switch.
Future<void> _seedWithUsage(_FakeChannel ch) async {
  ch.pushControl(
    const RoomAnnounced(
      peer: _epk,
      roomId: 'main',
      startedAt: 1,
      model: 'old-model',
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 10));
  ch.pushControl(
    const RoomMetaUpdated(
      peer: _epk,
      roomId: 'main',
      contextUsage: ContextUsage(
        tokens: 100000,
        contextWindow: 200000,
        percent: 50,
      ),
      hasContextUsage: true,
      hasModel: false,
      hasThinking: false,
      hasGit: false,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

void main() {
  group('context_usage invalidation on model switch (PR #67 review)', () {
    test('model-only update with a DIFFERENT model clears cached usage',
        () async {
      final s = await _setup();
      await _seedWithUsage(s.ch);
      expect(
        s.cm.roomsFor(_epk).single.contextUsage?.contextWindow,
        200000,
        reason: 'precondition: usage cached for the old model',
      );

      s.ch.pushControl(
        const RoomMetaUpdated(
          peer: _epk,
          roomId: 'main',
          model: 'new-model',
          hasModel: true,
          hasThinking: false,
          hasGit: false,
          // NB: has* flags default to TRUE in the constructor — a raw
          // model-only push would double as a context_usage tombstone
          // and pass for the wrong reason. Keep every flag explicit.
          hasContextUsage: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final room = s.cm.roomsFor(_epk).single;
      expect(room.model, 'new-model');
      expect(
        room.contextUsage,
        isNull,
        reason: 'old-model usage must not label the new model `· 200k`',
      );
      s.cm.dispose();
    });

    test('model-only update with the SAME model preserves usage (republish)',
        () async {
      final s = await _setup();
      await _seedWithUsage(s.ch);

      s.ch.pushControl(
        const RoomMetaUpdated(
          peer: _epk,
          roomId: 'main',
          model: 'old-model', // idempotent republish, no switch
          hasModel: true,
          hasThinking: false,
          hasGit: false,
          hasContextUsage: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        s.cm.roomsFor(_epk).single.contextUsage?.contextWindow,
        200000,
        reason: 'no model change → the bar must not flicker away',
      );
      s.cm.dispose();
    });

    test('explicit context_usage: null (extension tombstone) clears',
        () async {
      final s = await _setup();
      await _seedWithUsage(s.ch);

      s.ch.pushControl(
        const RoomMetaUpdated(
          peer: _epk,
          roomId: 'main',
          contextUsage: null,
          hasContextUsage: true,
          hasModel: false,
          hasThinking: false,
          hasGit: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(s.cm.roomsFor(_epk).single.contextUsage, isNull);
      s.cm.dispose();
    });

    test('rooms snapshot with a DIFFERENT model drops stale local usage',
        () async {
      final s = await _setup();
      await _seedWithUsage(s.ch);

      // Offline during the switch: the extension cleared its side, so the
      // snapshot omits context_usage but carries the NEW model.
      s.ch.pushControl(
        const RoomsSnapshot(
          peer: _epk,
          rooms: [
            RoomInfo(roomId: 'main', startedAt: 1, model: 'new-model'),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final room = s.cm.roomsFor(_epk).single;
      expect(room.model, 'new-model');
      expect(
        room.contextUsage,
        isNull,
        reason: 'snapshot model differs → local usage is from the old model',
      );
      s.cm.dispose();
    });

    test('rooms snapshot with the SAME model keeps local usage', () async {
      final s = await _setup();
      await _seedWithUsage(s.ch);

      s.ch.pushControl(
        const RoomsSnapshot(
          peer: _epk,
          rooms: [
            RoomInfo(roomId: 'main', startedAt: 1, model: 'old-model'),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        s.cm.roomsFor(_epk).single.contextUsage?.contextWindow,
        200000,
        reason: 'same model → usage still valid, keep the bar',
      );
      s.cm.dispose();
    });
  });
}
