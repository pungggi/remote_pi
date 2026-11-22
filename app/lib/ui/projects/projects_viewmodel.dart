import 'dart:async';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';

/// Plan/121 — Projects screen state.
sealed class ProjectsState {
  const ProjectsState();
}

final class ProjectsLoading extends ProjectsState {
  const ProjectsLoading();
}

final class ProjectsReady extends ProjectsState {
  final List<WireProject> projects;
  // Plan/122 — absolute paths pinned to the top. Drives the per-tile icon +
  // the pinned-first ordering the viewmodel emits.
  final Set<String> pinnedPaths;
  const ProjectsReady(this.projects, {this.pinnedPaths = const {}});
}

final class ProjectsError extends ProjectsState {
  final String message;

  /// Plan/168 — what failed. Drives the repair affordance: [relay] means
  /// the phone never reached the relay (no channel to send `daemon_control`
  /// on — no repair possible); [device] (default) means the link is up but
  /// the device daemon's room is dark (repair available).
  final ProjectsErrorKind kind;
  const ProjectsError(this.message, {this.kind = ProjectsErrorKind.device});
}

/// Plan/168 — failure diagnosis for [ProjectsError].
enum ProjectsErrorKind { relay, device }

/// Plan/168 — transient state while a `daemon_control restart` round-trip
/// (plus the wait for the daemon to come back) is in flight. Ends in
/// [ProjectsReady] (single retry succeeded) or back in [ProjectsError]
/// (device kind → the page shows the Retry restart button).
final class ProjectsRepairing extends ProjectsState {
  const ProjectsRepairing();
}

/// Plan/121 — viewmodel for the Projects screen.
///
/// Deliberately lightweight: unlike [HomeViewModel] it subscribes to **no**
/// connection streams in its constructor. Routing to the device room
/// ([kDeviceRoom]) and the wait-for-online happen on-demand inside
/// [load]/[openTerminalForProject], and the only stream subscription
/// (`_waitForOnline`) is short-lived and cancelled before returning. This
/// keeps a second VM from doubling the connection's per-message work (which
/// made the app slow/strange when Projects reused a full HomeViewModel).
class ProjectsViewModel extends ViewModel<ProjectsState> {
  final PairingStorage _storage;
  final ConnectionManager _conn;
  final IActionsRepository _actions;
  final Preferences _prefs;
  bool _disposed = false;

  // Plan/168 — device-daemon self-repair bookkeeping.
  /// Display label of the routed peer ("Device daemon offline on <label>").
  String? _peerLabel;

  /// Auto-repair fires at most once per screen visit (VM lifetime) —
  /// auto once, then the manual Retry button (plan/168 UX decision).
  bool _autoRepairFired = false;
  Timer? _graceTimer;

  ProjectsViewModel(this._storage, this._conn, this._actions, this._prefs)
    : super(const ProjectsLoading());

  /// Fetch discovered projects from the device daemon. Routes the shared
  /// connection to the device room on demand. Throws nothing — failures land
  /// as [ProjectsError] in [state].
  Future<void> load() async {
    _graceTimer?.cancel();
    emit(const ProjectsLoading());
    var routed = false;
    try {
      await _routeToDeviceRoom();
      if (_disposed) return;
      routed = true;
      final projects = await _actions.listProjects();
      if (_disposed) return;
      emit(_sortedReady(projects));
    } on ActionFailure catch (e) {
      if (!_disposed) _emitFailure(routed, e);
    } catch (_) {
      if (!_disposed) _emitFailure(routed, null);
    }
  }

  /// Plan/168 — translate a load failure into a diagnosed error state.
  /// [routed] is true only when routing to the device room SUCCEEDED (the
  /// relay link is up): a failure past that point means the daemon room is
  /// dark, which is repairable via `daemon_control` (the keeper holds the
  /// room control-only exactly for this). Earlier failures mean the phone
  /// itself has no channel — no repair is possible.
  void _emitFailure(bool routed, ActionFailure? e) {
    if (!routed) {
      final noPeer = e?.message == 'no paired peer';
      emit(ProjectsError(
        noPeer ? 'No paired peer.' : 'No connection to relay.',
        kind: ProjectsErrorKind.relay,
      ));
      return;
    }
    emit(ProjectsError(
      'Device daemon offline on ${_peerLabel ?? 'the PC'}.',
      kind: ProjectsErrorKind.device,
    ));
    _scheduleAutoRepair();
  }

  /// Plan/168 — after a 10 s grace (transient blips usually clear on
  /// their own; pull-to-refresh is also wired to [load]), fire the repair
  /// flow exactly once per screen visit. If the state moved on (user
  /// recovered manually), the timer pops as a no-op.
  void _scheduleAutoRepair() {
    if (_autoRepairFired) return;
    _autoRepairFired = true;
    _graceTimer = Timer(const Duration(seconds: 10), () {
      if (_disposed) return;
      final s = state;
      if (s is ProjectsError && s.kind == ProjectsErrorKind.device) {
        repairNow();
      }
    });
  }

  /// Plan/168 — the repair flow (auto timer + Retry button both land
  /// here): re-route → `daemon_control restart` → wait ≤10 s for the real
  /// daemon to re-announce the device room → ONE `list_projects` retry.
  /// Throws nothing — progress and outcomes land in [state].
  Future<void> repairNow() async {
    if (_disposed) return;
    _graceTimer?.cancel();
    emit(const ProjectsRepairing());
    try {
      await _routeToDeviceRoom();
    } catch (_) {
      if (!_disposed) {
        emit(const ProjectsError(
          'No connection to relay.',
          kind: ProjectsErrorKind.relay,
        ));
      }
      return;
    }
    if (_disposed) return;
    try {
      await _actions.restartDeviceDaemon();
      if (_disposed) return;
      await _waitForDeviceRoomLive(const Duration(seconds: 10));
      if (_disposed) return;
    } catch (_) {
      if (!_disposed) {
        emit(const ProjectsError(
          'Restart sent, daemon still unreachable.',
          kind: ProjectsErrorKind.device,
        ));
      }
      return;
    }
    try {
      final projects = await _actions.listProjects();
      if (!_disposed) emit(_sortedReady(projects));
    } on ActionFailure {
      if (!_disposed) {
        emit(const ProjectsError(
          'Daemon restarted but still unreachable.',
          kind: ProjectsErrorKind.device,
        ));
      }
    }
  }

  /// Wait up to [timeout] for the device room to be held by a LIVE daemon
  /// again. The keeper's control-only presence never announces room meta
  /// (plan/120 invisible-room filter), so "an entry with meta" means the
  /// respawned daemon re-announced. Scoped subscription, cancelled in
  /// `finally` — never leaks past the await.
  Future<void> _waitForDeviceRoomLive(Duration timeout) async {
    if (_deviceRoomLive()) return;
    final completer = Completer<void>();
    final sub = _conn.roomsStream.listen((_) {
      if (_deviceRoomLive() && !completer.isCompleted) completer.complete();
    });
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(const ActionFailure('timeout'));
      }
    });
    try {
      await completer.future;
    } finally {
      sub.cancel();
      timer.cancel();
    }
  }

  /// The device room counts as live when an entry with room meta (cwd or
  /// model) exists for the active peer — the keeper publishes none.
  bool _deviceRoomLive() {
    final epk = _conn.activePeer?.remoteEpk;
    if (epk == null) return false;
    for (final r in _conn.roomsFor(epk)) {
      if (r.roomId == kDeviceRoom && (r.cwd != null || r.model != null)) {
        return true;
      }
    }
    return false;
  }

  /// Spawn a worktree terminal for a project. Routes to the device room on
  /// demand. Throws [ActionFailure] on offline/timeout; a launch failure comes
  /// back as `ok:false` in the result.
  Future<OpenTerminalResult> openTerminalForProject({
    required String cwd,
    required String branch,
  }) async {
    await _routeToDeviceRoom();
    if (_disposed) throw const ActionFailure('cancelled');
    return _actions.openTerminal(cwd: cwd, branch: branch);
  }

  /// Plan/122 — toggle a project's pin and re-sort the current list. No-op
  /// outside [ProjectsReady]. Persists via [Preferences]; the list re-emits
  /// immediately so the UI flips optimistically. Persistence failures are
  /// swallowed — pinning must never crash.
  Future<void> togglePin(String path) async {
    try {
      await _prefs.togglePinnedProject(path);
    } catch (_) {
      // best-effort: the optimistic re-sort still reflects the toggle
    }
    final s = state;
    if (s is ProjectsReady && !_disposed) {
      emit(_sortedReady(s.projects));
    }
  }

  /// Build a [ProjectsReady] with projects partitioned: pinned (per
  /// [Preferences.pinnedProjects]) first, then the rest — each group
  /// preserving the discovery order returned by the device daemon. A stable
  /// partition (not [List.sort]) keeps within-group order deterministic.
  ProjectsReady _sortedReady(List<WireProject> projects) {
    final pinned = _prefs.pinnedProjects.toSet();
    if (pinned.isEmpty) {
      return ProjectsReady(projects, pinnedPaths: const {});
    }
    final pinnedItems = <WireProject>[];
    final rest = <WireProject>[];
    for (final p in projects) {
      (pinned.contains(p.path) ? pinnedItems : rest).add(p);
    }
    return ProjectsReady([...pinnedItems, ...rest], pinnedPaths: pinned);
  }

  /// Route the shared WS connection to the device daemon's room. switchTo the
  /// first paired peer (a no-op when already active + online) and wait for the
  /// link to settle before switching the room, so the dispatch lands on a live
  /// channel.
  Future<void> _routeToDeviceRoom() async {
    final peers = await _storage.listPeers();
    if (peers.isEmpty) throw const ActionFailure('no paired peer');
    final peer = peers.first;
    _peerLabel = peer.sessionName;
    final samePeer = _conn.activePeer?.remoteEpk == peer.remoteEpk;
    if (!samePeer || _conn.status is! StatusOnline) {
      await _conn.switchTo(peer);
      if (_disposed) throw const ActionFailure('cancelled');
      if (_conn.status is! StatusOnline) {
        await _waitForOnline(const Duration(seconds: 15));
      }
    }
    _conn.switchRoom(kDeviceRoom);
  }

  /// Wait up to [timeout] for the connection to reach [StatusOnline]. The
  /// subscription is scoped to this call (cancelled in `finally`) — never
  /// leaks past the await.
  Future<void> _waitForOnline(Duration timeout) async {
    if (_conn.status is StatusOnline) return;
    final completer = Completer<void>();
    final sub = _conn.statusStream.listen((s) {
      if (s is StatusOnline && !completer.isCompleted) completer.complete();
    });
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(const ActionFailure('timeout'));
      }
    });
    try {
      await completer.future;
    } finally {
      sub.cancel();
      timer.cancel();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _graceTimer?.cancel();
    super.dispose();
  }
}
