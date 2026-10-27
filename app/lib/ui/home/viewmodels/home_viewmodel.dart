import 'dart:async';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/notifications/session_completion_notifications.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart' show BoxX;
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

  /// Plan/149 — local box facade for unread counts (msgs rows past the
  /// read marker). Optional so existing tests construct the VM unchanged;
  /// defaults to the shared global-boxes facade.
  final LocalBoxes _boxes;

  /// Plan/132 — per-session completion-notification toggles. The vm
  /// re-emits its HomeList when a toggle flips so the tile bell badges
  /// rebuild without a separate provider.
  final ICompletionNotifications _completion;
  StreamSubscription<Map<String, PresenceState>>? _presenceSub;
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  bool _relayConnected = false;

  /// Security fix 2026-08 (H2) — Online over a non-confidential transport
  /// (`ws://` to a non-loopback host). Drives the persistent banner.
  bool _insecureBannerWanted = false;

  /// `true` when the app is Online over an insecure transport — exposed for
  /// tests and the banner widget.
  bool get isTransportInsecure => _insecureBannerWanted;
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

  HomeViewModel(
    this._storage,
    this._prefs,
    this._conn,
    this._actions,
    this._completion, {
    LocalBoxes? boxes,
  }) : _boxes = boxes ?? LocalBoxes(),
       super(const HomeLoading()) {
    _relayConnected = _conn.status is StatusOnline;
    _load();
    _presenceSub = _conn.presenceStream.listen(_onPresence);
    _roomsSub = _conn.roomsStream.listen(_onRooms);
    _statusSub = _conn.statusStream.listen(_onStatus);
    // Settings (rename / revoke) and pairing flow both write through
    // PairingStorage; listening here keeps Home in sync without manual
    // notifications between screens.
    _storage.addListener(_onStorageChanged);
    // Plan/132 — a toggled session repaints its tile's bell badge.
    _completion.addListener(_reemitHomeList);
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
  /// no matter which path produced the HomeList (review #5). Also derives
  /// the insecure-transport banner (security fix 2026-08) here.
  void _emitHome(HomeList s) {
    final want = _reliabilityBannerWanted && !_reliabilityDismissed;
    if (s.showReliabilityBanner != want) {
      s = s.copyWith(showReliabilityBanner: want);
    }
    final insecureWant = _insecureBannerWanted;
    if (s.showInsecureTransportBanner != insecureWant) {
      s = s.copyWith(showInsecureTransportBanner: insecureWant);
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

  /// Plan/134 — `true` when `(epk, roomId)`'s agent is blocked on a
  /// user-facing ctx.ui prompt (any extension's — pi-ask or foreign).
  /// Drives the amber "needs input" state on the Home tile; takes display
  /// priority over `working` (tri-state derivation lives in the tile).
  bool isRoomWaitingForInput(String epk, String roomId) =>
      _conn.isRoomWaitingForInput(epk, roomId);

  // ---- Plan/132 — completion notifications ---------------------------------

  /// Whether this session's completion notification is toggled on.
  bool notifyOnDone(String epk, String roomId) =>
      _completion.isEnabled(epk, roomId);

  /// Toggle this session's completion notification. Returns whether the
  /// notification permission ended up granted (an enable with a DENIED
  /// permission still persists the intent — caller surfaces the miss).
  Future<bool> setNotifyOnDone(String epk, String roomId, bool value) =>
      _completion.setEnabled(epk, roomId, value);

  /// Plan/149 — unread message count for a session tile (msgs box rows
  /// past the read marker). Never cached: the box rows are the SSOT.
  int unreadCount(String epk, String roomId) => _boxes.unreadCount(epk, roomId);

  /// Plan/149 — listenable that fires whenever the session's unread can
  /// change: the msgs box (row delivery) and the read-markers box (chat
  /// open). A not-yet-open msgs box is opened lazily and triggers a Home
  /// re-emit so the next build merges it in.
  Listenable unreadListenable(String epk, String roomId) {
    final markers = _boxes.readMarkersBox().listenable();
    if (_boxes.isMsgsBoxOpen(epk, roomId)) {
      return Listenable.merge([
        _boxes.openMsgsBox(epk, roomId).listenable(),
        markers,
      ]);
    }
    unawaited(
      _boxes.msgsBox(epk, roomId).then((_) {
        if (!_disposed) _reemitHomeList();
      }),
    );
    return markers;
  }

  /// Keep-alive mode as it affects completion notifications: `off` means
  /// the process is frozen in background and banners can never fire — the
  /// menu shows a hint pointing at Settings.
  KeepAliveMode get keepAliveMode => _prefs.keepAliveMode;

  Future<void> _load() async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    if (peers.isEmpty) {
      emit(const HomeNoPeer());
      return;
    }
    // Plan/149 / PR #71 review — open every room's msgs box BEFORE emitting
    // the HomeList: a tile's unread listenable merges the msgs box only
    // when it is already open, and ViewModel.emit suppresses identical
    // states, so a tile built against a closed box (cold start, offline
    // session) would show 0 unread and NEVER rebuild onto the merged
    // listenable. openBox is idempotent for open boxes, so reloads after
    // the first pay nothing. Boxes open with the RAW peer epk — the same
    // form the chat/SyncService writer uses. Skipped entirely when the
    // boxes namespace was never initialized (Hive-less environments).
    if (LocalBoxes.isInitialized) {
      for (final p in peers) {
        final rooms =
            _conn.roomsSnapshot[toStandardB64(p.remoteEpk)] ??
            const <RoomInfo>[];
        for (final r in rooms) {
          try {
            await _boxes.msgsBox(p.remoteEpk, r.roomId);
          } catch (_) {
            /* best-effort — this tile's unread stays 0 */
          }
        }
      }
    }
    if (_disposed) return;
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
    // Security fix 2026-08 (H2) — track transport confidentiality at every
    // status flip; Online means the channel (and its transport) is attached.
    final insecureNow = next && !_conn.isTransportSecure;
    if (insecureNow != _insecureBannerWanted) {
      _insecureBannerWanted = insecureNow;
      if (state is HomeList) _reemitHomeList();
    }
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
      _emitHome(
        HomeList(
          peers: s.peers,
          statusByEpk: s.statusByEpk,
          roomsByPeer: s.roomsByPeer,
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

  /// `true` when this tile is a real live session on a reachable relay.
  /// Keeper mirrors always count as offline, including for the status color.
  bool isRoomOnline(HomeItem it) => _roomOnline(it.peer.remoteEpk, it.room);

  /// Plan/140 C — a keeper-held room is a durable-history mirror, not a live
  /// agent: it counts as offline for status and plan/148 cleanup gating.
  bool _roomOnline(String epk, RoomInfo room) =>
      !room.keeper && _relayConnected && _conn.isRoomLive(epk, room.roomId);

  /// One combined session list: live, cached/offline, and keeper mirrors.
  /// Keeper mirrors sort last so real sessions stay prominent.
  List<HomeItem> get visibleItems {
    final s = state;
    if (s is! HomeList) return const [];
    return s.items(normalizeEpk: normalizeEpkForLookup)..sort((a, b) {
      if (a.room.keeper == b.room.keeper) return 0;
      return a.room.keeper ? 1 : -1;
    });
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

  // ---- Plan/148 — offline worktree cleanup ---------------------------------

  /// Plan/148 — tracked worktrees per peer, keyed by the RAW epk (the value
  /// the UI holds, not the wire encoding). Filled ONLY by [findWorktreeFor]
  /// at tap time: opening the long-press menu must never route the shared
  /// connection, or the next send of the chat visible in the tablet split
  /// view would go to whatever room the fetch was routed to (PR #70 review).
  /// Absent = unknown, and the menu offers the entry optimistically — tap-time
  /// validation filters untracked folders out with a toast.
  final Map<String, List<WireWorktree>> _worktreesByEpk = {};

  /// Plan/148 — should the long-press sheet offer "Delete worktree & branch"?
  ///
  /// - **Offline only**: an online room's worktree is busy; keeper-held rooms
  ///   count as offline (history mirrors, see [_roomOnline]).
  /// - **Registry cache refines, never gates**: once the peer's registry has
  ///   been fetched (any earlier cleanup attempt), a missing match hides the
  ///   entry. With no cache we cannot know without routing the connection —
  ///   so the entry shows and [findWorktreeFor] decides at tap time.
  bool mayOfferCleanup(HomeItem it) {
    if (_roomOnline(it.peer.remoteEpk, it.room)) return false;
    final list = _worktreesByEpk[it.peer.remoteEpk];
    if (list == null) return true; // unknown — let tap time decide
    return _cachedMatchFor(it.peer.remoteEpk, it.room.cwd) != null;
  }

  /// The tracked worktree whose folder IS [cwd], from the cached registry
  /// (cache-miss safe: returns null when the peer was never fetched).
  WireWorktree? _cachedMatchFor(String epk, String? cwd) {
    final list = _worktreesByEpk[epk];
    if (list == null || cwd == null || cwd.isEmpty) return null;
    for (final w in list) {
      if (_samePath(w.path, cwd)) return w;
    }
    return null;
  }

  /// Plan/148 — tap-time resolution for the cleanup entry: route to the peer
  /// (see [_routeToPeer]), fetch the tracked-worktree registry and return the
  /// entry whose folder IS the session's cwd, or `null` when that folder is
  /// not tracked (main checkout / created outside Piper). This is the FIRST
  /// moment the shared connection may be touched; the caller keeps the modal
  /// dialog barrier up from here on, so the visible chat cannot send into a
  /// misrouted room.
  ///
  /// Throws [ActionFailure] when the PC cannot be reached.
  Future<WireWorktree?> findWorktreeFor({
    required String epk,
    required String roomId,
  }) async {
    await _routeToPeer(epk);
    if (_disposed) return null;
    final room = _actionRoomFor(epk, roomId);
    if (room == null) {
      throw ActionFailure(
        'Could not reach ${_peerLabelForError()}. Start the Cockpit or Pi on '
        'that computer (the supervisor must be running).',
      );
    }
    _conn.switchRoom(room);
    final list = await _actions.listWorktrees();
    if (_disposed) return null;
    _worktreesByEpk[epk] = list;
    return _cachedMatchFor(epk, _roomOf(epk, roomId)?.cwd);
  }

  /// Plan/148 — remove the worktree + branch behind an OFFLINE session and,
  /// only on success, drop the phone-side room record so the tile disappears
  /// in the same frame (the plan/17 delete path).
  ///
  /// On failure nothing is touched: `git worktree remove` refuses a dirty
  /// tree, the registry entry survives, and the room record stays so the user
  /// can retry after committing/stashing. Throws [ActionFailure] when the PC
  /// cannot be reached or a live session still anchors the folder; a git
  /// refusal comes back as `ok:false` with the server's message.
  Future<RemoveWorktreeResult> cleanupWorktree({
    required String epk,
    required String roomId,
    required WireWorktree worktree,
  }) async {
    await _routeToPeer(epk);
    if (_disposed) throw const ActionFailure('cancelled');
    // Race guard (PR #70 review): the tile was offline at tap time, but any
    // session may have come back while the dialog was open. Git happily
    // removes a CLEAN worktree an agent is using — liveness, not dirtiness,
    // is what protects here — so re-check EVERY same-peer session anchored at
    // or under the worktree folder, not just the tile that was long-pressed.
    final liveOwner = _liveWorktreeOwner(epk, worktree, exceptRoomId: roomId);
    if (liveOwner != null) {
      throw ActionFailure(
        liveOwner == roomId
            ? 'This session is running again — nothing was removed.'
            : 'Another session on this computer is using this folder — '
                  'nothing was removed.',
      );
    }
    final room = _actionRoomFor(epk, roomId);
    if (room == null) {
      throw ActionFailure(
        'Could not reach ${_peerLabelForError()}. Start the Cockpit or Pi on '
        'that computer (the supervisor must be running).',
      );
    }
    _conn.switchRoom(room);
    final res = await _actions.removeWorktree(worktree.id);
    if (_disposed) return res;
    if (res.ok) {
      // Folder + branch are gone on the PC: forget the cached list (the next
      // attempt refetches) and drop the phone-side record so the tile goes
      // away immediately instead of lingering as a dead entry.
      _worktreesByEpk.remove(epk);
      await deleteRoom(epk, roomId);
    }
    return res;
  }

  /// Plan/148 — the roomId of a LIVE same-peer session whose cwd is the
  /// worktree root or anywhere INSIDE it (a session running in
  /// `<worktree>/packages/foo` dies with the folder just as surely as one at
  /// the root — PR #70 review), or null. [exceptRoomId] (the tile being
  /// cleaned) is checked too, but reported separately so the UI can say
  /// "this session" vs "another session". Cross-peer rooms with identical
  /// paths are unrelated folders on other computers and never block.
  String? _liveWorktreeOwner(
    String epk,
    WireWorktree worktree, {
    required String exceptRoomId,
  }) {
    for (final it in _allItems()) {
      if (it.peer.remoteEpk != epk) continue;
      if (!_roomOnline(epk, it.room)) continue;
      final isTarget = it.room.roomId == exceptRoomId;
      if (isTarget || _insideWorktree(it.room.cwd, worktree.path)) {
        return it.room.roomId;
      }
    }
    return null;
  }

  /// Plan/148 — route the action channel to [epk]: switch peer when needed and
  /// wait for the link. Same dance as [openTerminal] / [startSession]; shared
  /// here so both plan/148 calls do it once.
  Future<void> _routeToPeer(String epk) async {
    final peers = await _storage.listPeers();
    if (_disposed) throw const ActionFailure('cancelled');
    final match = peers.where((p) => p.remoteEpk == epk).cast<PeerRecord?>();
    if (match.isEmpty) throw const ActionFailure('peer not found');
    final peer = match.first!;
    final samePeer = _conn.activePeer?.remoteEpk == epk;
    if (!samePeer || !_relayConnected) {
      await _conn.switchTo(peer);
      if (_disposed) throw const ActionFailure('cancelled');
      if (_conn.status is! StatusOnline) {
        await _waitForOnline(kTerminalOpenConnectTimeout);
      }
    }
  }

  /// Plan/148 — which room of [epk] should carry an action request. The
  /// device daemon (plan/120) is the first choice: it runs even when every
  /// session room is dead, which is the offline-cleanup case. Then the
  /// target room itself, then any live room of that peer (the same handlers
  /// run in every pi-extension). Keeper-held rooms are skipped everywhere:
  /// their connection is relay-live but they only serve `session_sync`, so an
  /// action dispatched there would time out instead of reaching the fallback
  /// (PR #70 review). `null` = nobody can answer, so the caller fails fast
  /// instead of waiting out the dispatch timeout.
  String? _actionRoomFor(String epk, String targetRoomId) {
    if (_conn.isRoomLive(epk, kDeviceRoom)) return kDeviceRoom;
    String? fallback;
    for (final it in _allItems()) {
      if (it.peer.remoteEpk != epk || it.room.keeper) continue;
      if (it.room.roomId == targetRoomId) {
        if (_conn.isRoomLive(epk, it.room.roomId)) return it.room.roomId;
        continue;
      }
      if (fallback == null && _conn.isRoomLive(epk, it.room.roomId)) {
        fallback = it.room.roomId;
      }
    }
    return fallback;
  }

  /// The cached room record for `(epk, roomId)`, or null.
  RoomInfo? _roomOf(String epk, String roomId) {
    for (final it in _allItems()) {
      if (it.peer.remoteEpk == epk && it.room.roomId == roomId) return it.room;
    }
    return null;
  }

  List<HomeItem> _allItems() {
    final s = state;
    if (s is! HomeList) return const [];
    return s.items(normalizeEpk: normalizeEpkForLookup);
  }

  /// Label for an "unreachable PC" error: nickname → session name → generic.
  String _peerLabelForError() =>
      _conn.activePeer?.nickname ??
      _conn.activePeer?.sessionName ??
      'the computer';

  /// Plan/148 — folder compare that survives separator style. Windows reports
  /// `C:\\a\\b` from git and `C:/a/b` from Pi, so separators and a trailing
  /// slash are normalized away. Drive-letter paths compare case-insensitively
  /// (Windows semantics); POSIX paths stay case-sensitive because `A` and `a`
  /// are different folders there.
  static bool _samePath(String? a, String? b) {
    final x = _normalizePath(a);
    final y = _normalizePath(b);
    if (x.isEmpty || y.isEmpty) return false;
    if (x == y) return true;
    final windows = RegExp(r'^[a-zA-Z]:/');
    if (windows.hasMatch(x) && windows.hasMatch(y)) {
      return x.toLowerCase() == y.toLowerCase();
    }
    return false;
  }

  static String _normalizePath(String? raw) {
    var p = (raw ?? '').trim().replaceAll('\\', '/');
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  /// Plan/148 — `true` when [child] IS [parent] or lives somewhere inside it
  /// (`/w1/packages/foo` dies with `/w1`). Same separator/case rules as
  /// [_samePath].
  static bool _insideWorktree(String? child, String parent) {
    final c = _normalizePath(child);
    final p = _normalizePath(parent);
    if (c.isEmpty || p.isEmpty) return false;
    final windows = RegExp(r'^[a-zA-Z]:/');
    if (windows.hasMatch(c) && windows.hasMatch(p)) {
      final cl = c.toLowerCase();
      final pl = p.toLowerCase();
      return cl == pl || cl.startsWith('$pl/');
    }
    return c == p || c.startsWith('$p/');
  }

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

  /// Plan/124 + plan/152 — bring an OFFLINE session back to life in its own
  /// cwd (no new worktree, no pin). Routes through the device daemon. A stored
  /// Pi session ID resumes exactly in a terminal; older rooms use visible
  /// `pi --continue` instead of hidden RPC. Either path re-announces
  /// the SAME room, so the tile flips live via the rooms push without polling.
  /// [name] scopes custom-named sessions.
  ///
  /// Throws [ActionFailure] when the peer is unreachable, the supervisor's
  /// device daemon isn't live on that PC, or the spawn itself fails.
  Future<StartSessionResult> startSession({
    required String epk,
    required String cwd,
    String? name,
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
    final samePeer = _conn.activePeer?.remoteEpk == epk;
    if (!samePeer || !_relayConnected) {
      await _conn.switchTo(peer);
      if (_disposed) {
        throw const ActionFailure('cancelled');
      }
      if (_conn.status is! StatusOnline) {
        await _waitForOnline(kTerminalOpenConnectTimeout);
      }
    }
    // Revive always rides the device daemon: the target session's own room is
    // offline by definition. The daemon opens a visible terminal and resumes
    // the stored ID exactly or continues the latest session for older rooms.
    // If the device room isn't live, the supervisor isn't running there → fail
    // fast with an actionable message instead of waiting out the dispatch
    // timeout.
    final deviceLive = _conn.isRoomLive(epk, kDeviceRoom);
    if (!deviceLive) {
      final label =
          _conn.activePeer?.nickname ??
          _conn.activePeer?.sessionName ??
          'the computer';
      throw ActionFailure(
        'Could not reach $label. Start the Cockpit or Pi on that computer '
        '(the supervisor must be running).',
      );
    }
    _conn.switchRoom(kDeviceRoom);
    return _actions.startSession(cwd: cwd, name: name);
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
      final label =
          _conn.activePeer?.nickname ??
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
    _completion.removeListener(_reemitHomeList);
    super.dispose();
  }
}
