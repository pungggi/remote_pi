// Plan/31 — SyncService: the SINGLE writer of the local SSOT.
//
// Consumes the channel (ConnectionManager status + PeerChannel
// serverMessages) and writes row-granular records to Hive (v2 boxes). The UI
// never touches this stream — it reads the DB via the read repositories.
//
// Streaming is the ONE exception to SSOT (#7): AgentChunk deltas are coalesced
// into an in-memory Stream<StreamingMessage?> and NEVER written to the DB; only
// the finalized message lands in the box on `agent_done`.

import 'dart:async';
import 'dart:math' as math;

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/data/sync/sync_events.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/stream_probe.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';
import 'package:flutter/foundation.dart';

class SyncService extends Service {
  final ConnectionManager _conn;
  final LocalBoxes _boxes;

  StreamSubscription<ConnectionStatus>? _connSub;
  StreamSubscription<ServerMessage>? _msgSub;
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  StreamSubscription<Map<String, PresenceState>>? _presenceSub;

  // Active session being written (follows ConnectionManager).
  String? _activeEpk;
  String _activeRoomId = 'main';

  // In-memory dedupe + ordering for the active session's msgs box. Rebuilt on
  // [activate]. Key = `<role>:<id>` so a user msg and the assistant reply that
  // shares its id don't collide.
  final Map<String, int> _idToSeq = {};
  int _nextSeq = 0;
  bool _indexLoaded = false;

  // Serialise box mutations so concurrent async writes stay ordered.
  Future<void> _writeChain = Future<void>.value();

  // Streaming — in-memory only (#7).
  final StringBuffer _chunkBuffer = StringBuffer();
  String _chunkReplyTo = '';
  Timer? _flushTimer;
  StreamingMessage? _streaming;
  final StreamController<StreamingMessage?> _streamingController =
      StreamController<StreamingMessage?>.broadcast();

  final StreamController<SessionEvent> _eventController =
      StreamController<SessionEvent>.broadcast();

  // Plan/100 — transient interactive extension prompts (ask_user via pi-ask).
  // Never persisted (live UI requests, not chat history); surfaced to the
  // ChatViewModel, which opens a full-screen modal.
  final StreamController<ExtensionUiRequest> _extensionUiController =
      StreamController<ExtensionUiRequest>.broadcast();

  // Plan/129 — durable current extension_ui_request (ask_user) for the active
  // session. The stream above is broadcast: an event fired with no
  // ChatViewModel mounted (app backgrounded, cold-start still on Home, or a
  // session_sync replay mid-reconnect) hits no listener and is lost. Holding
  // the current value here makes it the SSOT the ChatViewModel reads in its
  // `_compose`, so a request that arrived while no listener existed still
  // surfaces when the chat next opens.
  ExtensionUiRequest? _currentExtensionUiRequest;

  List<QueuedMsg> _queuedMessages = const [];
  final StreamController<List<QueuedMsg>> _queuedController =
      StreamController<List<QueuedMsg>>.broadcast();

  bool _pendingSyncRequest = false;
  Timer? _syncDebounce;

  // Plan/111 — track whether session history is truncated (server has more
  // messages than returned). Streamed to ChatViewModel for "Load more" UI.
  bool _truncated = false;
  final StreamController<bool> _truncatedController =
      StreamController<bool>.broadcast();
  // Plan/128 — backward paging via cursor. `_nextBefore` threads the server's
  // `next_before`; loadMore sends it as `before` to fetch the next older page.
  // `_truncated` (mirrored from the server's `has_more`) gates the UI affordance.
  static const int _loadMorePageSize = 500;
  String? _nextBefore;

  // Whether the active session's agent is currently producing a reply. Spans
  // the WHOLE turn (send/echo → agent_done), not just the token-streaming
  // window — restoring the old broad "working" signal. Mirrored into the
  // session index (durable, for Home) and exposed in-memory (for the chat
  // pill, no box-key matching needed).
  bool _working = false;
  bool _sawRemoteWorking = false;
  // Id of the user message the in-flight reply is answering — the `cancel`
  // target while working. Null when idle.
  String? _workingReplyTo;
  final StreamController<bool> _workingController =
      StreamController<bool>.broadcast();

  // Plan/32 safety net — if the relay never echoes a sent message back, the
  // optimistic `pending:true` bubble would spin forever. After this window we
  // remove the bubble SILENTLY (no "failed" state, no spinner). The real fix
  // lives in the relay; this is the app-side backstop. Per-message (`id`)
  // timers are armed only when a send is actually attempted online, and
  // cancelled on echo, user-cancel, session switch, and dispose.
  final Duration pendingSendTimeout;

  /// Plan/128 step 6 — optional on-device retention cap (rows/session).
  /// Default off (null): the box grows without bound (history is durable +
  /// append-only). When set (>0), each history merge trims the OLDEST rows
  /// (by ts; seq isn't chronological under backward paging) once the box
  /// exceeds cap+headroom, bounding storage for very long sessions. Resolved
  /// from `REMOTE_PI_LOCAL_HISTORY_MAX` at the wiring site
  /// (config/dependencies.dart). See plan/128 step 6.
  final int? localHistoryMax;

  /// Strategy fix (2026-08-21) — a session_sync reply can be silently
  /// DROPPED by the relay when the PC reconnects mid-request ("dest not
  /// found"); the app then sat on its stale cache forever. Every request is
  /// tracked by id and re-sent after [syncRetryDelay] until its terminal
  /// (eos) reply lands or attempts run out. History merges are idempotent
  /// (dedup by `<role>:<id>`), so duplicate replies are harmless.
  final Duration syncRetryDelay;

  static const int _syncRetryMax = 3;

  /// Safety valve for auto gap-fill: 20 pages × 500 = 10k events per
  /// catch-up chain before the manual "Load more" tile takes over.
  static const int _gapFillMaxPages = 20;
  int _gapFillPages = 0;
  final Map<String, _PendingSyncRequest> _pendingSyncs = {};
  Timer? _syncRetryTimer;

  final Map<String, Timer> _pendingSendTimers = {};

  SyncService(
    this._conn,
    this._boxes, {
    this.pendingSendTimeout = const Duration(seconds: 20),
    this.localHistoryMax,
    this.syncRetryDelay = const Duration(seconds: 6),
  }) {
    _connSub = _conn.statusStream.listen(_onStatus);
    _roomsSub = _conn.roomsStream.listen((_) {
      _writeRuntime();
      _syncTurnStateFromRoomMeta();
    });
    _presenceSub = _conn.presenceStream.listen((_) => _writeRuntime());
    _onStatus(_conn.status); // replay current
  }

  // ---------------------------------------------------------------------------
  // Public surface (commands + in-memory streams)
  // ---------------------------------------------------------------------------

  StreamingMessage? get streaming => _streaming;
  Stream<StreamingMessage?> get streamingStream => _streamingController.stream;
  Stream<SessionEvent> get events => _eventController.stream;

  /// Plan/100 — stream of interactive extension_ui_request prompts (ask_user
  /// via pi-ask). Transient: not written to the DB; the ChatViewModel renders
  /// a full-screen modal and replies via [respondExtensionUi].
  Stream<ExtensionUiRequest> get extensionUiRequestStream =>
      _extensionUiController.stream;

  /// Plan/129 — the current pending ask_user request for the active session
  /// (null when none / after the flow resolved). Durable SSOT — see
  /// [_currentExtensionUiRequest].
  ExtensionUiRequest? get currentExtensionUiRequest =>
      _currentExtensionUiRequest;
  List<QueuedMsg> get queuedMessages => _queuedMessages;
  String? get queuedText =>
      _queuedMessages.isEmpty ? null : _queuedMessages.first.text;
  Stream<List<QueuedMsg>> get queuedStream => _queuedController.stream;

  /// True while the active session's agent is producing a reply (whole turn).
  bool get isWorking => _working;
  Stream<bool> get workingStream => _workingController.stream;

  /// `cancel` target for the in-flight reply (null when idle).
  String? get workingReplyTo => _workingReplyTo;

  // Plan/111 — session history truncation state and "load more" support.
  bool get truncated => _truncated;
  Stream<bool> get truncatedStream => _truncatedController.stream;

  String? get activeEpk => _activeEpk;
  String get activeRoomId => _activeRoomId;

  /// Bind the writer to a (peer, room). Opens the box and rebuilds the
  /// dedupe/seq index from it. Called by the chat when it mounts / switches
  /// rooms; also adopted automatically on the first StatusOnline.
  Future<void> activate(String epk, String roomId) async {
    final room = roomId.isEmpty ? 'main' : roomId;
    if (_activeEpk == epk && _activeRoomId == room && _indexLoaded) return;
    // Genuine session switch: drop the in-memory turn state so the
    // PREVIOUS session's streaming buffer + whole-turn working flag can't
    // bleed into the next chat (the bug where chat 2 looked "working"
    // because chat 1 was mid-turn). We deliberately do NOT clear the
    // durable session index — the previous room may still be running on
    // the Pi, and Home keeps showing it via the relay's per-room
    // `meta.working` broadcast.
    _resetTurnState();
    // Plan/111 — reset truncation state on session switch.
    if (_truncated) {
      _truncated = false;
      _truncatedController.add(false);
    }
    _nextBefore = null;
    // Session switch: prior pending syncs belong to the old transcript.
    _pendingSyncs.clear();
    _gapFillPages = 0;
    _cancelSyncRetryTimer();
    _activeEpk = epk;
    _activeRoomId = room;
    await _loadIndex();
    _writeRuntime();
  }

  /// Clears the in-memory streaming buffer + whole-turn working flag
  /// (emitting the cleared state so listeners update) WITHOUT touching the
  /// durable session index. Used on a session switch — see [activate].
  void _resetTurnState() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _chunkBuffer.clear();
    _chunkReplyTo = '';
    _workingReplyTo = null;
    _sawRemoteWorking = false;
    _setQueuedMessages(const []);
    // Session switch: the previous chat's in-flight sends are no longer ours
    // to confirm — drop their backstops so a stale timer can't fire later.
    _cancelAllSendTimers();
    if (_streaming != null) _emitStreaming(null);
    if (_working) {
      _working = false;
      if (!_workingController.isClosed) _workingController.add(false);
    }
    // Plan/129 — a pending ask_user belongs to the session we just left; drop
    // it so it can't surface in the next chat. The new session's own request
    // (if any) arrives on its stream / session_sync replay.
    _currentExtensionUiRequest = null;
  }

  /// Plan/129 — apply an inbound [ExtensionUiRequest] to the durable current
  /// state (the SSOT the ChatViewModel reads). A `notify` whose id matches the
  /// open flow clears it on completion (info/absent type); a warning/error
  /// notify is a no-op here — the flow stays open for retry and the retry
  /// message is tracked in the ChatViewModel. Any other (interactive) request
  /// opens/replaces it. Unmatched stand-alone notifies are ignored in v1.
  void _handleExtensionUiRequest(ExtensionUiRequest req) {
    if (req.method == ExtensionUiMethod.notify) {
      final matchesOpen = _currentExtensionUiRequest != null &&
          req.id == _currentExtensionUiRequest!.id;
      if (matchesOpen) {
        final isWarning =
            req.notifyType == 'warning' || req.notifyType == 'error';
        if (!isWarning) {
          _currentExtensionUiRequest = null;
        }
      }
    } else {
      _currentExtensionUiRequest = req;
    }
  }

  Future<void> sendMessage(
    String text, {
    List<MessageImage>? images,
    UserMessageStreamingBehavior? streamingBehavior,
    ({String provider, String id})? model,
  }) async {
    final epk = _activeEpk;
    final id = _newId();
    final now = DateTime.now();
    final isSteer = streamingBehavior == UserMessageStreamingBehavior.steer;
    final isFollowUp = streamingBehavior == UserMessageStreamingBehavior.followUp;
    // Both steer and follow-up are sent while the room is busy and must NOT
    // start a fresh assistant turn / cursor (steer injects; follow-up queues).
    final isDeferred = isSteer || isFollowUp;
    // Plan/105 — the DB record + preview carry the FIRST image only (the DB
    // message row is single-image); the wire message carries all of them. The
    // relay echoes the full set, so the row is replaced with every image on echo.
    final first = images != null && images.isNotEmpty ? images.first : null;
    // Optimistic pending row (#defaults: optimistic + dedupe by id).
    if (epk != null) {
      await _upsert(
        MsgRole.user,
        id,
        (seq, _) => MessageRecord(
          id: id,
          seq: seq,
          role: MsgRole.user,
          text: text,
          image: first,
          ts: now,
          pending: true,
          steering: isSteer,
          followUp: isFollowUp,
        ),
      );
      if (!isDeferred) {
        _setWorking(true, preview: _preview(text, first), replyTo: id);
      }
      // Arm the no-echo backstop for this row. The timeout is keyed off the
      // row's `ts`, NOT online-ness: an offline "held pending" send is reaped
      // 20s after its ts too, and ANY pending row is re-armed on session load
      // (see _loadIndex). So a quick session-switch or an app restart still
      // reaps a stale bubble instead of letting it spin "sending…" forever.
      _armSendTimeout(id, now);
    }
    final ch = _conn.channel;
    if (ch == null) {
      debugPrint(
        '[msg-send] id=$id (offline → held pending, reaped in '
        '${pendingSendTimeout.inSeconds}s)',
      );
      return;
    }
    // Seed an EMPTY streaming buffer so the blinking cursor shows during the
    // "thinking" gap before the first agent_chunk (pre-31 behavior). In-memory
    // only (#7) — never written to the DB. agent_chunk appends; agent_done
    // clears it (even for a text-less, tool-only turn).
    // Steering/follow-up messages should not create a new cursor, because
    // they do not start a fresh assistant turn (steer injects; follow-up queues).
    if (!isDeferred) {
      _emitStreaming(StreamingMessage(inReplyTo: id));
    }
    debugPrint('[msg-send] id=$id text=${_preview(text, first)}');
    await ch.send(
      UserMessage(
        id: id,
        text: text,
        streamingBehavior: streamingBehavior,
        images: (images == null || images.isEmpty)
            ? null
            : images.map((i) => WireImage(data: i.data, mime: i.mime)).toList(),
        model: model,
      ),
    );
  }

  /// Arm (or re-arm) the silent no-echo backstop for a pending row, keyed by
  /// `id`. The window is the time REMAINING relative to the row's [ts], so a
  /// row loaded from disk already past [pendingSendTimeout] fires immediately
  /// (floored at zero). Idempotent — cancels any existing timer for `id`.
  void _armSendTimeout(String id, DateTime ts) {
    _pendingSendTimers.remove(id)?.cancel();
    final remaining = pendingSendTimeout - DateTime.now().difference(ts);
    _pendingSendTimers[id] = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      () => _onSendTimeout(id),
    );
  }

  /// No echo arrived within [pendingSendTimeout]: drop the optimistic bubble
  /// silently and unwind only the turn state that belongs to THIS `id`.
  void _onSendTimeout(String id) {
    _pendingSendTimers.remove(id);
    // ignore: discarded_futures
    _removeById(id);
    // Clear the thinking cursor only if it's seeded for this message.
    if (_streaming?.inReplyTo == id) _emitStreaming(null);
    // Clear working ONLY if this id owns it — never knock down a turn that a
    // different (echoed) message is already driving.
    if (_workingReplyTo == id) _setWorking(false);
    debugPrint(
      '[msg-timeout] id=$id removed (no echo in '
      '${pendingSendTimeout.inSeconds}s)',
    );
  }

  void _cancelAllSendTimers() {
    for (final t in _pendingSendTimers.values) {
      t.cancel();
    }
    _pendingSendTimers.clear();
  }

  /// Test seam — number of armed no-echo timers (asserts no leak on reset).
  @visibleForTesting
  int get debugPendingSendTimerCount => _pendingSendTimers.length;

  Future<void> queueMessage(String text) async {
    final ch = _conn.channel;
    if (ch == null) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final id = _newId();
    _setQueuedMessages([
      ..._queuedMessages,
      QueuedMsg(
        id: id,
        text: trimmed,
        editable: true,
        createdAt: DateTime.now(),
      ),
    ]);
    await ch.send(QueuedMessageSet(id: id, text: trimmed));
  }

  Future<void> setQueuedMessage(String text) => queueMessage(text);

  Future<void> clearQueuedMessage([String? targetId]) async {
    if (targetId == null) {
      _setQueuedMessages(const []);
    } else {
      _setQueuedMessages([
        for (final item in _queuedMessages)
          if (item.id != targetId) item,
      ]);
    }
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(QueuedMessageClear(id: _newId(), targetId: targetId));
  }

  Future<void> clearQueuedMessages() => clearQueuedMessage();

  Future<void> cancel(String targetId) async {
    // User-driven cancel of this message → disarm its no-echo backstop too.
    _pendingSendTimers.remove(targetId)?.cancel();
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(Cancel(id: _newId(), targetId: targetId));
  }

  /// Plan/100 — respond to an interactive extension_ui_request (ask_user).
  /// The ChatViewModel builds the [ExtensionUiResponse] (value/confirmed/
  /// cancelled + optional `ask` envelope); the SyncService just ships it.
  /// Returns false when there is no live channel or the send fails so the
  /// caller can surface a retryable failure immediately instead of waiting on
  /// the sheet's 25s backstop.
  Future<bool> respondExtensionUi(ExtensionUiResponse resp) async {
    final ch = _conn.channel;
    if (ch == null) return false;
    try {
      await ch.send(resp);
      return true;
    } catch (error) {
      debugPrint('[extension-ui] failed to send response: $error');
      return false;
    }
  }

  Future<void> approveTool(String toolCallId, ApproveDecision decision) async {
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(
      ApproveTool(id: _newId(), toolCallId: toolCallId, decision: decision),
    );
    await _upsert(MsgRole.tool, toolCallId, (seq, existing) {
      final base =
          existing?.tool ??
          ToolEventData(toolCallId: toolCallId, tool: 'unknown');
      return (existing ??
              MessageRecord(
                id: toolCallId,
                seq: seq,
                role: MsgRole.tool,
                ts: DateTime.now(),
              ))
          .copyWith(
            tool: base.copyWith(
              status: decision == ApproveDecision.allow
                  ? ToolEventStatus.allowed
                  : ToolEventStatus.denied,
            ),
          );
    });
  }

  /// Plan/128 — request session history. Normal sync asks for the newest page
  /// (limit omitted ⇒ the server serves its default, a few thousand); the
  /// durable append-only merge dedups on reconnect. `loadMore` pages OLDER
  /// history via the `before` cursor (threaded from the server's `next_before`),
  /// and is a no-op when there's no cursor or no more to load.
  void requestSync({bool loadMore = false}) {
    final ch = _conn.channel;
    if (ch == null || _activeEpk == null) {
      _pendingSyncRequest = true;
      return;
    }
    _pendingSyncRequest = false;

    if (loadMore) {
      if (_nextBefore == null) return; // nothing paged yet / no more to load
      _sendTrackedSync(
        ch,
        SessionSync(id: _newId(), limit: _loadMorePageSize, before: _nextBefore),
      );
    } else {
      _nextBefore = null; // newest page: discard any stale cursor
      _gapFillPages = 0; // newest chain restarts the gap-fill budget
      _sendTrackedSync(ch, SessionSync(id: _newId()));
    }
  }

  /// Sends [msg] on [ch] and arms the unanswered-request retry for its id.
  /// The send itself is guarded (see [_guardedSyncSend]): during teardown
  /// the ConnectionManager can still expose the old channel while close()
  /// is pending, and a rejection there would surface as an unhandled async
  /// error — instead the request simply stays tracked and the retry timer
  /// re-sends it on a healthy channel.
  void _sendTrackedSync(IChannel ch, SessionSync msg) {
    _pendingSyncs[msg.id] = _PendingSyncRequest(
      id: msg.id,
      limit: msg.limit,
      before: msg.before,
    );
    unawaited(_guardedSyncSend(ch, msg));
    _syncRetryTimer ??= Timer.periodic(
      syncRetryDelay,
      (t) => unawaited(_retryPendingSyncs(t)),
    );
  }

  /// Review #1 (PR #45) — a sync send on a channel that is mid-teardown can
  /// reject (close() races the exposed handle; WsTransport fails after
  /// signing). Swallow the rejection: the request is already tracked, so the
  /// retry timer owns recovery instead of the error surfacing unhandled.
  Future<void> _guardedSyncSend(IChannel ch, SessionSync msg) async {
    try {
      await ch.send(msg);
    } catch (_) {
      // Lost to teardown — leave tracked; retry re-sends on a live channel.
    }
  }

  /// Re-sends every session_sync that still has no terminal (eos) reply.
  /// Same id ⇒ the server re-serves the same page; the idempotent merge
  /// dedups whatever arrives twice. A send that rejects (teardown race)
  /// does NOT burn an attempt — the record stays pending for the next tick.
  Future<void> _retryPendingSyncs(Timer _) async {
    final ch = _conn.channel;
    if (ch == null) return; // offline: the reconnect flow re-syncs anyway
    final exhausted = <String>[];
    for (final entry in _pendingSyncs.entries.toList()) {
      final rec = entry.value;
      if (rec.attempts >= _syncRetryMax) {
        exhausted.add(entry.key);
        continue;
      }
      try {
        await ch.send(
          SessionSync(id: rec.id, limit: rec.limit, before: rec.before),
        );
        rec.attempts++;
      } catch (_) {
        // Channel died mid-close; next tick retries on whatever channel the
        // ConnectionManager exposes then.
      }
    }
    _pendingSyncs.removeWhere((id, _) => exhausted.contains(id));
    if (_pendingSyncs.isEmpty) _cancelSyncRetryTimer();
  }

  void _cancelSyncRetryTimer() {
    _syncRetryTimer?.cancel();
    _syncRetryTimer = null;
  }

  /// Strategy fix (2026-08-21) — "load ALL messages no matter how long the
  /// app was offline". A page that shares NO ids with the local box means
  /// the offline gap exceeds that page, so we keep auto-paging OLDER via the
  /// `before` cursor until a page overlaps history we already have (gap
  /// closed) or the cursor runs out. On a first-ever sync of a long session
  /// (empty box) this intentionally pages the whole transcript up to
  /// [_gapFillMaxPages] × 500 events; manual "Load more" extends beyond.
  void _maybeGapFill(
    SessionHistory h, {
    required bool hadOverlap,
    required bool wasLoadMore,
  }) {
    if (!wasLoadMore) _gapFillPages = 0;
    if (hadOverlap || h.nextBefore == null || h.events.isEmpty) return;
    if (_gapFillPages >= _gapFillMaxPages) return;
    _gapFillPages++;
    requestSync(loadMore: true);
  }

  /// Plan/28 — `session_new` acked: wipe the active session's rows + index.
  Future<void> clearActiveSession() async {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    // Session wiped → any optimistic sends/streaming/working state are moot.
    _cancelAllSendTimers();
    _discardStreamingState();
    _setQueuedMessages(const []);
    _setWorking(false);
    // Plan/111 — reset truncation state on session clear.
    if (_truncated) {
      _truncated = false;
      _truncatedController.add(false);
    }
    _nextBefore = null;
    await _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      await box.clear();
      _idToSeq.clear();
      _nextSeq = 0;
      _indexLoaded = true;
      final idx = _boxes.sessionsIndexBox();
      await idx.delete(LocalBoxes.sessionKey(epk, room));
    });
  }

  // ---------------------------------------------------------------------------
  // Channel → DB
  // ---------------------------------------------------------------------------

  void _onStatus(ConnectionStatus s) {
    _msgSub?.cancel();
    _msgSub = null;
    if (s is StatusOnline) {
      // Plan/32f — bind this stream's writes to the PEER that owns the
      // channel RIGHT NOW. After a `switchTo`, a late frame from the OLD
      // peer's channel must not land in the NEW session's box: `_activeEpk`
      // has already moved (the chat calls `activate()` before `switchTo`), so
      // a straggler chat-1 frame would otherwise be written to chat-2's box
      // and bleed across until chat-2's history re-applied. We capture the
      // origin epk here and drop frames whose origin is no longer active.
      //
      // We gate on epk only — NOT room: rooms of the same peer share one
      // channel and `_onStatus` doesn't re-fire on a same-peer room switch
      // (the transport already demuxes by room), so a room gate would wrongly
      // drop everything after switching cwds on the same Mac.
      final originEpk = _conn.activePeer?.remoteEpk;
      _msgSub = s.channel.serverMessages.listen(
        (msg) => _onServerMessage(msg, originEpk),
        onError: (Object _, StackTrace _) {},
      );
      // ignore: discarded_futures
      _onlineActivated();
    }
    _writeRuntime();
  }

  Future<void> _onlineActivated() async {
    final peer = _conn.activePeer;
    if (peer != null && _activeEpk == null) {
      await activate(peer.remoteEpk, _conn.activeRoomId);
    }
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 200), requestSync);
    if (_pendingSyncRequest) requestSync();
  }

  void _onServerMessage(ServerMessage msg, [String? originEpk]) {
    // Plan/32f — drop frames from a peer whose channel is no longer the active
    // session (a stale connection still draining after `switchTo`). Without
    // this, a straggler write targets `_activeEpk` — which already points at
    // the NEW chat — and bleeds the old session's messages into the new box.
    // Only gate when BOTH origin and active are set and differ: pre-bind
    // (`_activeEpk == null`, cold boot before `activate`) must still flow, and
    // direct test calls without an origin aren't gated.
    if (originEpk != null && _activeEpk != null && originEpk != _activeEpk) {
      return;
    }
    switch (msg) {
      case AgentChunk(:final inReplyTo, :final delta):
        StreamProbe.instance.chunk(inReplyTo, delta.length);
        _chunkBuffer.write(delta);
        _chunkReplyTo = inReplyTo;
        _flushTimer?.cancel();
        _flushTimer = Timer(const Duration(milliseconds: 16), _flushChunks);
        _setWorking(true, replyTo: inReplyTo);

      case AgentDone(:final inReplyTo):
        // Finalize whatever text accumulated since the last tool boundary.
        final text = _finalizeSegment();
        _clearSteeringLabel(inReplyTo);
        _setWorking(false, preview: text.isEmpty ? null : text);
        StreamProbe.instance.turnDone(inReplyTo);

      case AgentMessage(:final inReplyTo, :final text):
        // ignore: discarded_futures
        _upsert(
          MsgRole.assistant,
          inReplyTo,
          (seq, existing) =>
              existing ??
              MessageRecord(
                id: inReplyTo,
                seq: seq,
                role: MsgRole.assistant,
                text: text,
                ts: DateTime.now(),
              ),
        );

      case AgentImage(:final id, :final image, :final path, :final caption):
        // Plan/114 — agent-pushed image (show_image tool). Persist as an
        // assistant row carrying an image so it survives app restart; dedup
        // by the message id guards against rebroadcast. Caption rides in
        // `text`, the repo path in `imagePath` (viewer title).
        // ignore: discarded_futures
        _upsert(
          MsgRole.assistant,
          id,
          (seq, existing) =>
              existing ??
              MessageRecord(
                id: id,
                seq: seq,
                role: MsgRole.assistant,
                text: caption ?? '',
                image: MessageImage(data: image.data, mime: image.mime),
                imagePath: path,
                ts: DateTime.now(),
              ),
        );

      case AgentFile(
        :final id,
        :final kind,
        :final data,
        :final mime,
        :final path,
        :final caption,
        :final allowNetwork,
      ):
        // Plan/126 - agent-pushed document (show_file tool: md/text/pdf/html).
        // Persist as an assistant row carrying a file so it survives app
        // restart; dedup by the message id guards against rebroadcast. Caption
        // rides in `text`, the repo path in `imagePath` (viewer title).
        // ignore: discarded_futures
        _upsert(
          MsgRole.assistant,
          id,
          (seq, existing) =>
              existing ??
              MessageRecord(
                id: id,
                seq: seq,
                role: MsgRole.assistant,
                text: caption ?? '',
                file: MessageFile(
                  kind: kind,
                  data: data,
                  mime: mime,
                  allowNetwork: allowNetwork,
                ),
                imagePath: path,
                ts: DateTime.now(),
              ),
        );

      case QueuedMessageState(:final items):
        _setQueuedMessages([
          for (final item in items)
            QueuedMsg(
              id: item.id,
              text: item.text,
              editable: item.editable,
              createdAt: item.createdAt,
            ),
        ]);

      case SteerConsumed(:final id):
        _clearSteeringLabel(id);

      case UserInput(
        :final id,
        :final text,
        :final image,
        :final streamingBehavior,
      ):
        // Echo dedupes against the optimistic row (same id): confirm it
        // (pending=false) or insert as confirmed (foreign device).
        debugPrint('[msg-echo] id=$id');
        // Echo arrived → the send landed; disarm the no-echo backstop.
        _pendingSendTimers.remove(id)?.cancel();
        if (_queuedMessages.any((item) => item.id == id)) {
          _setQueuedMessages([
            for (final item in _queuedMessages)
              if (item.id != id) item,
          ]);
        }
        // ignore: discarded_futures
        _upsert(
          MsgRole.user,
          id,
          (seq, existing) => existing != null
              ? existing.copyWith(pending: false)
              : MessageRecord(
                  id: id,
                  seq: seq,
                  role: MsgRole.user,
                  text: text,
                  image: image == null
                      ? null
                      : MessageImage(data: image.data, mime: image.mime),
                  ts: DateTime.now(),
                  // Plan/127 — a foreign-device echo (no local optimistic
                  // row) must carry the delivery marker so every owner
                  // renders the same steer/follow-up bubble from the echoed
                  // streaming_behavior.
                  steering:
                      streamingBehavior == UserMessageStreamingBehavior.steer,
                  followUp:
                      streamingBehavior ==
                      UserMessageStreamingBehavior.followUp,
                ),
        );
        // Steering/follow-up input should not start/replace the working turn
        // bubble (steer injects into the running turn; follow-up queues behind
        // it — its own turn streams later, attributed to this id).
        if (streamingBehavior == UserMessageStreamingBehavior.steer ||
            streamingBehavior == UserMessageStreamingBehavior.followUp) {
          _setActivity(SessionActivity.working, preview: text);
        } else {
          _setWorking(true, preview: text, replyTo: id);
          // Show the thinking cursor for this turn (foreign-device echo, or the
          // local echo when the send-seed was already cleared). Guarded so it
          // never wipes a buffer that's already accumulating for this id.
          if (_streaming?.inReplyTo != id) {
            _emitStreaming(StreamingMessage(inReplyTo: id));
          }
        }

      case ToolRequest(:final toolCallId, :final tool, :final args):
        // Sequential ordering: close the current text segment as its own row
        // BEFORE the tool, so "narration → command → narration" renders in
        // order instead of all text landing after the commands.
        _finalizeSegment();
        // ignore: discarded_futures
        _upsert(
          MsgRole.tool,
          toolCallId,
          (seq, existing) =>
              existing ??
              MessageRecord(
                id: toolCallId,
                seq: seq,
                role: MsgRole.tool,
                ts: DateTime.now(),
                tool: ToolEventData(
                  toolCallId: toolCallId,
                  tool: tool,
                  args: args,
                ),
              ),
        );

      case ToolResult(:final toolCallId, :final result, :final error):
        // ignore: discarded_futures
        _upsert(MsgRole.tool, toolCallId, (seq, existing) {
          final base =
              existing?.tool ??
              ToolEventData(toolCallId: toolCallId, tool: 'unknown');
          return (existing ??
                  MessageRecord(
                    id: toolCallId,
                    seq: seq,
                    role: MsgRole.tool,
                    ts: DateTime.now(),
                  ))
              .copyWith(
                tool: base.copyWith(
                  status: error != null
                      ? ToolEventStatus.failed
                      : ToolEventStatus.completed,
                  result: result,
                  error: error,
                ),
              );
        });

      case Cancelled(:final targetId):
        _pendingSendTimers.remove(targetId)?.cancel();
        _discardStreamingState();
        // Cancel is stop-generation, not delete-history. Only drop a local
        // optimistic row that never got confirmed by the Pi echo; preserve
        // confirmed user/tool rows as the audit trail of what happened.
        // ignore: discarded_futures
        _removePendingById(targetId);
        _clearSteeringLabels();
        _setWorking(false);

      case Bye(:final rawReason):
        if (!_eventController.isClosed) {
          _eventController.add(PeerWentOffline(rawReason));
        }
        _clearSteeringLabels();
        _setWorking(false);
        final peer = _conn.activePeer;
        if (peer != null) {
          // ignore: discarded_futures
          _conn.switchTo(peer);
        }

      case SessionHistory():
        // Retry bookkeeping: the terminal frame (eos) answers the request.
        final rec = _pendingSyncs[msg.inReplyTo];
        if (msg.eos) {
          _pendingSyncs.remove(msg.inReplyTo);
          if (_pendingSyncs.isEmpty) _cancelSyncRetryTimer();
        }
        _applyHistory(msg, wasLoadMore: rec?.limit != null);

      case ErrorMessage(:final code, :final message):
        if (code.contains('unknown_peer')) {
          if (!_eventController.isClosed) {
            _eventController.add(const PairingRevoked());
          }
          break;
        }
        // PR #34 review — provider errors must not eat the streamed tail.
        // The last agent_chunk and this error can land inside the same 16ms
        // paint window; _discardStreamingState would cancel the flush timer
        // and silently drop it. Finalize like agent_done/tool boundaries do:
        // persist whatever text exists as an assistant row, then show the ⚠.
        _finalizeSegment();
        _clearSteeringLabels();
        _setWorking(false);
        // ignore: discarded_futures
        _upsert(
          MsgRole.assistant,
          _newId(),
          (seq, _) => MessageRecord(
            id: 'err_$seq',
            seq: seq,
            role: MsgRole.assistant,
            text: '⚠ $code: $message',
            ts: DateTime.now(),
          ),
        );

      case Compaction(:final summary, :final tokensBefore, :final ts):
        _writeCompaction(summary, tokensBefore, ts);

      case ExtensionUiRequest():
        // Plan/100/129 — update the durable current request (SSOT), then ping
        // live listeners. The cached value survives no-listener windows
        // (backgrounded / cold-start / mid-reconnect); the broadcast stream
        // alone does not.
        _handleExtensionUiRequest(msg);
        _extensionUiController.add(msg);
        break;
      case Pong():
      case PairOk():
      case PairError():
      case ActionOk():
      case ActionError():
      case ModelsList():
      // Plan/107 — git status replies are owned by ActionsRepository
      // (session-info dialog), not the message sync.
      case GitStatusResult():
      // Plan/108 — terminal-launch replies are owned by ActionsRepository
      // (quick action / session menu), not the message sync.
      case OpenTerminalResult():
      // Plan/112 — worktree tracking replies are owned by ActionsRepository
      // (session-info dialog), not the message sync.
      case ListWorktreesResult():
      case RemoveWorktreeResult():
      // Plan/121 — discovered projects reply is owned by ActionsRepository
      // (Projects screen), not the message sync.
      case ListProjectsResult():
      // api.changeLayout — orchestrate reply is owned by ActionsRepository
      // (Quick Actions), not the message sync.
      case ChangeLayoutResult():
      // Plan/124 — start-session (revive) reply is owned by ActionsRepository
      // (Home session menu), not the message sync.
      case StartSessionResult():
        break;
    }
  }

  /// Plan/32 — persist a compaction as a system row so it renders a system
  /// bubble in the chat and survives a re-sync. Keyed by `ts` when present so
  /// the live message and its history replay collapse to one row.
  void _writeCompaction(String summary, int? tokensBefore, int? ts) {
    final id = 'compaction_${ts ?? uuid7()}';
    final when = ts != null
        ? DateTime.fromMillisecondsSinceEpoch(ts)
        : DateTime.now();
    // ignore: discarded_futures
    _upsert(
      MsgRole.compaction,
      id,
      (seq, existing) =>
          existing ??
          MessageRecord(
            id: id,
            seq: seq,
            role: MsgRole.compaction,
            text: summary,
            tokensBefore: tokensBefore,
            ts: when,
          ),
    );
  }

  Future<void> _applyHistory(SessionHistory h, {bool wasLoadMore = false}) async {
    final epk = _activeEpk;
    if (epk == null) return;
    // Plan/111/128 — track truncation (mirrors the server's `has_more`) and
    // thread the backward-paging cursor for `loadMore`.
    if (h.truncated != _truncated) {
      _truncated = h.truncated;
      _truncatedController.add(_truncated);
    }
    _nextBefore = h.nextBefore;
    final room = _activeRoomId;
    final rows = _convertHistory(h.events);
    final started = h.sessionStartedAt;
    await _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      // Safety net: never merge before the dedupe index is loaded from the
      // box, or every existing row would look "new" and re-append as a
      // duplicate. `_loadIndex` (via activate) always runs first on the
      // serialized write chain, so this only guards an out-of-order frame.
      if (!_indexLoaded) {
        debugPrint('[history] drop frame: index not loaded yet');
        return;
      }
      final box = await _boxes.msgsBox(epk, room);
      // Strategy fix (2026-08-21): overlap vs PRE-merge local state decides
      // auto gap-fill after the merge (see _maybeGapFill).
      final hadOverlap = rows.any(
        (r) => _idToSeq.containsKey(_key(r.role, r.id)),
      );

      // Plan/128 — durable append-only merge. The box is NO LONGER a
      // substitutive mirror of the server's in-memory buffer. Each history
      // row is merged by `<role>:<id>`: a row new to this box appends at
      // `_nextSeq`; a row we already have is left untouched (its local content
      // is at least as rich as the replay — tool results, follow-up/steer
      // flags — so we never downgrade it). NOTHING is deleted on a
      // same-session sync.
      //
      // This fixes two symptoms at once:
      //  - "disappears offline / after Pi restart": an empty server history
      //    (buffer wiped by a process restart) used to delete every local row;
      //    now an empty `events` list with an unchanged session is a no-op.
      //  - "only the latest 30": rows that scrolled off the server window are
      //    kept locally instead of being reaped on the next reconnect.
      //
      // The ONLY path that clears the box is a genuine session change
      // (`session_started_at` differs from the one we persisted for this
      // (epk, room) and is non-zero — a fresh conversation). A `0` value means
      // a legacy/no-session Pi: treat as "nothing new", never wipe.
      // Plan/128 (review C1) — DON'T wipe on a bare session_started_at change:
      // a Pi PROCESS RESTART restamps it (Date.now()) even though the SAME
      // transcript is resumed, which would discard already-loaded history —
      // the core durability scenario. Treat it as a new session only when the
      // incoming page is also CONTENT-DISJOINT from local (no id overlap ⇒ not
      // a restart re-send) AND it's a newest-page sync (a backward loadMore's
      // older rows are disjoint by id but are the same session, excluded by
      // ts). A restart re-sends rows we already have ⇒ overlap ⇒ no wipe.
      var isNewSession = started != 0 &&
          _storedSessionStartedAtDiffers(epk, room, started) &&
          _idToSeq.isNotEmpty;
      if (isNewSession) {
        final overlaps =
            rows.any((r) => _idToSeq.containsKey(_key(r.role, r.id)));
        if (overlaps) {
          isNewSession = false;
        } else {
          // A loadMore page is disjoint by id but is the same session; its max
          // ts is strictly older than the local box's newest — exclude it.
          int? localMax;
          for (final k in box.keys) {
            final t = MessageRecord.fromJson(_coerce(box.get(k)))
                .ts
                .millisecondsSinceEpoch;
            if (localMax == null || t > localMax) localMax = t;
          }
          final incomingMax = rows.fold<int>(
            0,
            (m, r) {
              final t = r.ts.millisecondsSinceEpoch;
              return t > m ? t : m;
            },
          );
          if (localMax != null && incomingMax < localMax) isNewSession = false;
        }
      }
      if (isNewSession) {
        await box.clear();
        _idToSeq.clear();
        _nextSeq = 0;
      }

      for (final row in rows) {
        final mapKey = _key(row.role, row.id);
        final existingSeq = _idToSeq[mapKey];
        if (existingSeq == null) {
          // New to this box → append. `_nextSeq` is a monotonic storage
          // identity; it stays chronological for the initial sync + live
          // appends (the only paths in this step). Backward paging
          // (plan/128 step 5) will switch display ordering to `ts` so older
          // pages can slot in correctly.
          final seq = _nextSeq++;
          _idToSeq[mapKey] = seq;
          await box.put(seq, row.copyWith(seq: seq).toJson());
        } else {
          // Already have it. History doesn't carry pending/follow-up/steer,
          // so keep the local row verbatim — only confirm delivery if it was a
          // pending user send the Pi has now echoed back, or complete a tool
          // row whose request/result arrived in separate pages (review C5).
          final curRaw = box.get(existingSeq);
          if (curRaw == null) {
            await box.put(existingSeq, row.copyWith(seq: existingSeq).toJson());
            continue;
          }
          final existing = MessageRecord.fromJson(_coerce(curRaw));
          if (existing.pending && !row.pending) {
            _pendingSendTimers.remove(row.id)?.cancel();
            await box.put(
              existingSeq,
              existing.copyWith(pending: false).toJson(),
            );
          } else if (existing.role == MsgRole.tool &&
              row.role == MsgRole.tool) {
            // Plan/128 (review C5) — a tool_request and its tool_result can
            // split across cursor pages (a result-only page makes an 'unknown'
            // tool row). Merge whichever side is missing so the persisted tool
            // event ends up complete (name/args + status/result/error).
            final merged = _mergeTool(existing, row);
            if (merged != null) {
              await box.put(existingSeq, existing.copyWith(tool: merged).toJson());
            }
          }
        }
      }
      // Plan/128 step 6 — optional local retention cap. Trim the OLDEST rows
      // (by ts; seq isn't chronological under backward paging) once the box
      // exceeds cap+headroom, down to `cap`. Hysteresis (cap+headroom trigger,
      // cap floor) avoids evicting on every single merge. Default off (null)
      // ⇒ the box grows without bound. Cost is O(N log N) with N = box.length,
      // and only runs when over the trigger, so steady-state merges skip it.
      final cap = localHistoryMax;
      if (cap != null &&
          cap > 0 &&
          box.length > cap + _retentionHeadroom(cap)) {
        final byTs = <MapEntry<int, DateTime>>[];
        for (final k in box.keys) {
          final seq = (k as num).toInt();
          byTs.add(
            MapEntry(seq, MessageRecord.fromJson(_coerce(box.get(k))).ts),
          );
        }
        byTs.sort((a, b) {
          final t = a.value.compareTo(b.value);
          return t != 0 ? t : a.key.compareTo(b.key);
        });
        final evictCount = box.length - cap;
        final victims = <int>{};
        for (final e in byTs.take(evictCount)) {
          victims.add(e.key);
          await box.delete(e.key);
        }
        // Drop dedupe entries pointing at evicted seqs so a later re-sync of
        // an evicted id re-appends cleanly instead of resurrecting at a stale
        // (now-vacant) seq.
        _idToSeq.removeWhere((_, seq) => victims.contains(seq));
      }
      _indexLoaded = true;
      _maybeGapFill(h, hadOverlap: hadOverlap, wasLoadMore: wasLoadMore);
    });
    if (_activeEpk == epk && _activeRoomId == room) {
      _updateIndex(
        (cur) => cur.copyWith(
          sessionStartedAt: DateTime.fromMillisecondsSinceEpoch(started),
        ),
      );
    }
  }

  /// Plan/128 — true if the session we persisted for `(epk, room)` has a
  /// different `session_started_at` than [started] (i.e. a new conversation
  /// started on the Pi). Sync read of the index box. False when nothing is
  /// stored yet (first sync) — the first contact never clears.
  bool _storedSessionStartedAtDiffers(String epk, String room, int started) {
    final raw = _boxes.sessionsIndexBox().get(LocalBoxes.sessionKey(epk, room));
    if (raw is! Map) return false;
    final stored = SessionIndexRecord.fromJson(
      raw.cast<String, dynamic>(),
    ).sessionStartedAt;
    return stored != null && stored.millisecondsSinceEpoch != started;
  }

  /// Hysteresis headroom for the retention cap (plan/128 step 6): evict only
  /// once the box exceeds `cap + headroom`, then trim down to `cap`. 10% of
  /// cap (min 1) so steady-state merges don't evict one row at a time.
  static int _retentionHeadroom(int cap) => math.max(1, cap ~/ 10);

  /// Plan/128 (review C5) — combine a tool_request and tool_result that arrived
  /// in separate cursor pages into one complete row: name/args from the
  /// request, status/result/error from the result. Returns null when the local
  /// row is already at least as complete (no write needed).
  ToolEventData? _mergeTool(MessageRecord a, MessageRecord b) {
    final ta = a.tool;
    final tb = b.tool;
    if (ta == null || tb == null) return null;
    bool hasName(ToolEventData t) => t.tool != 'unknown' && t.tool.isNotEmpty;
    final nameSrc = hasName(ta) ? ta : (hasName(tb) ? tb : ta);
    final args = ta.args ?? tb.args;
    final bDone = tb.status == ToolEventStatus.completed ||
        tb.status == ToolEventStatus.failed;
    // Prefer the completed side for status/result/error; falls back to `ta`.
    final status = bDone ? tb.status : ta.status;
    final result = bDone ? tb.result : ta.result;
    final error = bDone ? tb.error : ta.error;
    if (nameSrc.tool == ta.tool &&
        args == ta.args &&
        status == ta.status &&
        result == ta.result &&
        error == ta.error) {
      return null; // local row already complete; no write
    }
    return ToolEventData(
      toolCallId: ta.toolCallId,
      tool: nameSrc.tool,
      args: args,
      status: status,
      result: result,
      error: error,
    );
  }

  List<MessageRecord> _convertHistory(List<SessionHistoryEvent> events) {
    final out = <MessageRecord>[];
    var seq = 0;
    for (final e in events) {
      switch (e) {
        case UserInputEvt(:final id, :final text, :final image):
          out.add(
            MessageRecord(
              id: id,
              seq: seq++,
              role: MsgRole.user,
              text: text,
              image: image == null
                  ? null
                  : MessageImage(data: image.data, mime: image.mime),
              ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
            ),
          );
        case AgentMessageEvt(:final inReplyTo, :final text):
          out.add(
            MessageRecord(
              id: inReplyTo,
              seq: seq++,
              role: MsgRole.assistant,
              text: text,
              ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
            ),
          );
        case ToolRequestEvt(:final toolCallId, :final tool, :final args):
          out.add(
            MessageRecord(
              id: toolCallId,
              seq: seq++,
              role: MsgRole.tool,
              ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
              tool: ToolEventData(
                toolCallId: toolCallId,
                tool: tool,
                args: args,
              ),
            ),
          );
        case ToolResultEvt(:final toolCallId, :final result, :final error):
          final idx = out.lastIndexWhere(
            (m) => m.role == MsgRole.tool && m.tool?.toolCallId == toolCallId,
          );
          final status = error != null
              ? ToolEventStatus.failed
              : ToolEventStatus.completed;
          if (idx >= 0) {
            out[idx] = out[idx].copyWith(
              tool: out[idx].tool!.copyWith(
                status: status,
                result: result,
                error: error,
              ),
            );
          } else {
            out.add(
              MessageRecord(
                id: toolCallId,
                seq: seq++,
                role: MsgRole.tool,
                ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
                tool: ToolEventData(
                  toolCallId: toolCallId,
                  tool: 'unknown',
                  status: status,
                  result: result,
                  error: error,
                ),
              ),
            );
          }
        case CompactionEvt(:final summary, :final tokensBefore):
          out.add(
            MessageRecord(
              id: 'compaction_${e.ts}',
              seq: seq++,
              role: MsgRole.compaction,
              text: summary,
              tokensBefore: tokensBefore,
              ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
            ),
          );
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Box write helpers (all serialised through _enqueue)
  // ---------------------------------------------------------------------------

  String _key(MsgRole role, String id) => '${role.name}:$id';

  Future<void> _loadIndex() {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      _idToSeq.clear();
      _nextSeq = 0;
      for (final k in box.keys) {
        final seq = (k as num).toInt();
        final r = MessageRecord.fromJson(_coerce(box.get(k)));
        _idToSeq[_key(r.role, r.id)] = seq;
        _nextSeq = math.max(_nextSeq, seq + 1);
        // Re-arm the no-echo backstop for any pending row this session owns, so
        // a bubble persisted across an app restart / quick session-switch is
        // reaped by its `ts` instead of spinning forever (already-stale → fires
        // immediately). Timers were cleared by _resetTurnState before this load.
        if (r.role == MsgRole.user && r.pending) _armSendTimeout(r.id, r.ts);
      }
      _indexLoaded = true;
    });
  }

  Future<void> _upsert(
    MsgRole role,
    String id,
    MessageRecord Function(int seq, MessageRecord? existing) build,
  ) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      final active = _activeEpk == epk && _activeRoomId == room;
      if (!active) return;
      final box = await _boxes.msgsBox(epk, room);
      final mapKey = _key(role, id);
      final existingSeq = _idToSeq[mapKey];
      if (existingSeq != null) {
        final existing = MessageRecord.fromJson(_coerce(box.get(existingSeq)));
        await box.put(existingSeq, build(existingSeq, existing).toJson());
      } else {
        final seq = _nextSeq++;
        await box.put(seq, build(seq, null).toJson());
        _idToSeq[mapKey] = seq;
      }
    });
  }

  Future<void> _removeById(String id) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      for (final role in MsgRole.values) {
        final seq = _idToSeq.remove(_key(role, id));
        if (seq != null) await box.delete(seq);
      }
    });
  }

  void _clearSteeringLabel(String id) {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    // ignore: discarded_futures
    _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      final seq = _idToSeq[_key(MsgRole.user, id)];
      if (seq == null) return;
      final raw = box.get(seq);
      if (raw == null) return;
      final existing = MessageRecord.fromJson(_coerce(raw));
      if (existing.role != MsgRole.user || !existing.steering) return;
      await box.put(seq, existing.copyWith(steering: false).toJson());
    });
  }

  void _clearSteeringLabels() {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    // ignore: discarded_futures
    _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      for (final key in box.keys.toList()) {
        final raw = box.get(key);
        if (raw == null) continue;
        final existing = MessageRecord.fromJson(_coerce(raw));
        if (existing.role != MsgRole.user || !existing.steering) continue;
        await box.put(
          (key as num).toInt(),
          existing.copyWith(steering: false).toJson(),
        );
      }
    });
  }

  Future<void> _removePendingById(String id) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      for (final role in MsgRole.values) {
        final key = _key(role, id);
        final seq = _idToSeq[key];
        if (seq == null) continue;
        final raw = box.get(seq);
        if (raw == null) {
          _idToSeq.remove(key);
          continue;
        }
        final existing = MessageRecord.fromJson(_coerce(raw));
        if (!existing.pending) continue;
        _idToSeq.remove(key);
        await box.delete(seq);
      }
    });
  }

  void _setActivity(SessionActivity status, {String? preview}) {
    _updateIndex(
      (cur) => cur.copyWith(
        status: status,
        lastMessageAt: preview != null ? DateTime.now() : null,
        lastMessagePreview: preview,
      ),
    );
  }

  void _setQueuedMessages(List<QueuedMsg> items) {
    final next = List<QueuedMsg>.unmodifiable(items);
    if (_queuedMessages == next) return;
    _queuedMessages = next;
    if (!_queuedController.isClosed) _queuedController.add(next);
  }

  /// Single source of "the active session is working". Drives the in-memory
  /// flag/stream (chat pill) AND the durable session index (Home dot).

  void _syncTurnStateFromRoomMeta() {
    final epk = _activeEpk;
    if (epk == null) return;
    final remoteWorking = _conn.isRoomWorking(epk, _activeRoomId);
    if (remoteWorking) {
      _sawRemoteWorking = true;
      return;
    }
    if (_sawRemoteWorking && _working) {
      _discardStreamingState();
      _setWorking(false);
    }
    _sawRemoteWorking = false;
  }

  void _setWorking(bool on, {String? preview, String? replyTo}) {
    _setActivity(
      on ? SessionActivity.working : SessionActivity.idle,
      preview: preview,
    );
    // Snapshot nullable field once; Dart won't promote mutable fields safely.
    final epk = _activeEpk;
    if (epk != null) {
      _conn.markRoomWorking(epk, _activeRoomId, on);
    }
    if (on) {
      if (replyTo != null) _workingReplyTo = replyTo;
    } else {
      _workingReplyTo = null;
      _sawRemoteWorking = false;
    }
    if (_working == on) return;
    _working = on;
    if (!_workingController.isClosed) _workingController.add(on);
  }

  void _updateIndex(SessionIndexRecord Function(SessionIndexRecord cur) build) {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    // ignore: discarded_futures
    _enqueue(() async {
      final idx = _boxes.sessionsIndexBox();
      final key = LocalBoxes.sessionKey(epk, room);
      final raw = idx.get(key);
      final cur = raw is Map
          ? SessionIndexRecord.fromJson(raw.cast<String, dynamic>())
          : SessionIndexRecord(epk: epk, roomId: room);
      await idx.put(key, build(cur).toJson());
    });
  }

  void _writeRuntime() {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    final s = _conn.status;
    final conn = switch (s) {
      StatusOnline() => RuntimeConnection.online,
      StatusConnecting() => RuntimeConnection.connecting,
      StatusRetrying() => RuntimeConnection.retrying,
      StatusOffline() => RuntimeConnection.offline,
      StatusNoPeer() => RuntimeConnection.connecting,
    };
    final presence = (s is StatusOnline && _conn.isRoomLive(epk, room))
        ? RuntimePresence.alive
        : (s is StatusOnline ? RuntimePresence.stale : RuntimePresence.unknown);
    // ignore: discarded_futures
    _enqueue(() async {
      _boxes.runtimeBox().put(
        LocalBoxes.sessionKey(epk, room),
        RuntimeRecord(connection: conn, presence: presence).toJson(),
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Streaming (in-memory only)
  // ---------------------------------------------------------------------------

  void _flushChunks() {
    if (_chunkBuffer.isEmpty) return;
    final delta = _chunkBuffer.toString();
    _chunkBuffer.clear();
    final cur = _streaming;
    if (cur != null && cur.inReplyTo == _chunkReplyTo) {
      _emitStreaming(cur.appendDelta(delta));
    } else {
      _emitStreaming(StreamingMessage(inReplyTo: _chunkReplyTo, buffer: delta));
    }
    StreamProbe.instance.emitted();
  }

  /// Persist the accumulated streaming text as a standalone assistant row
  /// (unique id, in chronological seq order) and clear the live cursor.
  /// Called at every tool boundary AND on agent_done so text/tool/text
  /// renders sequentially. No-op (just clears the cursor) when there's no
  /// text — so a tool-only or empty turn never leaves a blank bubble.
  /// Returns the finalized text (empty if none).
  String _finalizeSegment() {
    // Drain any coalesced delta still sitting in the 16ms buffer.
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_chunkBuffer.isNotEmpty) {
      final delta = _chunkBuffer.toString();
      _chunkBuffer.clear();
      final cur = _streaming;
      _streaming = (cur != null && cur.inReplyTo == _chunkReplyTo)
          ? cur.appendDelta(delta)
          : StreamingMessage(inReplyTo: _chunkReplyTo, buffer: delta);
    }
    final text = _streaming?.buffer ?? '';
    if (text.isNotEmpty) {
      final id = 'agent_${uuid7()}';
      // ignore: discarded_futures
      _upsert(
        MsgRole.assistant,
        id,
        (seq, _) => MessageRecord(
          id: id,
          seq: seq,
          role: MsgRole.assistant,
          text: text,
          ts: DateTime.now(),
        ),
      );
    }
    _chunkReplyTo = '';
    _emitStreaming(null);
    return text;
  }

  void _discardStreamingState() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _chunkBuffer.clear();
    _chunkReplyTo = '';
    _emitStreaming(null);
  }

  void _emitStreaming(StreamingMessage? s) {
    _streaming = s;
    if (!_streamingController.isClosed) _streamingController.add(s);
  }

  // ---------------------------------------------------------------------------

  Future<void> _enqueue(Future<void> Function() op) {
    final next = _writeChain.then((_) => op());
    _writeChain = next.catchError((Object _, StackTrace _) {});
    return next;
  }

  static Map<String, dynamic> _coerce(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return raw.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  static String _preview(String text, MessageImage? image) {
    if (text.isEmpty && image != null) return '📷 Image';
    return text.length <= 80 ? text : '${text.substring(0, 80)}…';
  }

  static String _newId() => 'cli_${uuid7()}';

  @override
  void dispose() {
    _flushTimer?.cancel();
    _syncDebounce?.cancel();
    _cancelSyncRetryTimer();
    _cancelAllSendTimers();
    _connSub?.cancel();
    _msgSub?.cancel();
    _roomsSub?.cancel();
    _presenceSub?.cancel();
    _streamingController.close();
    _eventController.close();
    _extensionUiController.close();
    _workingController.close();
    _queuedController.close();
    _truncatedController.close();
  }
}

/// Strategy fix (2026-08-21) — an in-flight session_sync awaiting its
/// terminal (eos) reply, tracked for re-send when the reply is lost to a
/// relay drop / PC reconnect. `limit != null` marks a backward (loadMore)
/// page, which the gap-fill logic treats differently from a newest page.
class _PendingSyncRequest {
  final String id;
  final int? limit;
  final String? before;
  int attempts = 0;

  _PendingSyncRequest({required this.id, this.limit, this.before});
}
