// Plan/156 — provider subscription usage (`plan_usage`) across a model
// switch.
//
// Unlike `context_usage` (PR #67), plan usage is ACCOUNT-scoped: it belongs
// to the provider subscription, not to the model that reported it. These
// tests pin the deliberately different merge rules:
//   * live update: model change (even to another model of the SAME
//     provider) KEEPS the quota — only the extension's explicit
//     `plan_usage: null` (published on a PROVIDER change) clears it
//   * rooms snapshot: local usage survives regardless of the snapshot's
//     model; the next live publish refreshes or clears it within minutes

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

const _epk = 'epk_plan_usage';

const _seedUsage = PlanUsage(
  provider: 'zai',
  plan: 'max',
  fetchedAt: 42,
  windows: [
    PlanUsageWindow(kind: 'time', label: 'mo', percent: 0, minutes: 43200),
    PlanUsageWindow(kind: 'tokens', label: '5h', percent: 3, minutes: 300),
    PlanUsageWindow(kind: 'tokens', label: 'wk', percent: 4, minutes: 10080),
  ],
);

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

/// Announce the room with a model, then push a plan-usage update — the
/// state the group header renders before the switch.
Future<void> _seedWithUsage(_FakeChannel ch) async {
  ch.pushControl(
    const RoomAnnounced(
      peer: _epk,
      roomId: 'main',
      startedAt: 1,
      model: 'GLM-4.6',
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 10));
  ch.pushControl(
    const RoomMetaUpdated(
      peer: _epk,
      roomId: 'main',
      planUsage: _seedUsage,
      hasPlanUsage: true,
      hasModel: false,
      hasThinking: false,
      hasGit: false,
      hasContextUsage: false,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

void main() {
  group('plan_usage semantics on model switch (plan/156)', () {
    test('model-only update KEEPS cached usage (account-scoped)', () async {
      final s = await _setup();
      await _seedWithUsage(s.ch);
      expect(
        s.cm.roomsFor(_epk).single.planUsage?.provider,
        'zai',
        reason: 'precondition: usage cached for the provider',
      );

      // Same-provider switch (GLM-4.6 → GLM-4.5-Air): the extension does
      // NOT tombstone plan_usage here, and neither must the app.
      s.ch.pushControl(
        const RoomMetaUpdated(
          peer: _epk,
          roomId: 'main',
          model: 'GLM-4.5-Air',
          hasModel: true,
          hasThinking: false,
          hasGit: false,
          hasContextUsage: false,
          hasPlanUsage: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final room = s.cm.roomsFor(_epk).single;
      expect(room.model, 'GLM-4.5-Air');
      expect(
        room.planUsage?.maxPercent,
        4,
        reason: 'quota belongs to the account, not the model',
      );
      s.cm.dispose();
    });

    test('explicit plan_usage: null (provider-change tombstone) clears',
        () async {
      final s = await _setup();
      await _seedWithUsage(s.ch);

      s.ch.pushControl(
        const RoomMetaUpdated(
          peer: _epk,
          roomId: 'main',
          planUsage: null,
          hasPlanUsage: true,
          hasModel: false,
          hasThinking: false,
          hasGit: false,
          hasContextUsage: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(s.cm.roomsFor(_epk).single.planUsage, isNull);
      s.cm.dispose();
    });

    test('rooms snapshot keeps local usage even across a model change',
        () async {
      final s = await _setup();
      await _seedWithUsage(s.ch);

      // Snapshot omits plan_usage and carries another model: the usage is
      // still the account's truth; the next live publish refreshes it.
      s.ch.pushControl(
        const RoomsSnapshot(
          peer: _epk,
          rooms: [
            RoomInfo(roomId: 'main', startedAt: 1, model: 'GLM-4.5-Air'),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final room = s.cm.roomsFor(_epk).single;
      expect(room.model, 'GLM-4.5-Air');
      expect(room.planUsage?.provider, 'zai');
      s.cm.dispose();
    });

    test('announce carrying plan_usage seeds the cache', () async {
      final s = await _setup();
      s.ch.pushControl(
        const RoomAnnounced(
          peer: _epk,
          roomId: 'main',
          startedAt: 1,
          model: 'GLM-4.6',
          planUsage: _seedUsage,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(s.cm.roomsFor(_epk).single.planUsage?.plan, 'max');
      s.cm.dispose();
    });
  });
}
