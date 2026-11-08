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
  bool isEnabled(String epk, String roomId) => toggles['$epk:$roomId'] == true;

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

  // Plan/148 — worktree registry + remove bookkeeping.
  List<WireWorktree> worktrees = const [];
  final List<String> removedIds = [];
  RemoveWorktreeResult nextRemoveResult = RemoveWorktreeResult(
    inReplyTo: 'x',
    ok: true,
    message: 'removed',
  );

  @override
  Future<List<WireWorktree>> listWorktrees({String? base}) async => base == null
      ? worktrees
      : worktrees.where((w) => w.base == base).toList();

  @override
  Future<RemoveWorktreeResult> removeWorktree(String worktreeId) async {
    removedIds.add(worktreeId);
    return nextRemoveResult;
  }

  // Plan/158 — forget_room bookkeeping (the PC-side registry prune).
  final List<({String roomId, bool deleteHistory})> forgetCalls = [];
  ForgetRoomResult nextForgetResult = ForgetRoomResult(
    inReplyTo: 'x',
    ok: true,
    message: 'The computer forgot this session.',
    registryRemoved: true,
  );

  @override
  Future<ForgetRoomResult> forgetRoom(
    String roomId, {
    bool deleteHistory = false,
  }) async {
    forgetCalls.add((roomId: roomId, deleteHistory: deleteHistory));
    return nextForgetResult;
  }

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

  // Plan/149 (PR #71 review) — session-ref link routing recorder.
  final List<({String roomId, GhRef? ghRef, String? cwd})> setSessionRefCalls =
      [];
  SetSessionRefResult nextSetRefResult = SetSessionRefResult(
    inReplyTo: 'x',
    ok: true,
    message: '',
  );

  @override
  Future<SetSessionRefResult> setSessionRef({
    required String roomId,
    required GhRef? ghRef,
    String? cwd,
  }) async {
    setSessionRefCalls.add((roomId: roomId, ghRef: ghRef, cwd: cwd));
    return nextSetRefResult;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StartCall {
  final String cwd;
  final String? name;
  _StartCall({required this.cwd, this.name});
}

// ---- Plan/148 — offline worktree cleanup harness ---------------------------

/// The folder Piper created for this session (a tracked worktree path).
const _kWorktreeCwd = '/src/remote_pi_w1';
const _kWorktree = WireWorktree(
  id: 'w1',
  base: '/src/remote_pi',
  path: _kWorktreeCwd,
  branch: 'work/w1',
  createdAt: '2026-10-23T10:00:00Z',
);

class _CleanupHarness {
  final _ControllableChannel ch;
  final _FakeStorage storage;
  final ConnectionManager conn;
  final Preferences prefs;
  final _RecordingActions actions;
  final HomeViewModel vm;

  _CleanupHarness({
    required this.ch,
    required this.storage,
    required this.conn,
    required this.prefs,
    required this.actions,
    required this.vm,
  });

  HomeItem item(String roomId) => (vm.state as HomeList)
      .items(normalizeEpk: HomeViewModel.normalizeEpkForLookup)
      .firstWhere((i) => i.room.roomId == roomId);

  bool hasRoom(String roomId) => (vm.state as HomeList)
      .items(normalizeEpk: HomeViewModel.normalizeEpkForLookup)
      .any((i) => i.room.roomId == roomId);

  Future<void> dispose() async {
    vm.dispose();
    await conn.disconnect();
    conn.dispose();
  }
}

/// An extra room to seed into the harness (duplicates, nested cwds,
/// cross-peer rooms). Always seeded live and non-keeper.
class _SeedRoom {
  final String peer;
  final String roomId;
  final String? cwd;
  const _SeedRoom(this.peer, {required this.roomId, this.cwd});
}

/// Builds a Home with one session room `r1` in a tracked worktree, plus the
/// supervisor's device room (the only room that answers once `r1` is dead).
Future<_CleanupHarness> _cleanupHarness({
  bool roomOffline = true,
  bool keeper = false,
  String roomCwd = _kWorktreeCwd,
  List<WireWorktree> worktrees = const [_kWorktree],
  List<_SeedRoom> extraRooms = const [],
  bool withPeerB = false,
  bool deviceLive = true,
}) async {
  final ch = _ControllableChannel();
  final storage = _FakeStorage(withPeerB ? [_peerA, _peerB] : [_peerA]);
  final conn = ConnectionManager(
    factory: (_, _) async => ch,
    storage: storage,
    emitDebounce: Duration.zero,
  );
  final prefs = Preferences(_FakeSecureStorage());
  final actions = _RecordingActions()..worktrees = worktrees;
  final vm = HomeViewModel(storage, prefs, conn, actions, _stubCompletion());
  await conn.connectTo(_peerA);
  await Future<void>.delayed(const Duration(milliseconds: 10));

  var ts = 1;
  if (deviceLive) {
    ch.pushControl(
      RoomAnnounced(peer: 'epk_A', roomId: kDeviceRoom, startedAt: ts++),
    );
  }
  ch.pushControl(
    RoomAnnounced(
      peer: 'epk_A',
      roomId: 'r1',
      startedAt: ts++,
      cwd: roomCwd,
      keeper: keeper,
    ),
  );
  for (final r in extraRooms) {
    ch.pushControl(
      RoomAnnounced(
        peer: r.peer,
        roomId: r.roomId,
        startedAt: ts++,
        cwd: r.cwd,
      ),
    );
  }
  if (roomOffline) {
    ch.pushControl(RoomEnded(peer: 'epk_A', roomId: 'r1', sinceTs: ts++));
  }
  await Future<void>.delayed(const Duration(milliseconds: 10));

  return _CleanupHarness(
    ch: ch,
    storage: storage,
    conn: conn,
    prefs: prefs,
    actions: actions,
    vm: vm,
  );
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
        final vm = HomeViewModel(
          storage,
          prefs,
          conn,
          _fakeActions(),
          _stubCompletion(),
        );
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
      final vm = HomeViewModel(
        storage,
        prefs,
        _conn(storage: storage),
        _fakeActions(),
        _stubCompletion(),
      );
      expect(vm.state, isA<HomeLoading>());
      vm.dispose();
    });

    test('empty storage → HomeNoPeer', () async {
      final storage = _FakeStorage([]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(
        storage,
        prefs,
        _conn(storage: storage),
        _fakeActions(),
        _stubCompletion(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, isA<HomeNoPeer>());
      vm.dispose();
    });

    test('two peers → HomeList containing both', () async {
      final storage = _FakeStorage([_peerA, _peerB]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(
        storage,
        prefs,
        _conn(storage: storage),
        _fakeActions(),
        _stubCompletion(),
      );
      await Future<void>.delayed(Duration.zero);

      final s = vm.state as HomeList;
      expect(s.peers.map((p) => p.remoteEpk), ['epk_A', 'epk_B']);

      vm.dispose();
    });

    test('openSession writes selectedPeerEpk to Preferences', () async {
      final storage = _FakeStorage([_peerA, _peerB]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(
        storage,
        prefs,
        _conn(storage: storage),
        _fakeActions(),
        _stubCompletion(),
      );
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
        final vm = HomeViewModel(
          storage,
          prefs,
          conn,
          _fakeActions(),
          _stubCompletion(),
        );
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
      final vm = HomeViewModel(
        storage,
        prefs,
        _conn(storage: storage),
        _fakeActions(),
        _stubCompletion(),
      );
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
        final vm = HomeViewModel(
          storage,
          prefs,
          _conn(storage: storage),
          _fakeActions(),
          _stubCompletion(),
        );
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

  group('HomeViewModel — combined session list', () {
    test(
      'visibleItems includes live + cached rooms, keeper mirrors last',
      () async {
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peerA]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        final prefs = Preferences(_FakeSecureStorage());
        final vm = HomeViewModel(
          storage,
          prefs,
          conn,
          _fakeActions(),
          _stubCompletion(),
        );
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
        ch.pushControl(
          const RoomEnded(peer: 'epk_A', roomId: 'r2', sinceTs: 3),
        );
        ch.pushControl(
          const RoomAnnounced(
            peer: 'epk_A',
            roomId: 'r0',
            startedAt: 4,
            keeper: true,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // Sanity — one live, one cached/offline.
        expect(vm.isRoomLive('epk_A', 'r1'), isTrue);
        expect(vm.isRoomLive('epk_A', 'r2'), isFalse);

        // No presence filter: live and cached rooms share one list, with
        // keeper mirrors after every real session.
        expect(vm.isRoomLive('epk_A', 'r0'), isTrue);
        expect(vm.visibleItems.map((i) => i.room.roomId).toList(), [
          'r1',
          'r2',
          'r0',
        ]);

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );

    test('visibleItems is empty-safe outside a HomeList', () {
      final storage = _FakeStorage([_peerA]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(
        storage,
        prefs,
        _conn(storage: storage),
        _fakeActions(),
        _stubCompletion(),
      );

      // Synchronously still HomeLoading — the getters must not throw.
      expect(vm.state, isA<HomeLoading>());
      expect(vm.visibleItems, isEmpty);

      vm.dispose();
    });

    test('cold-start cached rooms keep their repository group', () async {
      final storage = _FakeStorage([_peerA]);
      await storage.saveRooms('epk_A', const [
        PersistedRoom(
          roomId: 'cached',
          startedAt: 1,
          cwd: '/src/pi-reflex',
          git: GitStatus(branch: 'main', repository: 'pungggi/pi-reflex'),
        ),
      ]);
      final conn = ConnectionManager(
        factory: (_, _) async => _channel(),
        storage: storage,
        emitDebounce: Duration.zero,
      );
      await conn.boot();
      final prefs = Preferences(_FakeSecureStorage());
      await prefs.setHomeGroupBy(HomeGroupBy.repository);
      final vm = HomeViewModel(
        storage,
        prefs,
        conn,
        _fakeActions(),
        _stubCompletion(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(vm.visibleGroups.single.label, 'pi-reflex');
      expect(vm.visibleGroups.single.items.single.room.roomId, 'cached');

      vm.dispose();
      await conn.disconnect();
      conn.dispose();
    });

    test('plan/161: visibleProviderSections nest models; usage is section-scoped', () async {
      final storage = _FakeStorage([_peerA]);
      await storage.saveRooms('epk_A', const [
        PersistedRoom(
          roomId: 'glm47',
          startedAt: 1,
          model: 'GLM 4.7',
          provider: 'zai',
        ),
        PersistedRoom(
          roomId: 'glm46',
          startedAt: 2,
          model: 'GLM 4.6',
          provider: 'zai',
        ),
        PersistedRoom(roomId: 'legacy', startedAt: 3, model: 'GLM 4.7'),
      ]);
      final conn = ConnectionManager(
        factory: (_, _) async => _channel(),
        storage: storage,
        emitDebounce: Duration.zero,
      );
      await conn.boot();
      final prefs = Preferences(_FakeSecureStorage());
      // Default grouping is provider since plan/161 — no explicit set.
      final vm = HomeViewModel(
        storage,
        prefs,
        conn,
        _fakeActions(),
        _stubCompletion(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final sections = vm.visibleProviderSections;
      expect(sections.map((s) => s.label), ['z.ai', 'Unknown provider'],
          reason: 'pretty name first, fallback last');
      final zai = sections.first;
      expect(zai.models.map((m) => m.label), ['GLM 4.6', 'GLM 4.7']);
      expect(zai.itemCount, 2);
      expect(
        sections.last.models.single.items.single.room.roomId,
        'legacy',
        reason: 'no-provider room lands in the fallback section',
      );

      // All rooms cached/offline → plan/156 gating hides the usage line.
      expect(vm.planUsageForSection(zai), isNull);

      vm.dispose();
      await conn.disconnect();
      conn.dispose();
    });

    test(
      'plan/120 — the device room is filtered from the combined list',
      () async {
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peerA]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        final prefs = Preferences(_FakeSecureStorage());
        final vm = HomeViewModel(
          storage,
          prefs,
          conn,
          _fakeActions(),
          _stubCompletion(),
        );
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

        final ids = vm.visibleItems.map((i) => i.room.roomId).toList();
        expect(ids, ['r1']);

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );
  });

  group('HomeViewModel.openTerminal (plan/108 — session-list entry)', () {
    test('routes to the tapped peer when it is NOT active: switchTo + '
        'openTerminal with the room cwd/branch', () async {
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
      final vm = HomeViewModel(
        storage,
        prefs,
        conn,
        actions,
        _stubCompletion(),
      );
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
    });

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
      final vm = HomeViewModel(
        storage,
        prefs,
        conn,
        actions,
        _stubCompletion(),
      );
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

    test('still switchTo (reconnect) when the active peer matches but the '
        'link is offline (review #3)', () async {
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
      final vm = HomeViewModel(
        storage,
        prefs,
        conn,
        actions,
        _stubCompletion(),
      );
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
    });

    test('unknown peer throws ActionFailure and dispatches nothing', () async {
      final storage = _FakeStorage([_peerA]);
      final conn = ConnectionManager(
        factory: (_, _) async => _channel(),
        storage: storage,
      );
      final prefs = Preferences(_FakeSecureStorage());
      final actions = _RecordingActions();
      final vm = HomeViewModel(
        storage,
        prefs,
        conn,
        actions,
        _stubCompletion(),
      );
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
        final vm = HomeViewModel(
          storage,
          prefs,
          conn,
          actions,
          _stubCompletion(),
        );
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
        // Uses start_session, not the separate worktree-opening action.
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
        final vm = HomeViewModel(
          storage,
          prefs,
          conn,
          actions,
          _stubCompletion(),
        );
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
      final vm = HomeViewModel(
        storage,
        prefs,
        conn,
        actions,
        _stubCompletion(),
      );
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

  group('HomeViewModel — worktree cleanup gating (plan/148, PR #70 review)', () {
    test(
      'offline tile WITHOUT a cached registry → entry offered optimistically; '
      'findWorktreeFor resolves the match via the device daemon',
      () async {
        final h = await _cleanupHarness();

        final it = h.item('r1');
        // Menu-open never touches the connection (review #1): the entry is
        // optimistic while the registry is unknown, and the routing stays
        // exactly where it was.
        final roomBefore = h.conn.activeRoomId;
        expect(h.vm.mayOfferCleanup(it), isTrue);
        expect(h.conn.activeRoomId, roomBefore);

        final w = await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1');
        expect(w?.id, 'w1');
        // The fetch rode the device daemon — the session room is dead.
        expect(h.vm.isRoomLive('epk_A', 'r1'), isFalse);
        expect(h.conn.activeRoomId, kDeviceRoom);

        await h.dispose();
      },
    );

    test('a LIVE tile is never offered (its worktree is busy)', () async {
      final h = await _cleanupHarness(roomOffline: false);

      expect(h.vm.isRoomOnline(h.item('r1')), isTrue);
      expect(h.vm.mayOfferCleanup(h.item('r1')), isFalse);

      await h.dispose();
    });

    test('a keeper-held (archive) tile counts as offline → offered '
        '(user decision 2026-10-23)', () async {
      final h = await _cleanupHarness(roomOffline: false, keeper: true);

      // The relay still has a connection in that room (the keeper), but it
      // is a history mirror, not an agent — cleanup stays available.
      expect(h.vm.isRoomLive('epk_A', 'r1'), isTrue);
      expect(h.vm.isRoomOnline(h.item('r1')), isFalse);
      expect(h.vm.mayOfferCleanup(h.item('r1')), isTrue);

      await h.dispose();
    });

    test('untracked folder → findWorktreeFor returns null, and the fetched '
        'registry must NOT hide the entry (1.5.5 device review: an empty '
        'registry made the first cleanup hide all following ones until '
        'app restart — PR #97)', () async {
      final h = await _cleanupHarness(
        roomCwd: '/home/me/main-checkout',
        worktrees: const [],
      );

      final it = h.item('r1');
      expect(h.vm.mayOfferCleanup(it), isTrue);

      // The fetch ran and came back EMPTY (no tracked worktrees on the PC):
      // the entry must survive — forget + local delete is the whole cleanup
      // for untracked folders, exactly what the batch flow offers.
      expect(await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1'), isNull);
      expect(h.vm.mayOfferCleanup(it), isTrue);

      await h.dispose();
    });

    test('offline entry survives a fetched registry that tracks OTHER '
        'folders (unmatched cwd is not a gate)', () async {
      final h = await _cleanupHarness(
        roomCwd: '/home/me/main-checkout',
        worktrees: const [_kWorktree], // tracks /src/remote_pi_w1, NOT r1's cwd
      );

      final it = h.item('r1');
      expect(await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1'), isNull);
      expect(h.vm.mayOfferCleanup(it), isTrue);

      await h.dispose();
    });

    test('routing skips keeper-held rooms: keeper target + live sibling + no '
        'device → the sibling answers the fetch (review #6)', () async {
      final h = await _cleanupHarness(
        roomOffline: false,
        keeper: true,
        deviceLive: false,
        extraRooms: const [_SeedRoom('epk_A', roomId: 'r2', cwd: '/src/other')],
      );

      final w = await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1');
      expect(w?.id, 'w1');
      // NOT the keeper connection — it only serves session_sync and would
      // have let the dispatch time out.
      expect(h.conn.activeRoomId, 'r2');

      await h.dispose();
    });
  });

  group(
    'HomeViewModel — consolidated cleanup execution (plan/158, carries the '
    'plan/148 PR #70 review guards)',
    () {
      test('removes worktree + branch, forgets the room, drops the tile',
          () async {
        final h = await _cleanupHarness();
        final w = await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1');

        final report = await h.vm.cleanupSession(
          epk: 'epk_A',
          roomId: 'r1',
          worktree: w!,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(report.ok, isTrue);
        expect(report.roomForgotten, isTrue);
        expect(h.actions.removedIds, ['w1']);
        // Step 2 ran for THIS room, history untouched (opt-in default).
        expect(
          h.actions.forgetCalls,
          [(roomId: 'r1', deleteHistory: false)],
        );
        // Same-frame disappearance: the delete path ran through
        // ConnectionManager.deleteCachedRoom.
        expect(h.hasRoom('r1'), isFalse);

        await h.dispose();
      });

      test('deleteHistory rides through to the forget call', () async {
        final h = await _cleanupHarness();
        final w = (await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1'))!;

        final report = await h.vm.cleanupSession(
          epk: 'epk_A',
          roomId: 'r1',
          worktree: w,
          deleteHistory: true,
        );
        expect(report.ok, isTrue);
        expect(
          h.actions.forgetCalls,
          [(roomId: 'r1', deleteHistory: true)],
        );

        await h.dispose();
      });

      test('removeWorktree:false skips the git step but still forgets + '
          'deletes locally (unchecked dialog box)', () async {
        final h = await _cleanupHarness();
        final w = (await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1'))!;

        final report = await h.vm.cleanupSession(
          epk: 'epk_A',
          roomId: 'r1',
          worktree: w,
          removeWorktree: false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(report.ok, isTrue);
        expect(report.worktreeAttempted, isFalse);
        expect(h.actions.removedIds, isEmpty);
        expect(h.actions.forgetCalls.single.roomId, 'r1');
        expect(h.hasRoom('r1'), isFalse);

        await h.dispose();
      });

      test('no tracked worktree (main checkout) → forget + local delete '
          'still run; a live sibling in the SAME cwd blocks', () async {
        // Two dead duplicates in the main checkout: cleaning one is fine.
        final h = await _cleanupHarness(
          roomCwd: '/home/me/main-checkout',
          worktrees: const [],
        );
        final report = await h.vm.cleanupSession(
          epk: 'epk_A',
          roomId: 'r1',
        );
        expect(report.ok, isTrue);
        expect(report.worktreeAttempted, isFalse);
        expect(h.actions.removedIds, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(h.hasRoom('r1'), isFalse);
        await h.dispose();

        // …but a LIVE sibling sharing that cwd must block the forget.
        final h2 = await _cleanupHarness(
          roomCwd: '/home/me/main-checkout',
          worktrees: const [],
          extraRooms: const [
            _SeedRoom('epk_A', roomId: 'r2', cwd: '/home/me/main-checkout'),
          ],
        );
        await expectLater(
          h2.vm.cleanupSession(epk: 'epk_A', roomId: 'r1'),
          throwsA(
            isA<ActionFailure>().having(
              (e) => e.message,
              'message',
              contains('Another session'),
            ),
          ),
        );
        expect(h2.actions.forgetCalls, isEmpty);
        await h2.dispose();
      });

      test('a forget refusal keeps the tile (nothing half-done)', () async {
        final h = await _cleanupHarness();
        final w = (await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1'))!;
        h.actions.nextForgetResult = ForgetRoomResult(
          inReplyTo: 'x',
          ok: false,
          message: 'registry write failed',
          registryRemoved: false,
        );

        final report = await h.vm.cleanupSession(
          epk: 'epk_A',
          roomId: 'r1',
          worktree: w,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(report.ok, isFalse);
        expect(report.message, contains('registry'));
        expect(h.hasRoom('r1'), isTrue);

        await h.dispose();
      });

      test('a git refusal keeps the registry entry and the tile', () async {
        final h = await _cleanupHarness();
        final w = (await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1'))!;
        h.actions.nextRemoveResult = RemoveWorktreeResult(
          inReplyTo: 'x',
          ok: false,
          message: 'worktree is dirty — nothing removed',
        );

        final report = await h.vm.cleanupSession(
          epk: 'epk_A',
          roomId: 'r1',
          worktree: w,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(report.ok, isFalse);
        expect(report.message, contains('dirty'));
        // Step 2 never ran: forgetting a room whose worktree removal failed
        // would leave the folder behind AND stop the keeper from serving it.
        expect(h.actions.forgetCalls, isEmpty);
        expect(h.hasRoom('r1'), isTrue);
        // Cache kept → the entry stays visible for a retry without a fetch.
        expect(h.vm.mayOfferCleanup(h.item('r1')), isTrue);

        await h.dispose();
      });

      test('the target session coming back online aborts BEFORE dispatching '
          'the remove', () async {
        final h = await _cleanupHarness();
        final w = (await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1'))!;

        // While the confirmation dialog is open the REAL daemon revives the
        // session: a fresh announce without the keeper flag (the keeper
        // yields to the live daemon). A keeper mirror alone must NOT abort —
        // it is not an agent.
        h.ch.pushControl(
          const RoomAnnounced(peer: 'epk_A', roomId: 'r1', startedAt: 80),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        await expectLater(
          h.vm.cleanupSession(epk: 'epk_A', roomId: 'r1', worktree: w),
          throwsA(
            isA<ActionFailure>().having(
              (e) => e.message,
              'message',
              contains('running again'),
            ),
          ),
        );
        expect(h.actions.removedIds, isEmpty);
        expect(h.actions.forgetCalls, isEmpty);
        expect(h.hasRoom('r1'), isTrue);

        await h.dispose();
      });

      test('a live session at the worktree ROOT (another room, same folder) '
          'blocks the remove', () async {
        final h = await _cleanupHarness(
          extraRooms: const [
            _SeedRoom('epk_A', roomId: 'r2', cwd: _kWorktreeCwd),
          ],
        );
        final w = (await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1'))!;

        await expectLater(
          h.vm.cleanupSession(epk: 'epk_A', roomId: 'r1', worktree: w),
          throwsA(
            isA<ActionFailure>().having(
              (e) => e.message,
              'message',
              contains('Another session'),
            ),
          ),
        );
        expect(h.actions.removedIds, isEmpty);

        await h.dispose();
      });

      test(
        'a live session in a NESTED folder of the worktree blocks the remove '
        '(review #3 — /w1/sub dies with /w1)',
        () async {
          final h = await _cleanupHarness(
            extraRooms: const [
              _SeedRoom(
                'epk_A',
                roomId: 'r2',
                cwd: '$_kWorktreeCwd/packages/app',
              ),
            ],
          );
          final w = (await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1'))!;

          await expectLater(
            h.vm.cleanupSession(epk: 'epk_A', roomId: 'r1', worktree: w),
            throwsA(isA<ActionFailure>()),
          );
          expect(h.actions.removedIds, isEmpty);

          await h.dispose();
        },
      );

      test('a live room on ANOTHER PC with the same absolute path does NOT '
          'block (review #5 — unrelated folders)', () async {
        final h = await _cleanupHarness(
          withPeerB: true,
          extraRooms: const [
            _SeedRoom('epk_B', roomId: 'b1', cwd: _kWorktreeCwd),
          ],
        );
        expect(h.vm.isRoomLive('epk_B', 'b1'), isTrue);
        final w = (await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1'))!;

        final report = await h.vm.cleanupSession(
          epk: 'epk_A',
          roomId: 'r1',
          worktree: w,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(report.ok, isTrue);
        expect(h.actions.removedIds, ['w1']);
        expect(h.actions.forgetCalls.single.roomId, 'r1');

        await h.dispose();
      });

      test(
        'a live session that appeared INSIDE the folder while the dialog was '
        'open aborts the remove (review #2 — guard covers all rooms)',
        () async {
          final h = await _cleanupHarness();
          final w = (await h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1'))!;

          // While the confirmation dialog is open, a duplicate comes online.
          h.ch.pushControl(
            const RoomAnnounced(
              peer: 'epk_A',
              roomId: 'r2',
              startedAt: 90,
              cwd: _kWorktreeCwd,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));

          await expectLater(
            h.vm.cleanupSession(epk: 'epk_A', roomId: 'r1', worktree: w),
            throwsA(
              isA<ActionFailure>().having(
                (e) => e.message,
                'message',
                contains('Another session'),
              ),
            ),
          );
          expect(h.actions.removedIds, isEmpty);
          expect(h.actions.forgetCalls, isEmpty);

          await h.dispose();
        },
      );

      test('unreachable PC → ActionFailure, nothing removed', () async {
        final h = await _cleanupHarness(deviceLive: false);
        // No device room and the target room is dead → nobody can answer.
        await expectLater(
          h.vm.findWorktreeFor(epk: 'epk_A', roomId: 'r1'),
          throwsA(isA<ActionFailure>()),
        );
        expect(h.actions.removedIds, isEmpty);
        expect(h.hasRoom('r1'), isTrue);

        await h.dispose();
      });
    },
  );

  group('HomeViewModel — batch cleanup (plan/158)', () {
    test('prep resolves worktree matches, skips live rooms and reports '
        'unreachable PCs', () async {
      final h = await _cleanupHarness(
        worktrees: const [_kWorktree],
        extraRooms: const [
          // A second session in the MAIN checkout (no worktree match).
          _SeedRoom('epk_A', roomId: 'r9', cwd: '/home/me/main-checkout'),
        ],
      );
      // Make r9 a FINISHED session too (it seeded live).
      h.ch.pushControl(const RoomEnded(peer: 'epk_A', roomId: 'r9', sinceTs: 99));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final items = h.vm.offlineCleanupItems();
      // r1 (offline) + r9 (offline, no tracker match) — nothing else.
      expect(items.map((i) => i.room.roomId), containsAll(['r1', 'r9']));

      final prep = await h.vm.batchCleanupCandidates(items);
      expect(prep.unreachablePeers, isEmpty);
      expect(prep.plans.map((p) => p.roomId), containsAll(['r1', 'r9']));
      expect(
        prep.plans.firstWhere((p) => p.roomId == 'r1').worktree?.id,
        'w1',
      );
      expect(
        prep.plans.firstWhere((p) => p.roomId == 'r9').worktree,
        isNull,
      );

      await h.dispose();
    });

    test('batch cleans every selected item and isolates one failure',
        () async {
      final h = await _cleanupHarness(
        worktrees: const [_kWorktree],
        extraRooms: const [
          _SeedRoom('epk_A', roomId: 'r9', cwd: '/home/me/main-checkout'),
        ],
      );
      h.ch.pushControl(const RoomEnded(peer: 'epk_A', roomId: 'r9', sinceTs: 99));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final prep = await h.vm.batchCleanupCandidates(h.vm.offlineCleanupItems());
      final itemsByKey = {
        for (final i in h.vm.offlineCleanupItems())
          '${i.peer.remoteEpk}|${i.room.roomId}': i,
      };

      // The worktree removal for r1 is REFUSED: r1's report fails while r9
      // (forget + local delete only) still succeeds — per-item isolation.
      h.actions.nextRemoveResult = RemoveWorktreeResult(
        inReplyTo: 'x',
        ok: false,
        message: 'worktree is dirty — nothing removed',
      );
      final reports = await h.vm.cleanupFinishedSessions(
        items: [
          for (final p in prep.plans) itemsByKey['${p.epk}|${p.roomId}']!,
        ],
        deleteHistory: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(reports, hasLength(2));
      final r1 = reports.firstWhere((r) => r.roomId == 'r1');
      final r9 = reports.firstWhere((r) => r.roomId == 'r9');
      expect(r1.ok, isFalse);
      expect(r1.message, contains('dirty'));
      expect(r9.ok, isTrue);
      expect(r9.worktreeAttempted, isFalse);
      // Both items were attempted; only r9's forget ran.
      expect(h.actions.forgetCalls.map((f) => f.roomId), ['r9']);
      expect(h.hasRoom('r1'), isTrue);
      expect(h.hasRoom('r9'), isFalse);

      await h.dispose();
    });

    test('batch reports come back in INPUT order, not per-peer group order '
        '(PR #94 review: the old grouped order mispaired sheet rows)', () async {
      final h = await _cleanupHarness(
        worktrees: const [],
        extraRooms: const [
          _SeedRoom('epk_A', roomId: 'r9', cwd: '/home/me/main-checkout'),
          _SeedRoom('epk_B', roomId: 'b1', cwd: '/home/me/other'),
        ],
        withPeerB: true,
      );
      // Finish the two extra rooms so all three are cleanup candidates.
      h.ch.pushControl(const RoomEnded(peer: 'epk_A', roomId: 'r9', sinceTs: 99));
      h.ch.pushControl(const RoomEnded(peer: 'epk_B', roomId: 'b1', sinceTs: 100));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Interleave the peers: the VM groups work per PC (peer A first
      // here), but must report in the caller's order.
      final reports = await h.vm.cleanupFinishedSessions(
        items: [h.item('r1'), h.item('b1'), h.item('r9')],
      );
      expect(reports.map((r) => r.roomId).toList(), ['r1', 'b1', 'r9']);
      // r1/r9 (peer A, device room answers) succeed; b1 fails honestly —
      // this harness announces no action-capable room on peer B.
      expect(reports[0].ok, isTrue);
      expect(reports[1].ok, isFalse);
      expect(reports[2].ok, isTrue);

      await h.dispose();
    });

    test('an unreachable PC marks ALL its items as failed reports', () async {
      final h = await _cleanupHarness(
        deviceLive: false,
        withPeerB: true,
        worktrees: const [],
      );
      // r1 (peer A, unreachable) + a live room on peer B is filtered out of
      // candidates; construct the batch from the still-offline r1 only.
      final items = h.vm.offlineCleanupItems();
      expect(items.map((i) => i.room.roomId), ['r1']);

      final reports = await h.vm.cleanupFinishedSessions(items: items);
      expect(reports, hasLength(1));
      expect(reports.single.ok, isFalse);
      expect(reports.single.message, isNotEmpty);
      expect(h.actions.forgetCalls, isEmpty);

      await h.dispose();
    });
  },
  );
}
