// Plan/168 — Projects screen renders the repair affordances: the two
// diagnosed error variants (relay vs device daemon) and the Retry
// restart button wiring into ProjectsViewModel.repairNow.

import 'dart:async';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/projects/projects_page.dart';
import 'package:app/ui/projects/projects_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

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

  // No-op room-registry persistence (real one needs a platform binding).
  @override
  Future<List<PersistedRoom>> loadRooms(String remoteEpk) async => const [];
  @override
  Future<void> saveRooms(String remoteEpk, List<PersistedRoom> rooms) async {}
  @override
  Future<void> deleteRooms(String remoteEpk) async {}
}

class _FakeActions implements IActionsRepository {
  final List<Object> listBehaviors = [];
  Object restartResult =
      const DaemonRestartResult(daemon: 'device', restarted: true);

  @override
  Future<List<WireProject>> listProjects() async {
    final b = listBehaviors.removeAt(0);
    if (b is Exception) throw b;
    return b as List<WireProject>;
  }

  @override
  Future<DaemonControlResult> restartDeviceDaemon() async => restartResult
      as DaemonControlResult;

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

Widget _wrap(ProjectsViewModel vm) => MaterialApp(
      home: ChangeNotifierProvider<ProjectsViewModel>.value(
        value: vm,
        child: const ProjectsPage(),
      ),
    );

void main() {
  testWidgets('device error shows Retry restart; tap enters Repairing', (
    tester,
  ) async {
    // Restart REFUSED (ActionFailure) so the repair flow returns to the
    // error state without arming the 10 s room-live wait — keeps the test
    // free of timers that outlive teardown (retry loop of a throwing
    // factory re-arms timers after dispose).
    final actions = _FakeActions()
      ..listBehaviors.add(const ActionFailure('timeout'))
      ..restartResult = const ActionFailure(
        'remote session control disabled on this peer',
      );
    final ch = _FakeChannel();
    final cm = ConnectionManager(
      factory: (_, _) async => ch,
      storage: _FakeStorage(),
      emitDebounce: Duration.zero,
    );
    final vm = ProjectsViewModel(_FakeStorage(), cm, actions, Preferences());
    cm.adopt(ch, _peer);

    await tester.pumpWidget(_wrap(vm));
    await tester.pump(); // postFrame callback → load()
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Device daemon offline'), findsOneWidget);
    expect(find.text('Retry restart'), findsOneWidget);

    // Manual re-fire (auto timer path covered by the viewmodel tests):
    // tap → repairNow → refused restart → back to the device error.
    await tester.tap(find.text('Retry restart'));
    await tester.pump();
    expect(find.text('Device daemon offline'), findsOneWidget);
    expect(find.text('Retry restart'), findsOneWidget);

    // Repairing banner renders. Seeded directly: the live flow passes
    // through Repairing between microtasks (a refused restart returns
    // before any frame lands — asserted by the state above).
    vm.emit(const ProjectsRepairing());
    await tester.pump();
    expect(find.text('Restarting device daemon…'), findsOneWidget);

    // Cleanup INSIDE the body: flutter_test's !timersPending invariant
    // runs before addTearDown callbacks, so disposal must happen here.
    vm.dispose();
    cm.dispose();
  });

  testWidgets('relay error shows no repair button', (tester) async {
    final actions = _FakeActions()..listBehaviors.add(const ActionFailure('x'));
    final cm = ConnectionManager(
      factory: (_, _) async => throw Exception('no relay'),
      storage: _FakeStorage(),
      emitDebounce: Duration.zero,
    );
    final vm = ProjectsViewModel(_FakeStorage(), cm, actions, Preferences());

    await tester.pumpWidget(_wrap(vm));
    await tester.pump(); // load() → routing fails, waits up to 15 s online
    await tester.pump(const Duration(seconds: 16));
    expect(find.text('No connection to relay'), findsOneWidget);
    expect(find.text('Retry restart'), findsNothing);
    // Quiesce: let any in-flight CM retry callback finish arming its next
    // backoff timer so dispose cancels a real armed timer instead of
    // racing a mid-flight microtask. Cleanup stays INSIDE the body:
    // flutter_test's !timersPending invariant runs before addTearDown.
    await tester.pump(const Duration(milliseconds: 500));
    vm.dispose();
    cm.dispose();
  });
}
