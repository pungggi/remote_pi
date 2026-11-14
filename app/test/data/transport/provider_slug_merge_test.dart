// Plan/161 — the provider slug rides room_meta like `model` (absent =
// preserve). Pins the ConnectionManager merge rules:
//   * announce: wire wins; a provider-less announce from an older extension
//     preserves the cached slug
//   * live update: a model+provider patch switches the slug (app re-groups);
//     a provider-absent patch preserves it
//   * rooms snapshot: omitted provider preserves the cached slug

import 'dart:async';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeChannel implements IChannel, IControlLink {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final _controlCtrl = StreamController<ControlInbound>.broadcast();

  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;

  @override
  Stream<ControlInbound> get controlFrames => _controlCtrl.stream;

  @override
  Future<void> send(ClientMessage msg) async {}

  @override
  void sendControl(Map<String, dynamic> json) {}

  @override
  Future<void> close() async {
    await _ctrl.close();
    await _controlCtrl.close();
  }

  void pushControl(ControlInbound m) => _controlCtrl.add(m);
}

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

const _epk = 'epk_provider_slug';

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

void main() {
  group('provider slug merge (plan/161)', () {
    test('announce seeds the slug; a later provider patch switches it', () async {
      final s = await _setup();
      s.ch.pushControl(
        const RoomAnnounced(
          peer: _epk,
          roomId: 'main',
          startedAt: 1,
          model: 'GLM 4.7',
          provider: 'zai',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(s.cm.roomsFor(_epk).single.provider, 'zai');

      // Cross-provider one-shot override: model + provider in one patch.
      s.ch.pushControl(
        const RoomMetaUpdated(
          peer: _epk,
          roomId: 'main',
          model: 'Kimi K3.1',
          provider: 'kimi-coding',
          hasModel: true,
          hasProvider: true,
          hasThinking: false,
          hasGit: false,
          hasContextUsage: false,
          hasPlanUsage: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final room = s.cm.roomsFor(_epk).single;
      expect(room.model, 'Kimi K3.1');
      expect(room.provider, 'kimi-coding');
      s.cm.dispose();
    });

    test('provider-absent patches preserve the cached slug', () async {
      final s = await _setup();
      s.ch.pushControl(
        const RoomAnnounced(
          peer: _epk,
          roomId: 'main',
          startedAt: 1,
          model: 'GLM 4.7',
          provider: 'zai',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Same-provider model switch (provider key absent) and a working
      // toggle must both keep the slug.
      s.ch.pushControl(
        const RoomMetaUpdated(
          peer: _epk,
          roomId: 'main',
          model: 'GLM 4.6',
          hasModel: true,
          hasProvider: false,
          hasThinking: false,
          hasGit: false,
          hasContextUsage: false,
          hasPlanUsage: false,
        ),
      );
      s.ch.pushControl(
        const RoomMetaUpdated(
          peer: _epk,
          roomId: 'main',
          working: true,
          hasModel: false,
          hasProvider: false,
          hasThinking: false,
          hasGit: false,
          hasContextUsage: false,
          hasPlanUsage: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final room = s.cm.roomsFor(_epk).single;
      expect(room.model, 'GLM 4.6');
      expect(room.provider, 'zai');
      s.cm.dispose();
    });

    test('legacy announce without provider and snapshot both preserve', () async {
      final s = await _setup();
      s.ch.pushControl(
        const RoomAnnounced(
          peer: _epk,
          roomId: 'main',
          startedAt: 1,
          model: 'GLM 4.7',
          provider: 'zai',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Older extension re-announces without the field → keep the slug.
      s.ch.pushControl(
        const RoomAnnounced(
          peer: _epk,
          roomId: 'main',
          startedAt: 2,
          model: 'GLM 4.7',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(s.cm.roomsFor(_epk).single.provider, 'zai');

      // Older relay snapshot omits it too → keep.
      s.ch.pushControl(
        const RoomsSnapshot(
          peer: _epk,
          rooms: [RoomInfo(roomId: 'main', startedAt: 3, model: 'GLM 4.7')],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(s.cm.roomsFor(_epk).single.provider, 'zai');
      s.cm.dispose();
    });
  });
}
