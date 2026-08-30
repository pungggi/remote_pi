import 'dart:async';

import 'package:app/data/notifications/local_notifications.dart';
import 'package:app/data/notifications/session_completion_notifications.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/protocol/protocol.dart';

/// Plan/134 — "Pi is waiting for input at the terminal" notifications.
///
/// The generic phone-side signal for ANY blocking user-facing `ctx.ui`
/// prompt (pi 0.84.4 `ui_prompt_start`/`end`): pi-ask's `ask_user` AND
/// every foreign extension's `confirm`/`select`/`input`/`editor`/`custom`.
/// Without it, a foreign prompt just looks like the agent "working" —
/// the user has no idea that walking to the terminal (or answering in the
/// app) is the unblocking action.
///
/// Gates, in order (mirrors the plan/132 completion-notification facade):
/// 1. **rising edge only** — [WaitingForInputEvent]s are transitions
///    emitted by [ConnectionManager] from live `room_meta_updated`
///    frames; app-open replays (`room_announced` / `rooms` snapshots)
///    never produce one, so a reconnecting app cannot re-fire a banner;
/// 2. **app backgrounded** — foreground, the tiles already show the
///    badge (same discipline as plan/132 gate 1);
/// 3. **pi-ask sheet dedupe** — when an `extension_ui_request` answer
///    sheet is already open for that room ([hasOpenAskSheet]), the sheet
///    IS the signal; suppressing the generic banner avoids a double
///    alert. Foreign prompts (no sheet) always notify — this banner is
///    their only signal;
/// 4. **notification permission granted**.
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

  WaitingInputNotifications({required LocalNotifications local})
    : _local = local;

  StreamSubscription<WaitingForInputEvent>? _sub;
  bool _backgrounded = false;
  bool _disposed = false;

  /// Subscribe to waiting-for-input transitions. Wired in bootstrap to
  /// `ConnectionManager.waitingForInputStream`.
  void attach(Stream<WaitingForInputEvent> stream) {
    _sub?.cancel();
    _sub = stream.listen(_onWaiting);
  }

  /// Driven from `didChangeAppLifecycleState`: `true` while the app is
  /// NOT resumed. Mirrors the plan/132 facade's gate.
  void setBackgrounded(bool backgrounded) {
    _backgrounded = backgrounded;
  }

  Future<void> _onWaiting(WaitingForInputEvent e) async {
    if (_disposed) return;
    // Falling edges carry no banner (the badge on the tiles just clears).
    if (!e.waiting) return;
    // Gate 1 — only worth a banner when the user is not looking at the app.
    if (!_backgrounded) return;
    // Gate 2 — pi-ask sheet already open for this room: the sheet is the
    // signal, a second banner would be noise. Foreign prompts have no
    // sheet, so they always pass through (this banner is their only signal).
    if (hasOpenAskSheet?.call(e.epk, e.roomId) ?? false) return;
    // Gate 3 — permission.
    if (!await _local.hasPermission()) return;

    final title = roomTitle?.call(e.epk, e.roomId);
    // Distinct-but-stable id per session (FNV over the same key shape the
    // completion banner uses, namespaced) so a waiting banner replaces an
    // older waiting banner for the same session but never collides with
    // the completion banner's id.
    final notificationId = SessionCompletionNotifications.stableNotificationId(
      'waiting|${SessionCompletionNotifications.prefsKey(e.epk, e.roomId)}',
    );
    await _local.show(
      id: notificationId,
      title: title == null || title.isEmpty ? 'Session' : title,
      body: 'Pi is waiting for input at the terminal.',
      payload: SessionCompletionNotifications.prefsKey(e.epk, e.roomId),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
  }
}
