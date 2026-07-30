import 'dart:async';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/home/states/home_state.dart';

/// HomeViewModel — passive list of paired peers + live presence dots
/// + rooms discovered on each peer (plan 17). A single tile per
/// (peer, room).
///
/// The WS connection is owned by [ConnectionManager] from app boot (plano
/// 12). Home only:
///   - reads the peer list from storage
///   - watches `presenceStream` + `roomsStream` to render dots / rooms
///     in real time
///   - writes [Preferences.selectedRoom] when the user taps a tile so
///     `/chat` knows which (peer, room) to address
///
/// Plan/108-offline — how long we wait for a peer to come online after a
/// [ConnectionManager.switchTo] before giving up on an [openTerminal] call.
const kTerminalOpenConnectTimeout = Duration(seconds: 15);

class HomeViewModel extends ViewModel<HomeState> {
  final PairingStorage _storage;
  final Preferences _prefs;
  final ConnectionManager _conn;
  final IActionsRepository _actions;
  StreamSubscription<Map<String, PresenceState>>? _presenceSub;
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  bool _relayConnected = false;
  bool _disposed = false;

  /// Plan/107b — git snapshots keyed `"${standardB64(epk)}|$roomId"`.
  /// Only the active session is populated (the action channel is
  /// active-peer-scoped); other tiles keep their model subtitle.
  Map<String, GitStatus?> _gitByKey = {};
  bool _gitBusy = false;
  // Plan 116 — sustained-offline → reliability banner (60s threshold).
  Timer? _sustainedOfflineTimer;
  bool _reliabilityDismissed = false;
  // Intent that survives a HomeLoading → HomeList transition: set when the
  // 60s timer fires, applied to every emitted HomeList via _emitHome.
  bool _reliabilityBannerWanted = false;

  HomeViewModel(this._storage, this._prefs, this._conn, this._actions)
    : super(const HomeLoading()) {
    _relayConnected = _conn.status is StatusOnline;
    _load();
    _presenceSub = _conn.presenceStream.listen(_onPresence);
    _roomsSub = _conn.roomsStream.listen(_onRooms);
    _statusSub = _conn.statusStream.listen(_onStatus);
    // Settings (rename / revoke) and pairing flow both write through
    // PairingStorage; listening here keeps Home in sync without manual
    // notifications between screens.
    _storage.addListener(_onStorageChanged);
    // Plan 116 — boot may already be offline; arm the banner timer.
    _reconcileReliability(_relayConnected);
  }

  void _onStorageChanged() {
    if (_disposed) return;
    _load();
  }

  /// `true` when the app's WS to the relay is alive (StatusOnline).
  /// When `false`, every room dot should render in the "reconnecting"
  /// colour (amber) regardless of `isRoomLive`, because the app has
  /// no fresh signal on any room.
  bool get isRelayConnected => _relayConnected;

  /// Plan 114 (B) — force a reconnect now (resets the backoff and redials
  /// immediately). Surfaced as the tap target on the Home "Offline" status.
  Future<void> reconnect() => _conn.forceReconnect();

  /// Plan 116 — arm/disarm the sustained-offline banner. When the relay is
  /// non-Online for > 60 s, set [_reliabilityBannerWanted]; recovering to
  /// Online clears it. The intent survives a HomeLoading → HomeList
  /// transition because every HomeList is emitted via [_emitHome], which
  /// derives `showReliabilityBanner` from the wanted flag (review #5).
  void _reconcileReliability(bool online) {
    if (_disposed) return;
    if (online) {
      _sustainedOfflineTimer?.cancel();
      _sustainedOfflineTimer = null;
      _reliabilityDismissed = false;
      _reliabilityBannerWanted = false;
      _reemitHomeList();
    } else {
      _sustainedOfflineTimer ??= Timer(const Duration(seconds: 60), () {
        if (!_disposed && !_relayConnected && !_reliabilityDismissed) {
          _reliabilityBannerWanted = true;
          _reemitHomeList();
        }
      });
    }
  }

  /// Emits a HomeList with the reliability-banner flag derived from
  /// [_reliabilityBannerWanted]. Single chokepoint so the banner is correct
  /// no matter which path produced the HomeList (review #5).
  void _emitHome(HomeList s) {
    final want = _reliabilityBannerWanted && !_reliabilityDismissed;
    if (s.showReliabilityBanner != want) {
      s = s.copyWith(showReliabilityBanner: want);
    }
    emit(s);
  }

  void _reemitHomeList() {
    final s = state;
    if (s is HomeList) _emitHome(s);
  }

  /// Plan 116 — user dismissed the banner; don't nag again until the
  /// connection recovers and drops once more.
  void dismissReliabilityBanner() {
    _reliabilityDismissed = true;
    _reemitHomeList();
  }

  /// `true` when `(epk, roomId)`'s agent is currently mid-turn. Drives
  /// the blue "working" dot on the Home tile.
  ///
  /// Plan/32 — single source of truth: the relay broadcasts `meta.working`
  /// (turn_start/turn_end from the Pi-extension) to ALL subscribed rooms,
  /// exactly like presence, so this reflects EVERY session — connected or
  /// not. We deliberately do NOT OR the DB session index here: that row is
  /// only kept fresh for the currently-connected room (the SyncService
  /// writer follows the active connection), so a session that finishes
  /// while the app is on a DIFFERENT chat would never get its index idled
  /// and the dot would stay blue forever. The relay flag has no such blind
  /// spot.
  bool isRoomWorking(String epk, String roomId) =>
      _conn.isRoomWorking(epk, roomId);

  Future<void> _load() async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    if (peers.isEmpty) {
      emit(const HomeNoPeer());
      return;
    }
    // Make sure the relay is pushing updates for everyone we know about;
    // the call is idempotent so this is safe even mid-session. The same
    // subscribe also covers rooms (plan 17 — replay block in
    // ConnectionManager sends both presence and rooms subscribes).
    _conn.subscribeToPeers(peers.map((p) => p.remoteEpk).toList());
    _emitHome(
      HomeList(
        peers: peers,
        statusByEpk: _conn.presenceSnapshot,
        roomsByPeer: _conn.roomsSnapshot,
        gitByKey: _gitByKey,
      ),
    );
    // Plan/107b — seed the active session's git snapshot now that the
    // list is live (no-op when offline / no active peer yet).
    _maybeFetchGit();
  }

  void _onPresence(Map<String, PresenceState> snapshot) {
    final s = state;
    if (s is! HomeList) return;
    _emitHome(s.copyWith(statusByEpk: snapshot));
  }

  void _onRooms(Map<String, List<RoomInfo>> snapshot) {
    final s = state;
    if (s is! HomeList) return;
    _emitHome(s.copyWith(roomsByPeer: snapshot));
  }

  void _onStatus(ConnectionStatus status) {
    final next = status is StatusOnline;
    if (next == _relayConnected) {
      _reconcileReliability(next);
      return;
    }
    _relayConnected = next;
    // Trigger a re-render of any HomeList so tiles re-evaluate dot
    // colour (room-live vs reconnecting).
    final s = state;
    if (s is HomeList) {
      // emit a duplicate-looking HomeList so context.watch() triggers
      // even though peers / roomsByPeer / presence didn't change.
      // Preserve `filter` — otherwise a status flip would silently reset
      // the user's tab back to the Online default (and, because the new
      // object would then differ, actually fire that reset).
      _emitHome(
        HomeList(
          peers: s.peers,
          statusByEpk: s.statusByEpk,
          roomsByPeer: s.roomsByPeer,
          filter: s.filter,
          gitByKey: _gitByKey,
        ),
      );
    }
    // Plan/107b — relay just came online: refresh the active session's git.
    if (next) _maybeFetchGit();
    _reconcileReliability(next);
  }

  /// Plan/107b — refresh the ACTIVE session's git status (the action
  /// channel is active-peer-scoped, so only the session the user is in /
  /// last opened can be queried). Stores the snapshot keyed by
  /// `"${standardB64(epk)}|$roomId"` so [SessionTile] can look it up.
  /// Never throws: an offline/timeout is recorded as `null` (unavailable).
  Future<void> refreshGitStatus() async {
    if (_gitBusy || _disposed) return;
    final epk = _conn.activePeer?.remoteEpk;
    if (epk == null) return;
    final key = '${toStandardB64(epk)}|${_conn.activeRoomId}';
    _gitBusy = true;
    try {
      final status = await _actions.gitStatus();
      if (_disposed) return;
      _gitByKey = {..._gitByKey, key: status};
    } on ActionFailure catch (_) {
      if (_disposed) return;
      _gitByKey = {..._gitByKey, key: null};
    } finally {
      _gitBusy = false;
    }
    _reemitWithGit();
  }

  /// Auto-fetch hook: seeds git once the list is live AND the relay is
  /// online AND there's an active peer. Idempotent (guarded by `_gitBusy`
  /// + the active-peer check). Called from `_load` + `_onStatus`.
  Future<void> _maybeFetchGit() async {
    if (_disposed) return;
    if (_conn.status is! StatusOnline) return;
    if (_conn.activePeer == null) return;
    await refreshGitStatus();
  }

  void _reemitWithGit() {
    final s = state;
    if (s is! HomeList) return;
    _emitHome(s.copyWith(gitByKey: _gitByKey));
  }

  /// Plan-38 Fase 3 — switch the presence tab. No reload: it only swaps the
  /// `filter` in state so [visibleItems] re-derives. No-op when the state
  /// isn't a list or the filter is unchanged.
  void setFilter(HomeFilter filter) {
    final s = state;
    if (s is! HomeList) return;
    if (s.filter == filter) return;
    _emitHome(s.copyWith(filter: filter));
  }

  /// `true` when `(epk, roomId)` is live on the relay AND the relay itself
  /// is reachable. The single source of truth for the Online/Offline split.
  /// [ConnectionManager.isRoomLive] is already gated on `StatusOnline`, so
  /// the `_relayConnected &&` is belt-and-suspenders that also documents
  /// intent: "online" requires a live relay.
  bool _online(HomeItem it) =>
      _relayConnected && _conn.isRoomLive(it.peer.remoteEpk, it.room.roomId);

  /// Plan-38 Fase 3 — the items the current [HomeList.filter] keeps. A pure
  /// view over `state.items()`; returns `const []` outside a list state.
  List<HomeItem> get visibleItems {
    final s = state;
    if (s is! HomeList) return const [];
    final all = s.items(normalizeEpk: normalizeEpkForLookup);
    return switch (s.filter) {
      HomeFilter.all => all,
      HomeFilter.online => all.where(_online).toList(),
      HomeFilter.offline => all.where((i) => !_online(i)).toList(),
    };
  }

  /// Plan-38 Fase 3 — per-tab counts for the filter badges. Independent of
  /// the active tab (each badge always shows its own slice's size).
  ({int all, int online, int offline}) get counts {
    final s = state;
    if (s is! HomeList) return (all: 0, online: 0, offline: 0);
    final all = s.items(normalizeEpk: normalizeEpkForLookup);
    final online = all.where(_online).length;
    return (all: all.length, online: online, offline: all.length - online);
  }

  /// Remember which (peer, room) the user picked. Falls back to
  /// `roomId='main'` when the caller doesn't supply one (legacy /
  /// pre-room-announce). Also flips the ConnectionManager's active
  /// room so subsequent sends carry the right outer envelope.
  ///
  /// Plan-24 follow-up: when the peer record in storage has no
  /// `roomId` yet (post-mesh-restore: the mesh blob doesn't carry
  /// per-device room data, so `PeerRecord.roomId` is null until the
  /// relay announces the room and `ConnectionManager._maybeAdoptLegacyRoom`
  /// catches up), persist the tapped roomId on the PeerRecord too.
  /// Without this, the next cold-start reads `peer.roomId=null` →
  /// `ConnectionManager._connect` falls back to room `'main'` → Pi
  /// never sees the frame → ChatViewModel sits on Connecting/offline
  /// even though the WS is alive.
  Future<void> openSession(String epk, {String? roomId}) async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    final match = peers.where((p) => p.remoteEpk == epk).cast<PeerRecord?>();
    if (match.isEmpty) return;
    final peer = match.first!;
    final effectiveRoom = (roomId == null || roomId.isEmpty) ? 'main' : roomId;
    await _prefs.setSelectedRoom(epk: epk, roomId: effectiveRoom);
    if (peer.roomId != effectiveRoom) {
      // ignore: unawaited_futures
      _storage.savePeer(peer.copyWith(roomId: effectiveRoom));
    }
    // Tell the manager which Pi-side room to address. Safe to call
    // even if the manager is mid-connect (room is applied on the next
    // send and any active StatusOnline channel).
    _conn.switchRoom(effectiveRoom);
  }

  /// Helper for widgets: pass a peer's url-safe epk → returns standard
  /// for indexing into [HomeList.roomsByPeer] / [HomeList.statusByEpk].
  static String normalizeEpkForLookup(String epk) => toStandardB64(epk);

  /// Plan-17 follow-up — `true` if `(epk, roomId)` is currently live on
  /// the relay. Drives the presence dot on each tile (per-room, not
  /// per-peer anymore).
  bool isRoomLive(String epk, String roomId) => _conn.isRoomLive(epk, roomId);

  /// Long-press menu — rename a single room locally (Pi never sees it).
  Future<void> renameRoom(String epk, String roomId, String? name) =>
      _conn.setRoomLocalName(epk, roomId, name);

  /// Long-press menu — delete a cached room locally. Caller should
  /// gate on `!isRoomLive` (only offline rooms can be removed).
  Future<void> deleteRoom(String epk, String roomId) =>
      _conn.deleteCachedRoom(epk, roomId);

  /// Plan/108 — open a terminal (worktree + `pi` tab) for a specific
  /// session straight from the Home list. The action channel is
  /// active-peer-scoped, so this first routes the connection to the
  /// tapped session's peer (a no-op `switchTo` when it is already the
  /// active+online one) and room, then dispatches
  /// [IActionsRepository.openTerminal] at that room's cwd. Unlike
  /// [openSession], it does NOT touch [Preferences] — switching here is
  /// just routing for this one action; the user's next chat open is
  /// unchanged.
  ///
  /// When the target peer is offline (e.g. the user tapped an item in the
  /// Offline tab), [switchTo] triggers a reconnect and this method waits
  /// up to [kTerminalOpenConnectTimeout] for the connection to come online
  /// before dispatching. If the peer stays unreachable the call throws
  /// [ActionFailure] with a descriptive message.
  ///
  /// Throws [ActionFailure] on transport issues (offline / timeout / peer
  /// not found); a launch failure comes back as `ok:false` in the result.
  Future<OpenTerminalResult> openTerminal({
    required String epk,
    required String roomId,
    String? cwd,
    bool runPi = true,
    String? branch,
  }) async {
    final peers = await _storage.listPeers();
    if (_disposed) {
      throw const ActionFailure('cancelled');
    }
    final match = peers.where((p) => p.remoteEpk == epk).cast<PeerRecord?>();
    if (match.isEmpty) {
      throw const ActionFailure('peer not found');
    }
    final peer = match.first!;
    // Route the action to the tapped session's Pi. The action channel
    // rides the active connection, so switch peer + room before
    // dispatching. Match ConnectionManager.switchTo's own no-op gate
    // (same peer AND online): if the active peer already matches but the
    // link is offline/connecting, we still switch so switchTo kicks a
    // reconnect instead of dispatching into a dead channel.
    final samePeer = _conn.activePeer?.remoteEpk == epk;
    if (!samePeer || !_relayConnected) {
      await _conn.switchTo(peer);
      if (_disposed) {
        throw const ActionFailure('cancelled');
      }
      // Plan/108-offline — wait for the connection to come online before
      // dispatching. switchTo returns as soon as the first connect attempt
      // settles (success or retry-scheduled); we block here until the
      // channel is actually available or the timeout fires.
      if (_conn.status is! StatusOnline) {
        await _waitForOnline(kTerminalOpenConnectTimeout);
      }
    }
    // After connecting, decide which room to dispatch to.
    // Plan/120 — if the target session room is offline but the supervisor's
    // device daemon is live, route to the device room instead. The device
    // daemon's pi-extension handles open_terminal_request at the requested
    // cwd (it creates the worktree there regardless of its own cwd).
    final targetLive = _conn.isRoomLive(epk, roomId);
    final deviceLive = _conn.isRoomLive(epk, kDeviceRoom);
    final dispatchRoom = (!targetLive && deviceLive) ? kDeviceRoom : roomId;
    _conn.switchRoom(dispatchRoom);
    return _actions.openTerminal(cwd: cwd, runPi: runPi, branch: branch);
  }

  /// Waits up to [timeout] for the connection to reach [StatusOnline].
  /// Throws [ActionFailure] on timeout or if the VM is disposed mid-wait.
  Future<void> _waitForOnline(Duration timeout) async {
    final completer = Completer<void>();
    late final StreamSubscription<ConnectionStatus> sub;
    sub = _conn.statusStream.listen((s) {
      if (s is StatusOnline) {
        sub.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    });
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      sub.cancel();
      final label = _conn.activePeer?.nickname ??
          _conn.activePeer?.sessionName ??
          'the computer';
      throw ActionFailure(
        'Could not reach $label. Make sure the relay is reachable and ' 
        'pi-supervisord is installed (`/remote-pi install`).',
      );
    } finally {
      if (_disposed && !completer.isCompleted) {
        sub.cancel();
        if (!completer.isCompleted) {
          completer.completeError(const ActionFailure('cancelled'));
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _presenceSub?.cancel();
    _roomsSub?.cancel();
    _statusSub?.cancel();
    _sustainedOfflineTimer?.cancel();
    _storage.removeListener(_onStorageChanged);
    super.dispose();
  }
}
