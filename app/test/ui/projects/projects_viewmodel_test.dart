// Plan/168 — Projects screen self-repair (device daemon dark).
//
// Covers the diagnosis split (relay vs device), the auto-repair-once
// flow (10 s grace → single daemon_control restart → wait for the real
// daemon to re-announce → single list_projects retry), the manual
// re-fire path (Retry restart button), and the dispose guarantees.

import 'dart:async';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/projects/projects_viewmodel.dart';
import 'package:fake_async/fake_async.dart';
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
  Future<List<PeerRecord>> listPeers() async => const [
        PeerRecord(
          remoteEpk: 'epk_p',
          sessionName: 'PC-Name',
          relayUrl: 'ws://localhost',
          pairedAt: '2026-01-01T00:00:00Z',
        ),
      ];

  // Room-registry persistence: the real implementations hit
  // FlutterSecureStorage (MethodChannel → needs a binding). The
  // ConnectionManager persists on every RoomAnnounced — keep no-op.
  @override
  Future<List<PersistedRoom>> loadRooms(String remoteEpk) async => const [];
  @override
  Future<void> saveRooms(String remoteEpk, List<PersistedRoom> rooms) async {}
  @override
  Future<void> deleteRooms(String remoteEpk) async {}
}

class _EmptyStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

/// Controllable actions fake — only what ProjectsViewModel touches. Every
/// other member throws UnimplementedError (mirrors the QuickActions fakes).
class _FakeActions implements IActionsRepository {
  int restartCalls = 0;

  /// Per-call outcomes for listProjects(): a `List<WireProject>` succeeds,
  /// an Exception (typically ActionFailure) is thrown. Popped in order.
  final List<Object> listBehaviors = [];

  /// Outcome of restartDeviceDaemon(): DaemonControlResult or Exception.
  Object restartResult =
      const DaemonRestartResult(daemon: 'device', restarted: true);

  @override
  Future<List<WireProject>> listProjects() async {
    final b = listBehaviors.removeAt(0);
    if (b is Exception) throw b;
    return b as List<WireProject>;
  }

  @override
  Future<DaemonControlResult> restartDeviceDaemon() async {
    restartCalls++;
    final r = restartResult;
    if (r is Exception) throw r;
    return r as DaemonControlResult;
  }

  @override
  Future<void> compact() async => throw UnimplementedError();
  @override
  Future<void> newSession() async => throw UnimplementedError();
  @override
  Future<void> shutdown() async => throw UnimplementedError();
  @override
  Future<void> setModel(String provider, String modelId) async =>
      throw UnimplementedError();
  @override
  Future<void> setThinking(ThinkingLevel level) async =>
      throw UnimplementedError();
  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async =>
      throw UnimplementedError();
  @override
  Future<GitStatus?> gitStatus() async => throw UnimplementedError();
  @override
  Future<PlanResetResult> planResetCard({required String kind}) async =>
      throw UnimplementedError();
  @override
  Future<OpenTerminalResult> openTerminal({
    String? cwd,
    bool runPi = true,
    String? worktreePath,
    String? branch,
  }) async => throw UnimplementedError();
  @override
  Future<List<WireWorktree>> listWorktrees({String? base}) async =>
      throw UnimplementedError();
  @override
  Future<RemoveWorktreeResult> removeWorktree(String worktreeId) async =>
      throw UnimplementedError();
  @override
  Future<ForgetRoomResult> forgetRoom(String roomId,
          {bool deleteHistory = false}) async =>
      throw UnimplementedError();
  @override
  Future<ChangeLayoutResult> changeLayout(String layout) async =>
      throw UnimplementedError();
  @override
  Future<StartSessionResult> startSession(
          {required String cwd, String? name}) async =>
      throw UnimplementedError();
  @override
  Future<SetSessionRefResult> setSessionRef(
          {required String roomId, required GhRef? ghRef, String? cwd}) async =>
      throw UnimplementedError();
  @override
  Future<DaemonControlResult> deviceStatus() async =>
      throw UnimplementedError();
  @override
  ActiveRoomMeta get activeRoomMeta => const ActiveRoomMeta();
  @override
  Stream<ActiveRoomMeta> get activeRoomMetaStream =>
      const Stream<ActiveRoomMeta>.empty();
  @override
  void dispose() {}
}

const _peer = PeerRecord(
  remoteEpk: 'epk_p',
  sessionName: 'PC-Name',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);

({ProjectsViewModel vm, _FakeChannel ch, _FakeActions actions,
  ConnectionManager cm}) _make(
  _FakeActions actions, {
  PairingStorage? storage,
}) {
  final ch = _FakeChannel();
  final cm = ConnectionManager(
    factory: (_, _) async => ch,
    storage: storage ?? _FakeStorage(),
    emitDebounce: Duration.zero,
  );
  final vm = ProjectsViewModel(
    storage ?? _FakeStorage(),
    cm,
    actions,
    Preferences(),
  );
  // Adopt makes the link StatusOnline synchronously — routing then takes
  // the no-switchTo fast path exactly like a warm production connection.
  cm.adopt(ch, _peer);
  return (vm: vm, ch: ch, actions: actions, cm: cm);
}

void main() {
  test('dark room: device diagnosis, auto-repair fires exactly once', () {
    fakeAsync((async) {
      final actions = _FakeActions()
        ..listBehaviors.add(const ActionFailure('timeout'))
        ..restartResult =
            const DaemonRestartResult(daemon: 'device', restarted: true);
      final s = _make(actions);
      s.vm.load();
      async.elapse(const Duration(milliseconds: 50));

      // Diagnosis: routed fine, room dark → device kind + peer label.
      var st = s.vm.state;
      expect(
        st,
        isA<ProjectsError>()
            .having((e) => e.kind, 'kind', ProjectsErrorKind.device)
            .having((e) => e.message, 'message', contains('PC-Name')),
      );
      expect(actions.restartCalls, 0, reason: 'grace period first');

      // Grace elapses → exactly one daemon_control restart fires.
      async.elapse(const Duration(seconds: 10, milliseconds: 50));
      expect(actions.restartCalls, 1);

      // Ack arrives but the room never goes live → wait times out → back
      // to a device error (Retry restart button state). No second auto-fire.
      async.elapse(const Duration(seconds: 11));
      expect(actions.restartCalls, 1);
      st = s.vm.state;
      expect(
        st,
        isA<ProjectsError>()
            .having((e) => e.kind, 'kind', ProjectsErrorKind.device),
      );
      s.vm.dispose();
      s.cm.dispose();
    });
  });

  test('ack + daemon re-announces: single retry lands ProjectsReady', () {
    fakeAsync((async) {
      final actions = _FakeActions()
        ..listBehaviors.addAll([
          const ActionFailure('timeout'), // initial load: dark
          [WireProject(path: 'C:\\dev\\repo', name: 'repo')], // retry
        ])
        ..restartResult =
            const DaemonRestartResult(daemon: 'device', restarted: true);
      final s = _make(actions);
      s.vm.load();
      async.elapse(const Duration(milliseconds: 50));
      expect(s.vm.state, isA<ProjectsError>());

      // Grace fires the repair; the daemon acks and (after a beat) the
      // respawned daemon re-announces the device room with real meta.
      async.elapse(const Duration(seconds: 10, milliseconds: 50));
      expect(actions.restartCalls, 1);
      expect(s.vm.state, isA<ProjectsRepairing>());
      s.ch.pushControl(
        RoomAnnounced(
          peer: 'epk_p',
          roomId: kDeviceRoom,
          startedAt: 42,
          cwd: 'C:\\dev',
        ),
      );
      async.elapse(const Duration(milliseconds: 50));

      final st = s.vm.state;
      expect(
        st,
        isA<ProjectsReady>().having(
          (r) => r.projects.length,
          'projects',
          1,
        ),
      );
      s.vm.dispose();
      s.cm.dispose();
    });
  });

  test('relay unreachable: relay diagnosis, auto-repair never fires', () {
    fakeAsync((async) {
      final actions = _FakeActions();
      final cm = ConnectionManager(
        factory: (_, _) async => throw Exception('no relay'),
        storage: _FakeStorage(),
        emitDebounce: Duration.zero,
      );
      final vm = ProjectsViewModel(_FakeStorage(), cm, actions, Preferences());
      vm.load();
      // Routing waits up to 15 s for StatusOnline before giving up.
      async.elapse(const Duration(seconds: 16));

      expect(
        vm.state,
        isA<ProjectsError>()
            .having((e) => e.kind, 'kind', ProjectsErrorKind.relay)
            .having((e) => e.message, 'message', 'No connection to relay.'),
      );
      async.elapse(const Duration(seconds: 20));
      expect(actions.restartCalls, 0);
      vm.dispose();
      cm.dispose();
    });
  });

  test('no paired peer: relay diagnosis with explicit message', () {
    fakeAsync((async) {
      final actions = _FakeActions()..listBehaviors.add(const ActionFailure('x'));
      final s = _make(actions, storage: _EmptyStorage());
      s.vm.load();
      async.elapse(const Duration(milliseconds: 50));
      expect(
        s.vm.state,
        isA<ProjectsError>()
            .having((e) => e.kind, 'kind', ProjectsErrorKind.relay)
            .having((e) => e.message, 'message', 'No paired peer.'),
      );
      s.vm.dispose();
      s.cm.dispose();
    });
  });

  test('manual reload does not re-arm the auto-repair', () {
    fakeAsync((async) {
      final actions = _FakeActions()
        ..listBehaviors.addAll([
          const ActionFailure('timeout'), // load #1
          const ActionFailure('timeout'), // load #2 (manual reload)
        ]);
      final s = _make(actions);
      s.vm.load();
      async.elapse(const Duration(milliseconds: 50));
      async.elapse(const Duration(seconds: 21, milliseconds: 100));
      // Auto attempt done (restart #1), wait timed out, error shown again.
      expect(actions.restartCalls, 1);

      s.vm.load(); // manual reload → dark again
      async.elapse(const Duration(milliseconds: 50));
      expect(s.vm.state, isA<ProjectsError>());
      async.elapse(const Duration(seconds: 30));
      expect(actions.restartCalls, 1, reason: 'once per screen visit');
      s.vm.dispose();
      s.cm.dispose();
    });
  });

  test('repairNow() re-fires manually (Retry restart button path)', () {
    fakeAsync((async) {
      final actions = _FakeActions()
        ..listBehaviors.add(const ActionFailure('timeout'));
      final s = _make(actions);
      s.vm.load();
      async.elapse(const Duration(seconds: 21, milliseconds: 100));
      expect(actions.restartCalls, 1);

      s.vm.repairNow();
      async.elapse(const Duration(milliseconds: 50));
      expect(actions.restartCalls, 2);
      expect(s.vm.state, isA<ProjectsRepairing>());
      s.vm.dispose();
      s.cm.dispose();
    });
  });

  test('dispose cancels the grace timer', () {
    fakeAsync((async) {
      final actions = _FakeActions()
        ..listBehaviors.add(const ActionFailure('timeout'));
      final s = _make(actions);
      s.vm.load();
      async.elapse(const Duration(milliseconds: 50));
      s.vm.dispose();
      async.elapse(const Duration(seconds: 30));
      expect(actions.restartCalls, 0);
      s.cm.dispose(); // vm already disposed mid-test
    });
  });
}
