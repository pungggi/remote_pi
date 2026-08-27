import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/notifications/session_completion_notifications.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStorage extends PairingStorage {
  List<PeerRecord> peers;
  _FakeStorage(this.peers);

  @override
  Future<List<PeerRecord>> listPeers() async => List.of(peers);

  @override
  Future<void> savePeer(PeerRecord r) async {
    peers = [r, ...peers.where((p) => p.remoteEpk != r.remoteEpk)];
  }

  @override
  Future<void> deletePeer(String epk) async {
    peers = peers.where((p) => p.remoteEpk != epk).toList();
  }

  // Rooms persistence is exercised when a RoomAnnounced lands on a real
  // ConnectionManager (_persistRoomsForPeer). Keep it in-memory so the
  // test never touches flutter_secure_storage (no binding in unit tests).
  final Map<String, List<PersistedRoom>> _rooms = {};
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {
    _rooms[epk] = rooms;
  }

  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async =>
      _rooms[epk] ?? const [];

  @override
  Future<void> deleteRooms(String epk) async {
    _rooms.remove(epk);
  }
}

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

const _peerA = PeerRecord(
  remoteEpk: 'epk_A',
  sessionName: 'Pi A',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);
const _peerB = PeerRecord(
  remoteEpk: 'epk_B',
  sessionName: 'Pi B',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-02T00:00:00Z',
);

class _NoopTransport implements PeerTransport {
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<Uint8List> receive() => Completer<Uint8List>().future;
  @override
  Future<void> close() async {}
}

PlainPeerChannel _channel() => PlainPeerChannel(transport: _NoopTransport());

/// Lets a test inject relay control frames (presence / rooms / working)
/// into a real ConnectionManager.
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

/// Plan/107b — HomeViewModel now needs an IActionsRepository to fetch git
/// status. Most tests don't exercise git, so stub only `gitStatus()`
/// (returns null = "not a repo") and noSuchMethod the rest.
class _FakeActions implements IActionsRepository {
  @override
  Future<GitStatus?> gitStatus() async => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

_FakeActions _fakeActions() => _FakeActions();

/// Plan/132 — in-memory stub of the completion-notification controls (no
/// Hive, no plugin; records toggles so tests can assert them if needed).
class _StubCompletionNotifications extends ICompletionNotifications {
  final Map<String, bool> toggles = {};
  bool permissionGranted = true;

  @override
  bool isEnabled(String epk, String roomId) =>
      toggles['$epk:$roomId'] == true;

  @override
  Future<bool> setEnabled(String epk, String roomId, bool value) async {
    toggles['$epk:$roomId'] = value;
    // Enabling surfaces the permission state; disabling always succeeds.
    return value ? permissionGranted : true;
  }
}

_StubCompletionNotifications _stubCompletion() =>
    _StubCompletionNotifications();

/// Plan/108 — records `openTerminal` calls so the session-list routing
/// test can assert the tapped (cwd, branch) reached the repo. Everything
/// else is noSuchMethod'd — these tests never exercise the wire.
class _OpenCall {
  final String? cwd;
  final bool runPi;
  final String? branch;
  _OpenCall({this.cwd, required this.runPi, this.branch});
}

class _RecordingActions implements IActionsRepository {
  final List<_OpenCall> openCalls = [];
  final List<_StartCall> startCalls = [];
  OpenTerminalResult nextResult = OpenTerminalResult(
    inReplyTo: 'x',
    ok: true,
    message: 'opened',
    method: OpenTerminalMethod.wt,
  );
  StartSessionResult nextStartResult = StartSessionResult(
    inReplyTo: 'x',
    ok: true,
    roomId: 'device-room',
    message: '',
  );
  @override
  Future<GitStatus?> gitStatus() async => null;
  @override
  Future<OpenTerminalResult> openTerminal({
    String? cwd,
    bool runPi = true,
    String? worktreePath,
    String? branch,
  }) async {
    openCalls.add(_OpenCall(cwd: cwd, runPi: runPi, branch: branch));
    return nextResult;
  }
  @override
  Future<StartSessionResult> startSession({
    required String cwd,
    String? name,
  }) async {
    startCalls.add(_StartCall(cwd: cwd, name: name));
    return nextStartResult;
  }
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StartCall {
  final String cwd;
  final String? name;
  _StartCall({required this.cwd, this.name});
}

ConnectionManager _conn({_FakeStorage? storage}) {
  return ConnectionManager(
    factory: (_, _) async => _channel(),
    storage: storage ?? _FakeStorage([]),
  );
}

void main() {
  group('HomeViewModel', () {
    test(
      'isRoomWorking follows the relay meta.working broadcast for ANY room — '
      'including one that is NOT the connected session, and clears when the '
      'relay says the turn ended (plan/32)',
      () async {
        // Reproduces the smoke-test bugs in sequence:
        //  1) the dot only lit for the active chat (working came from the
        //     connected peer's message channel), and
        //  2) a session that FINISHED while the app was on another chat
        //     stayed blue forever (the DB session index never got idled).
        // Home now reads ONLY ConnectionManager.isRoomWorking — the relay's
        // per-room broadcast — which has no such blind spot.
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peerA]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        final prefs = Preferences(_FakeSecureStorage());
        final vm = HomeViewModel(storage, prefs, conn, _fakeActions(), _stubCompletion());
        await conn.connectTo(_peerA);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // Room comes online idle.
        ch.pushControl(
          const RoomAnnounced(peer: 'epk_A', roomId: 'r1', startedAt: 1),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(vm.isRoomWorking('epk_A', 'r1'), isFalse);

        // turn_start → relay broadcasts meta.working=true.
        ch.pushControl(
          const RoomMetaUpdated(
            peer: 'epk_A',
            roomId: 'r1',
            working: true,
            hasModel: false,
            hasThinking: false,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(vm.isRoomWorking('epk_A', 'r1'), isTrue);

        // turn_end → meta.working=false → dot goes back off (this is the
        // case that previously stayed blue forever).
        ch.pushControl(
          const RoomMetaUpdated(
            peer: 'epk_A',
            roomId: 'r1',
            working: false,
            hasModel: false,
            hasThinking: false,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(vm.isRoomWorking('epk_A', 'r1'), isFalse);

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );

    test('initial state is HomeLoading', () {
      final storage = _FakeStorage([_peerA]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, _conn(storage: storage), _fakeActions(), _stubCompletion());
      expect(vm.state, isA<HomeLoading>());
      vm.dispose();
    });

    test('empty storage → HomeNoPeer', () async {
      final storage = _FakeStorage([]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, _conn(storage: storage), _fakeActions(), _stubCompletion());
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, isA<HomeNoPeer>());
      vm.dispose();
    });

    test('two peers → HomeList containing both', () async {
      final storage = _FakeStorage([_peerA, _peerB]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, _conn(storage: storage), _fakeActions(), _stubCompletion());
      await Future<void>.delayed(Duration.zero);

      final s = vm.state as HomeList;
      expect(s.peers.map((p) => p.remoteEpk), ['epk_A', 'epk_B']);

      vm.dispose();
    });

    test('openSession writes selectedPeerEpk to Preferences', () async {
      final storage = _FakeStorage([_peerA, _peerB]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, _conn(storage: storage), _fakeActions(), _stubCompletion());
      await Future<void>.delayed(Duration.zero);

      await vm.openSession('epk_B');
      expect(prefs.selectedPeerEpk, 'epk_B');

      vm.dispose();
    });

    test(
      'plano app-state-normalization: openSession ONLY sets prefs '
      '(no switchTo from Home — boot races would otherwise happen)',
      () async {
        final storage = _FakeStorage([_peerA, _peerB]);
        final prefs = Preferences(_FakeSecureStorage());
        final connects = <String>[];
        final conn = ConnectionManager(
          factory: (peer, _) async {
            connects.add(peer.remoteEpk);
            return _channel();
          },
          storage: storage,
        );
        final vm = HomeViewModel(storage, prefs, conn, _fakeActions(), _stubCompletion());
        await Future<void>.delayed(Duration.zero);

        await vm.openSession('epk_B');
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(prefs.selectedPeerEpk, 'epk_B');
        expect(
          connects,
          isEmpty,
          reason:
              'Home must NOT call the connection factory — chat owns '
              'the switchTo decision',
        );
        expect(conn.activePeer, isNull);

        vm.dispose();
        conn.dispose();
      },
    );

    test('openSession with unknown epk is a no-op', () async {
      final storage = _FakeStorage([_peerA]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, _conn(storage: storage), _fakeActions(), _stubCompletion());
      await Future<void>.delayed(Duration.zero);

      await vm.openSession('epk_unknown');
      expect(prefs.selectedPeerEpk, isNull);

      vm.dispose();
    });

    test(
      'openSession with roomId persists the composite epk:room AND '
      'awaits before returning — caller can rely on Preferences being '
      'updated before navigating to /chat (race-condition regression)',
      () async {
        final storage = _FakeStorage([_peerA]);
        final prefs = Preferences(_FakeSecureStorage());
        final vm = HomeViewModel(storage, prefs, _conn(storage: storage), _fakeActions(), _stubCompletion());
        await Future<void>.delayed(Duration.zero);

        // Seed prefs with a DIFFERENT room (simulating the previous
        // chat the user was looking at).
        await prefs.setSelectedRoom(epk: 'epk_A', roomId: 'room-previous');
        expect(prefs.selectedRoomId, 'room-previous');

        // Now tap a new room → openSession completes, prefs reflect it.
        await vm.openSession('epk_A', roomId: 'room-target');

        // After awaiting openSession, prefs ARE updated. If
        // ChatViewModel.bootstrap reads prefs at this point, it sees
        // the correct room.
        expect(prefs.selectedPeerEpk, 'epk_A');
        expect(prefs.selectedRoomId, 'room-target');

        vm.dispose();
      },
    );
  });

  group('HomeViewModel — presence filter (plan-38 Fase 3)', () {
    test('counts / visibleItems split rooms by liveness; setFilter re-derives '
        'without reloading', () async {
      final ch = _ControllableChannel();
      final storage = _FakeStorage([_peerA]);
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, conn, _fakeActions(), _stubCompletion());
      await conn.connectTo(_peerA);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // r1 stays live; r2 is announced then ended → cached but offline
      // (grey tile — still in _roomsByPeer, dropped from _liveRoomIds).
      ch.pushControl(
        const RoomAnnounced(peer: 'epk_A', roomId: 'r1', startedAt: 1),
      );
      ch.pushControl(
        const RoomAnnounced(peer: 'epk_A', roomId: 'r2', startedAt: 2),
      );
      ch.pushControl(const RoomEnded(peer: 'epk_A', roomId: 'r2', sinceTs: 3));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Sanity — one live, one cached/offline.
      expect(vm.isRoomLive('epk_A', 'r1'), isTrue);
      expect(vm.isRoomLive('epk_A', 'r2'), isFalse);

      // Counts are independent of the selected tab.
      expect(vm.counts, (all: 2, online: 1, offline: 1));

      // Default tab is Online → only the live room is visible.
      expect((vm.state as HomeList).filter, HomeFilter.online);
      expect(vm.visibleItems.map((i) => i.room.roomId).toList(), ['r1']);

      // Offline → only the cached room.
      vm.setFilter(HomeFilter.offline);
      expect((vm.state as HomeList).filter, HomeFilter.offline);
      expect(vm.visibleItems.map((i) => i.room.roomId).toList(), ['r2']);

      // All → both (sorted), and the counts are unchanged.
      vm.setFilter(HomeFilter.all);
      expect(vm.visibleItems.map((i) => i.room.roomId).toList(), ['r1', 'r2']);
      expect(vm.counts, (all: 2, online: 1, offline: 1));

      vm.dispose();
      await conn.disconnect();
      conn.dispose();
    });

    test(
      'setFilter is a no-op when the tab is unchanged, and emits exactly once '
      'when it changes',
      () async {
        final storage = _FakeStorage([_peerA]);
        final prefs = Preferences(_FakeSecureStorage());
        final vm = HomeViewModel(storage, prefs, _conn(storage: storage), _fakeActions(), _stubCompletion());
        await Future<void>.delayed(Duration.zero);

        expect((vm.state as HomeList).filter, HomeFilter.online);
        var notifies = 0;
        vm.addListener(() => notifies++);

        vm.setFilter(HomeFilter.online); // same tab → no emit
        expect(notifies, 0);

        vm.setFilter(HomeFilter.offline); // changed → one emit
        expect(notifies, 1);
        expect((vm.state as HomeList).filter, HomeFilter.offline);

        vm.dispose();
      },
    );

    test('counts / visibleItems are empty-safe outside a HomeList', () {
      final storage = _FakeStorage([_peerA]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, _conn(storage: storage), _fakeActions(), _stubCompletion());

      // Synchronously still HomeLoading — the getters must not throw.
      expect(vm.state, isA<HomeLoading>());
      expect(vm.counts, (all: 0, online: 0, offline: 0));
      expect(vm.visibleItems, isEmpty);

      vm.dispose();
    });

    test(
      'plan/120 — the device room is filtered from the Home list '
      '(never appears in any tab)',
      () async {
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peerA]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        final prefs = Preferences(_FakeSecureStorage());
        final vm = HomeViewModel(storage, prefs, conn, _fakeActions(), _stubCompletion());
        await conn.connectTo(_peerA);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // Push a regular room + the device room.
        ch.pushControl(
          const RoomAnnounced(peer: 'epk_A', roomId: 'r1', startedAt: 1),
        );
        ch.pushControl(
          const RoomAnnounced(peer: 'epk_A', roomId: 'device', startedAt: 2),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // The device room must NOT appear in any filter.
        for (final f in HomeFilter.values) {
          vm.setFilter(f);
          final ids = vm.visibleItems.map((i) => i.room.roomId).toList();
          expect(ids, isNot(contains('device')));
        }

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );
  });

  group('HomeViewModel.openTerminal (plan/108 — session-list entry)', () {
    test(
      'routes to the tapped peer when it is NOT active: switchTo + '
      'openTerminal with the room cwd/branch',
      () async {
        final storage = _FakeStorage([_peerA, _peerB]);
        final connects = <String>[];
        final conn = ConnectionManager(
          factory: (peer, _) async {
            connects.add(peer.remoteEpk);
            return _channel();
          },
          storage: storage,
        );
        final prefs = Preferences(_FakeSecureStorage());
        final actions = _RecordingActions();
        final vm = HomeViewModel(storage, prefs, conn, actions, _stubCompletion());
        // Seed the active peer as A so the call below has to switch.
        await conn.connectTo(_peerA);
        await Future<void>.delayed(Duration.zero);
        expect(conn.activePeer?.remoteEpk, 'epk_A');

        final r = await vm.openTerminal(
          epk: 'epk_B',
          roomId: 'r1',
          cwd: '/home/me/proj',
          branch: 'feat',
        );

        // switchTo B landed on the connection (factory saw B after A).
        expect(connects, ['epk_A', 'epk_B']);
        expect(conn.activePeer?.remoteEpk, 'epk_B');
        // The tapped cwd + branch reached the action repo, verbatim.
        expect(actions.openCalls.length, 1);
        expect(actions.openCalls.single.cwd, '/home/me/proj');
        expect(actions.openCalls.single.branch, 'feat');
        expect(actions.openCalls.single.runPi, isTrue);
        expect(r.ok, isTrue);

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );

    test('does NOT switchTo when the tapped peer is already active', () async {
      final storage = _FakeStorage([_peerA]);
      final connects = <String>[];
      final conn = ConnectionManager(
        factory: (peer, _) async {
          connects.add(peer.remoteEpk);
          return _channel();
        },
        storage: storage,
      );
      final prefs = Preferences(_FakeSecureStorage());
      final actions = _RecordingActions();
      final vm = HomeViewModel(storage, prefs, conn, actions, _stubCompletion());
      await conn.connectTo(_peerA);
      // Let StatusOnline propagate to the VM's _relayConnected before we
      // act — the gate below is (samePeer && online).
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await vm.openTerminal(epk: 'epk_A', roomId: 'r1', branch: 'b');

      // Same peer AND online → switchTo's no-op path: only the seed
      // connect happened.
      expect(connects, ['epk_A']);
      expect(actions.openCalls.single.branch, 'b');

      vm.dispose();
      await conn.disconnect();
      conn.dispose();
    });

    test(
      'still switchTo (reconnect) when the active peer matches but the '
      'link is offline (review #3)',
      () async {
        final storage = _FakeStorage([_peerA]);
        final connects = <String>[];
        // First call (connectTo) fails → seeds activePeer=A but _relayConnected
        // stays false. Second call (switchTo from openTerminal) succeeds so
        // _waitForOnline resolves immediately.
        var attempt = 0;
        final conn = ConnectionManager(
          factory: (peer, _) async {
            connects.add(peer.remoteEpk);
            attempt++;
            if (attempt == 1) throw Exception('offline');
            return _channel();
          },
          storage: storage,
        );
        final prefs = Preferences(_FakeSecureStorage());
        final actions = _RecordingActions();
        final vm = HomeViewModel(storage, prefs, conn, actions, _stubCompletion());
        await conn.connectTo(_peerA);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(conn.activePeer?.remoteEpk, 'epk_A');

        await vm.openTerminal(epk: 'epk_A', roomId: 'r1', branch: 'b');

        // The old epk-only check skipped switchTo here and dispatched into
        // a dead channel. Now we switchTo (reconnect): a second factory
        // call beyond the seed.
        expect(connects.length, greaterThanOrEqualTo(2));
        expect(actions.openCalls.single.branch, 'b');

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );

    test('unknown peer throws ActionFailure and dispatches nothing', () async {
      final storage = _FakeStorage([_peerA]);
      final conn = ConnectionManager(
        factory: (_, _) async => _channel(),
        storage: storage,
      );
      final prefs = Preferences(_FakeSecureStorage());
      final actions = _RecordingActions();
      final vm = HomeViewModel(storage, prefs, conn, actions, _stubCompletion());
      await conn.connectTo(_peerA);
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        vm.openTerminal(epk: 'epk_X', roomId: 'r1', branch: 'b'),
        throwsA(isA<ActionFailure>()),
      );
      expect(actions.openCalls, isEmpty);

      vm.dispose();
      await conn.disconnect();
      conn.dispose();
    });
  });

  group('HomeViewModel.startSession (plan/124 — bring session to life)', () {
    test(
      'routes to the device room and dispatches startSession with cwd + name',
      () async {
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peerA]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        final prefs = Preferences(_FakeSecureStorage());
        final actions = _RecordingActions();
        final vm = HomeViewModel(storage, prefs, conn, actions, _stubCompletion());
        await conn.connectTo(_peerA);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // The target session room (r1) stays offline — that's the whole
        // point of revive. Make the supervisor's device room live so the
        // dispatch proceeds.
        ch.pushControl(
          const RoomAnnounced(peer: 'epk_A', roomId: kDeviceRoom, startedAt: 1),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(vm.isRoomLive('epk_A', kDeviceRoom), isTrue);

        final r = await vm.startSession(
          epk: 'epk_A',
          cwd: '/home/me/proj',
          name: 'worker',
        );

        expect(r.ok, isTrue);
        // The tapped cwd + name reached the action repo verbatim.
        expect(actions.startCalls.single.cwd, '/home/me/proj');
        expect(actions.startCalls.single.name, 'worker');
        // The connection was routed to the device room for the dispatch
        // (revive always rides the device daemon, never the offline room).
        expect(conn.activeRoomId, kDeviceRoom);
        // No terminal/worktree was spawned — this is a pure session revive.
        expect(actions.openCalls, isEmpty);

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );

    test(
      'throws ActionFailure when the device room is not live (no supervisor)',
      () async {
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peerA]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        final prefs = Preferences(_FakeSecureStorage());
        final actions = _RecordingActions();
        final vm = HomeViewModel(storage, prefs, conn, actions, _stubCompletion());
        await conn.connectTo(_peerA);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        // Device room never announced → not live → fail fast with an
        // actionable error instead of waiting out the dispatch timeout.
        expect(vm.isRoomLive('epk_A', kDeviceRoom), isFalse);

        await expectLater(
          vm.startSession(epk: 'epk_A', cwd: '/home/me/proj'),
          throwsA(isA<ActionFailure>()),
        );
        expect(actions.startCalls, isEmpty);

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );

    test('unknown peer throws ActionFailure and dispatches nothing', () async {
      final storage = _FakeStorage([_peerA]);
      final conn = ConnectionManager(
        factory: (_, _) async => _channel(),
        storage: storage,
      );
      final prefs = Preferences(_FakeSecureStorage());
      final actions = _RecordingActions();
      final vm = HomeViewModel(storage, prefs, conn, actions, _stubCompletion());
      await conn.connectTo(_peerA);
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        vm.startSession(epk: 'epk_X', cwd: '/home/me/proj'),
        throwsA(isA<ActionFailure>()),
      );
      expect(actions.startCalls, isEmpty);

      vm.dispose();
      await conn.disconnect();
      conn.dispose();
    });
  });
}
