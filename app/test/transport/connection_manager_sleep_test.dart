import 'dart:async';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/network_monitor.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _peer = PeerRecord(
  remoteEpk: 'epk_test',
  sessionName: 'test',
  relayUrl: 'ws://localhost:8080',
  pairedAt: '2026-01-01T00:00:00Z',
  roomId: 'main',
);

class _Storage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [_peer];
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => const [];
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {}
}

class _Channel implements IChannel, IControlLink {
  final _server = StreamController<ServerMessage>.broadcast();
  final _control = StreamController<ControlInbound>.broadcast();
  final controls = <Map<String, dynamic>>[];
  final messages = <ClientMessage>[];
  bool closed = false;

  @override
  Stream<ServerMessage> get serverMessages => _server.stream;
  @override
  Stream<ControlInbound> get controlFrames => _control.stream;
  @override
  void sendControl(Map<String, dynamic> json) => controls.add(json);
  @override
  Future<void> send(ClientMessage msg) async => messages.add(msg);
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _server.close();
    await _control.close();
  }
}

void main() {
  test(
    'sleep cancels every reconnect path and foreground replays subscriptions',
    () {
      fakeAsync((async) {
        var calls = 0;
        final channels = <_Channel>[];
        final cm = ConnectionManager(
          factory: (_, _) async {
            calls++;
            final channel = _Channel();
            channels.add(channel);
            return channel;
          },
          storage: _Storage(),
          watchdogInterval: const Duration(milliseconds: 20),
          recheckInterval: const Duration(milliseconds: 20),
          emitDebounce: Duration.zero,
        );
        cm.boot();
        async.flushMicrotasks();
        expect(cm.status, isA<StatusOnline>());
        expect(calls, 1);
        channels.single.controls.clear();

        cm.suspendForBalancedSleep();
        async.flushMicrotasks();
        expect(cm.status, isA<StatusSleeping>());
        expect(channels.single.closed, isTrue);
        expect(cm.activePeer, isNotNull);

        final monitor = NetworkMonitor(
          connectivityStream: const Stream.empty(),
        );
        monitor.attach(cm);
        monitor.handle(const [ConnectivityResult.wifi]);
        async.elapse(const Duration(minutes: 10));
        async.flushMicrotasks();
        expect(calls, 1, reason: 'watchdog/network/retry must stay asleep');
        expect(channels.single.controls, isEmpty);
        expect(channels.single.messages, isEmpty);

        cm.onForeground();
        async.flushMicrotasks();
        expect(calls, 2);
        expect(cm.status, isA<StatusOnline>());
        final replay = channels.last.controls.map((f) => f['type']);
        expect(replay, contains('subscribe_presence'));
        expect(replay, contains('subscribe_rooms'));
        expect(replay, contains('presence_check'));
        expect(replay, contains('rooms_check'));

        monitor.dispose();
        cm.dispose();
      });
    },
  );

  test(
    'sleep cancels an already scheduled retry and resets backoff on wake',
    () {
      fakeAsync((async) {
        var calls = 0;
        final cm = ConnectionManager(
          factory: (_, _) async {
            calls++;
            if (calls == 1) throw StateError('offline');
            return _Channel();
          },
          storage: _Storage(),
          emitDebounce: Duration.zero,
        );
        cm.boot();
        async.flushMicrotasks();
        expect(cm.status, isA<StatusRetrying>());

        cm.suspendForBalancedSleep();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5));
        expect(calls, 1);
        expect(cm.status, isA<StatusSleeping>());

        cm.onForeground();
        async.flushMicrotasks();
        expect(calls, 2);
        expect(cm.status, isA<StatusOnline>());
        cm.dispose();
      });
    },
  );

  test('pending connect is cancelled and its late channel is closed', () {
    fakeAsync((async) {
      final pending = Completer<_Channel>();
      var calls = 0;
      late _Channel lateChannel;
      final cm = ConnectionManager(
        factory: (_, _) {
          calls++;
          if (calls == 1) return pending.future;
          return Future.value(_Channel());
        },
        storage: _Storage(),
        emitDebounce: Duration.zero,
      );
      cm.boot();
      async.flushMicrotasks();
      expect(cm.status, isA<StatusConnecting>());

      cm.suspendForBalancedSleep();
      async.flushMicrotasks();
      lateChannel = _Channel();
      pending.complete(lateChannel);
      async.flushMicrotasks();
      expect(lateChannel.closed, isTrue);
      expect(cm.status, isA<StatusSleeping>());

      cm.onForeground();
      async.flushMicrotasks();
      expect(calls, 2);
      expect(cm.status, isA<StatusOnline>());
      cm.dispose();
    });
  });

  test('background preparation restores peer without dialing', () async {
    var calls = 0;
    final cm = ConnectionManager(
      factory: (_, _) async {
        calls++;
        return _Channel();
      },
      storage: _Storage(),
      emitDebounce: Duration.zero,
    );
    await cm.prepareForBackgroundSleep(preferredEpk: _peer.remoteEpk);
    expect(calls, 0);
    expect(cm.status, isA<StatusSleeping>());
    expect(cm.activePeer?.remoteEpk, _peer.remoteEpk);
    expect(cm.activeRoomId, 'main');
    cm.dispose();
  });
}
