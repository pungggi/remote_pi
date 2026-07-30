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
  const ProjectsError(this.message);
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

  ProjectsViewModel(this._storage, this._conn, this._actions, this._prefs)
    : super(const ProjectsLoading());

  /// Fetch discovered projects from the device daemon. Routes the shared
  /// connection to the device room on demand. Throws nothing — failures land
  /// as [ProjectsError] in [state].
  Future<void> load() async {
    emit(const ProjectsLoading());
    try {
      await _routeToDeviceRoom();
      if (_disposed) return;
      final projects = await _actions.listProjects();
      if (_disposed) return;
      emit(_sortedReady(projects));
    } on ActionFailure catch (e) {
      if (!_disposed) {
        emit(ProjectsError(e.message.isEmpty ? 'Device unreachable.' : e.message));
      }
    } catch (_) {
      if (!_disposed) emit(const ProjectsError('Device unreachable.'));
    }
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
    super.dispose();
  }
}
