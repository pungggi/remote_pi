import 'dart:async';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/notifications/local_notifications.dart';
import 'package:app/data/notifications/session_completion_notifications.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/protocol/protocol.dart';

/// Plan/134 — "Pi is waiting for input at the terminal" notifications.
/// Plan/141 — snapshot-on-background + cancel-on-clear + permission ask.
///
/// The generic phone-side signal for ANY blocking user-facing `ctx.ui`
/// prompt (pi 0.84.4 `ui_prompt_start`/`end`): pi-ask's `ask_user` AND
/// every foreign extension's `confirm`/`select`/`input`/`editor`/`custom`.
/// Without it, a foreign prompt just looks like the agent "working" —
/// the user has no idea that walking to the terminal (or answering in the
/// app) is the unblocking action.
///
/// Gates (plan/141 revision):
/// 1. **rising edge while backgrounded** — [WaitingForInputEvent]s are
///    transitions emitted by [ConnectionManager] from live
///    `room_meta_updated` frames; app-open replays (`room_announced` /
///    `rooms` snapshots) never produce one, so a reconnecting app cannot
///    re-fire a banner;
///    **plus the background snapshot** — `setBackgrounded(true)` re-checks
///    every live waiting room ([liveWaitingRooms]) so the common flow
///    "dot appeared while I was looking, THEN I pocketed the phone" also
///    notifies (plan/141 gap 1). Same stable id per room ⇒ a snapshot
///    banner REPLACES a transition banner, never stacks;
/// 2. **pi-ask sheet dedupe** — when an `extension_ui_request` answer
///    sheet is already open for that room ([hasOpenAskSheet]), the sheet
///    IS the signal; suppressing the generic banner avoids a double
///    alert. Foreign prompts (no sheet) always notify — this banner is
///    their only signal;
/// 3. **notification permission granted** — and while the app is
///    FOREGROUNDED, the first waiting edge without an open sheet asks
///    for the permission ONCE per install (durable `permission_asked`
///    flag) — the activity is resumed there, so the OS dialog can show
///    (plan/141 gap 2: previously nothing ever asked unless the keep-alive
///    service happened to start).
///
/// **Falling edges cancel** (plan/141 gap 3): when the prompt is answered
/// — in the app, at the terminal, or by a run abort — the room's banner
/// is removed from the tray so it can't outlive the wait it described.
///
/// Unlike plan/132 there is no per-session opt-in: waiting-for-input is
/// an action-required state, not a convenience signal — the plan calls
/// for notifying every backgrounded room.
///
/// Banner payload stays generic (session title + fixed body); no prompt
/// content ever travels in the notification. Same process-lifetime
/// honesty limit as plan/132: it fires while the plan/103 keep-alive
/// service holds the relay WS in background, it is NOT push.
///
/// Not a [ChangeNotifier] (unlike the plan/132 facade): there is no
/// per-session toggle surface to watch — nothing ever listens to this
/// class; it only subscribes.
class WaitingInputNotifications implements Service {
  /// Durable key in the `notify_prefs` box — `true` once the proactive
  /// POST_NOTIFICATIONS ask (plan/141) has been made on this install.
  /// Denied users re-enable via Settings → Session alerts; the flag
  /// prevents the facade from ever re-nagging unbidden.
  static const String _kPermissionAsked = 'permission_asked';

  final LocalBoxes _boxes;
  final LocalNotifications _local;

  /// Session display-name resolver for the banner title (wired in
  /// bootstrap to [SessionCompletionNotifications.roomTitleFor] — the
  /// same resolver the completion banner uses).
  String? Function(String epk, String roomId)? roomTitle;

  /// Plan/134 dedupe rule — `true` when an `extension_ui_request` answer
  /// sheet is already open for `(epk, roomId)` (wired in bootstrap to the
  /// SyncService's pending pi-ask request for the ACTIVE session). The
  /// sheet is itself the signal; the generic banner stays silent.
  bool Function(String epk, String roomId)? hasOpenAskSheet;

  /// Plan/141 — live waiting rooms as `(epk, roomId)` records (wired in
  /// bootstrap over `ConnectionManager.roomsSnapshot` +
  /// `isRoomWaitingForInput`, which already gates on `StatusOnline` and
  /// `_liveRoomIds`). Drives the background snapshot so a wait that
  /// STARTED in the foreground still notifies once the user leaves.
  /// Null/empty (tests, early boot) simply skips the snapshot.
  List<({String epk, String roomId})> Function()? liveWaitingRooms;

  WaitingInputNotifications({
    required LocalBoxes boxes,
    required LocalNotifications local,
  }) : _boxes = boxes,
       _local = local;

  StreamSubscription<WaitingForInputEvent>? _sub;
  bool _backgrounded = false;
  bool _disposed = false;

  /// Serializes the proactive permission ask so two near-simultaneous
  /// rising edges can't surface the OS dialog twice.
  bool _askInFlight = false;

  /// Subscribe to waiting-for-input transitions. Wired in bootstrap to
  /// `ConnectionManager.waitingForInputStream`.
  void attach(Stream<WaitingForInputEvent> stream) {
    _sub?.cancel();
    _sub = stream.listen(_onWaiting);
  }

  /// Driven from `didChangeAppLifecycleState`: `true` while the app is
  /// NOT resumed. On the foreground→background transition it re-checks
  /// every live waiting room (plan/141 snapshot) — the dot the user just
  /// saw on the tile becomes a banner the moment they pocket the phone.
  void setBackgrounded(bool backgrounded) {
    _backgrounded = backgrounded;
    if (backgrounded && !_disposed) {
      // ignore: unawaited_futures
      _snapshotWaitingRooms();
    }
  }

  Future<void> _onWaiting(WaitingForInputEvent e) async {
    if (_disposed) return;
    // Plan/141 — falling edge clears the room's banner from the tray,
    // regardless of foreground/background: a banner fired earlier while
    // backgrounded must not outlive the answered prompt.
    if (!e.waiting) {
      await _local.cancel(_notificationId(e.epk, e.roomId));
      return;
    }
    // Gate 1 — only worth a banner when the user is not looking at the app.
    if (!_backgrounded) {
      // Plan/141 — foreground rising edge: the banner stays suppressed
      // (tiles show the badge), but this is the ONE moment the OS dialog
      // can actually show — ask for the permission once per install.
      await _maybeAskPermission(e.epk, e.roomId);
      return;
    }
    // Gate 2 — pi-ask sheet already open for this room: the sheet is the
    // signal, a second banner would be noise. Foreign prompts have no
    // sheet, so they always pass through (this banner is their only signal).
    if (hasOpenAskSheet?.call(e.epk, e.roomId) ?? false) return;
    // Gate 3 — permission.
    if (!await _local.hasPermission()) return;
    await _show(e.epk, e.roomId);
  }

  /// Plan/141 snapshot — notify for every room that is waiting RIGHT NOW
  /// as the app goes to the background, except the one whose sheet is
  /// open (the user is mid-answer there). Same-id `show` replaces any
  /// transition-fired banner, so a lifecycle flap (inactive→paused) can
  /// never stack duplicates.
  Future<void> _snapshotWaitingRooms() async {
    final rooms = liveWaitingRooms?.call() ?? const [];
    if (rooms.isEmpty) return;
    if (!await _local.hasPermission()) return;
    for (final r in rooms) {
      if (_disposed) return;
      if (hasOpenAskSheet?.call(r.epk, r.roomId) ?? false) continue;
      await _show(r.epk, r.roomId);
    }
  }

  /// Plan/141 — proactive POST_NOTIFICATIONS ask: once per install, at
  /// the first foreground waiting edge with no sheet open. Never
  /// interrupts an in-progress answer (sheet check); never re-asks after
  /// the first attempt (durable flag); a denial is recoverable via the
  /// Settings → Session alerts row.
  Future<void> _maybeAskPermission(String epk, String roomId) async {
    if (_askInFlight) return;
    // Sheet open — don't overlay the OS dialog on the answer the user is
    // giving; a later edge (or the next wait) retries.
    if (hasOpenAskSheet?.call(epk, roomId) ?? false) return;
    final box = _boxes.notifyPrefsBox();
    if (box.get(_kPermissionAsked) == true) return;
    _askInFlight = true;
    try {
      if (await _local.hasPermission()) {
        // Nothing to ask — remember that too, so the check never runs
        // again on this install.
        await box.put(_kPermissionAsked, true);
        return;
      }
      // Set the flag BEFORE the await so a second concurrent edge can't
      // slip past the guard (Hive updates its in-memory cache eagerly).
      await box.put(_kPermissionAsked, true);
      await _local.requestPermission();
    } finally {
      _askInFlight = false;
    }
  }

  /// Distinct-but-stable id per session (FNV over the same key shape the
  /// completion banner uses, namespaced) so a waiting banner replaces an
  /// older waiting banner for the same session but never collides with
  /// the completion banner's id.
  static int _notificationId(String epk, String roomId) =>
      SessionCompletionNotifications.stableNotificationId(
        'waiting|${SessionCompletionNotifications.prefsKey(epk, roomId)}',
      );

  Future<void> _show(String epk, String roomId) async {
    final title = roomTitle?.call(epk, roomId);
    await _local.show(
      id: _notificationId(epk, roomId),
      title: title == null || title.isEmpty ? 'Session' : title,
      body: 'Pi is waiting for input at the terminal.',
      payload: SessionCompletionNotifications.prefsKey(epk, roomId),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
  }
}
