import 'dart:async';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/balanced_connection_controller.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/keep_alive_controller.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _peer = PeerRecord(
  remoteEpk: 'epk_test',
  sessionName: 'test',
  relayUrl: 'ws://localhost:8080',
  pairedAt: '2026-01-01T00:00:00Z',
);

class _Storage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [_peer];
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => const [];
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {}
}

class _Prefs extends Preferences {
  _Prefs(this.mode);
  KeepAliveMode mode;
  @override
  KeepAliveMode get keepAliveMode => mode;
  void setMode(KeepAliveMode value) {
    mode = value;
    notifyListeners();
  }
}

class _KeepAlive extends KeepAliveController {
  _KeepAlive(super.prefs) : super(isAndroid: () => false);
  final balancedValues = <bool>[];
  @override
  void setBalancedActive(bool active) {
    if (balancedValues.isEmpty || balancedValues.last != active) {
      balancedValues.add(active);
    }
  }
}

class _Channel implements IChannel, IControlLink {
  final _server = StreamController<ServerMessage>.broadcast();
  final control = StreamController<ControlInbound>.broadcast();
  @override
  Stream<ServerMessage> get serverMessages => _server.stream;
  @override
  Stream<ControlInbound> get controlFrames => control.stream;
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> send(ClientMessage msg) async {}
  @override
  Future<void> close() async {
    await _server.close();
    await control.close();
  }
}

RoomAnnounced _room(String room, bool working) => RoomAnnounced(
  peer: _peer.remoteEpk,
  roomId: room,
  startedAt: 1,
  working: working,
  waitingForInput: false,
);

void main() {
  test(
    'active runs, grace, metadata, waiting wake and foreground are coherent',
    () {
      fakeAsync((async) {
        var now = DateTime.utc(2026, 1, 1);
        final prefs = _Prefs(KeepAliveMode.balanced);
        final keepAlive = _KeepAlive(prefs);
        final channels = <_Channel>[];
        final cm = ConnectionManager(
          factory: (_, _) async {
            final channel = _Channel();
            channels.add(channel);
            return channel;
          },
          storage: _Storage(),
          emitDebounce: Duration.zero,
        );
        cm.boot();
        async.flushMicrotasks();
        final controller = BalancedConnectionController(
          prefs,
          cm,
          keepAlive,
          now: () => now,
        )..attach();
        controller.setBackgrounded(true);
        expect(controller.phase, BalancedPhase.grace);
        final initialDeadline = controller.graceEndsAt;
        prefs.notifyListeners();
        async.flushMicrotasks();
        expect(controller.phase, BalancedPhase.grace);
        expect(controller.graceEndsAt, initialDeadline);
        expect(channels, hasLength(1));

        channels.single.control.add(_room('a', true));
        async.flushMicrotasks();
        expect(controller.phase, BalancedPhase.active);
        expect(cm.hasActiveRuns, isTrue);
        expect(keepAlive.balancedValues.last, isTrue);

        channels.single.control.add(_room('b', true));
        channels.single.control.add(_room('a', false));
        async.flushMicrotasks();
        expect(controller.phase, BalancedPhase.active);
        now = now.add(const Duration(minutes: 1));
        async.elapse(const Duration(minutes: 1));
        channels.single.control.add(_room('b', false));
        async.flushMicrotasks();
        expect(controller.phase, BalancedPhase.grace);

        channels.single.control.add(
          RoomMetaUpdated(peer: _peer.remoteEpk, roomId: 'b', model: 'new'),
        );
        async.flushMicrotasks();
        expect(controller.graceEndsAt, isNot(initialDeadline));
        final graceDeadline = controller.graceEndsAt;
        channels.single.control.add(
          RoomMetaUpdated(peer: _peer.remoteEpk, roomId: 'b', model: 'newer'),
        );
        async.flushMicrotasks();
        expect(
          controller.graceEndsAt,
          graceDeadline,
          reason: 'routine metadata must not extend grace',
        );

        channels.single.control.add(_room('b', true));
        async.flushMicrotasks();
        expect(controller.phase, BalancedPhase.active);
        channels.single.control.add(_room('b', false));
        async.flushMicrotasks();
        expect(controller.phase, BalancedPhase.grace);

        now = now.add(const Duration(minutes: 5));
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(controller.phase, BalancedPhase.sleeping);
        expect(cm.status, isA<StatusSleeping>());
        expect(keepAlive.balancedValues.last, isFalse);
        expect(channels.length, 1);

        controller.noteRunFinished();
        async.flushMicrotasks();
        expect(channels.length, 1, reason: 'completion alone must not wake');
        controller.wakeForWaiting();
        async.flushMicrotasks();
        expect(channels.length, 2);
        expect(controller.phase, BalancedPhase.grace);
        expect(cm.status, isA<StatusOnline>());

        controller.setBackgrounded(false);
        now = now.add(const Duration(minutes: 5));
        async.elapse(const Duration(minutes: 5));
        expect(controller.phase, BalancedPhase.foreground);
        expect(cm.status, isA<StatusOnline>());

        controller.dispose();
        keepAlive.dispose();
        cm.dispose();
      });
    },
  );

  test('leaving Balanced restores a legacy connection', () {
    fakeAsync((async) {
      var now = DateTime.utc(2026, 1, 1);
      final prefs = _Prefs(KeepAliveMode.balanced);
      final keepAlive = _KeepAlive(prefs);
      var calls = 0;
      final cm = ConnectionManager(
        factory: (_, _) async {
          calls++;
          return _Channel();
        },
        storage: _Storage(),
        emitDebounce: Duration.zero,
      );
      cm.boot();
      async.flushMicrotasks();
      final controller = BalancedConnectionController(
        prefs,
        cm,
        keepAlive,
        now: () => now,
      )..attach();
      controller.setBackgrounded(true);
      now = now.add(const Duration(minutes: 5));
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
      expect(cm.status, isA<StatusSleeping>());
      expect(calls, 1);

      prefs.setMode(KeepAliveMode.always);
      async.flushMicrotasks();
      expect(controller.phase, BalancedPhase.inactive);
      expect(calls, 2);
      expect(cm.status, isA<StatusOnline>());

      controller.dispose();
      keepAlive.dispose();
      cm.dispose();
    });
  });

  test('FGS timeout suspends socket instead of leaking retries', () {
    fakeAsync((async) {
      final prefs = _Prefs(KeepAliveMode.balanced);
      final keepAlive = _KeepAlive(prefs);
      var calls = 0;
      final cm = ConnectionManager(
        factory: (_, _) async {
          calls++;
          return _Channel();
        },
        storage: _Storage(),
        emitDebounce: Duration.zero,
      );
      cm.boot();
      async.flushMicrotasks();
      final controller = BalancedConnectionController(prefs, cm, keepAlive)
        ..attach();
      controller.setBackgrounded(true);
      controller.handleForegroundServiceTimeout();
      async.flushMicrotasks();
      expect(cm.status, isA<StatusSleeping>());
      async.elapse(const Duration(minutes: 10));
      expect(calls, 1);

      controller.setBackgrounded(false);
      async.flushMicrotasks();
      expect(calls, 2);
      expect(cm.status, isA<StatusOnline>());
      controller.dispose();
      keepAlive.dispose();
      cm.dispose();
    });
  });

  test('active run does not enter grace or sleep during a long reconnect', () {
    fakeAsync((async) {
      var now = DateTime.utc(2026, 1, 1);
      final prefs = _Prefs(KeepAliveMode.balanced);
      final keepAlive = _KeepAlive(prefs);
      var failReconnect = false;
      final channels = <_Channel>[];
      final cm = ConnectionManager(
        factory: (_, _) async {
          if (failReconnect) throw StateError('tunnel down');
          final channel = _Channel();
          channels.add(channel);
          return channel;
        },
        storage: _Storage(),
        emitDebounce: Duration.zero,
      );
      cm.boot();
      async.flushMicrotasks();
      final controller = BalancedConnectionController(
        prefs,
        cm,
        keepAlive,
        now: () => now,
      )..attach();
      controller.setBackgrounded(true);
      channels.single.control.add(_room('a', true));
      async.flushMicrotasks();
      expect(controller.phase, BalancedPhase.active);

      failReconnect = true;
      channels.single.close();
      async.flushMicrotasks();
      expect(cm.status, isA<StatusRetrying>());
      now = now.add(const Duration(minutes: 10));
      async.elapse(const Duration(minutes: 10));
      async.flushMicrotasks();
      expect(controller.phase, BalancedPhase.active);
      expect(cm.status, isA<StatusRetrying>());
      expect(keepAlive.balancedValues.last, isTrue);

      failReconnect = false;
      cm.onForeground();
      async.flushMicrotasks();
      expect(cm.status, isA<StatusOnline>());
      expect(controller.phase, BalancedPhase.active);
      controller.dispose();
      keepAlive.dispose();
      cm.dispose();
    });
  });
}
