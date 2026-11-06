import 'dart:async';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/notifications/local_notifications.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter/foundation.dart';

/// Plan/132 — the per-session toggle surface consumed by the UI layer
/// (HomeViewModel / tiles). Interface so view-model tests can stub it
/// without Hive (same pattern as `IActionsRepository`). [Service] so the
/// injector's `addService` accepts the concrete implementation.
abstract class ICompletionNotifications extends ChangeNotifier
    implements Service {
  bool isEnabled(String epk, String roomId);
  Future<bool> setEnabled(String epk, String roomId, bool value);
}

/// Plan/132 — session-completion notifications.
///
/// One facade owning the whole feature:
///
/// - **The per-session toggle** (durable, Hive `notify_prefs` box) —
///   `isEnabled` / `setEnabled`. It is a [ChangeNotifier] so Home can
///   rebuild the bell badges when a toggle flips. **Default ON** (the
///   `notifydefault` change, 2026-11): a missing key means enabled —
///   only an explicit `false` opts a session out. There is no toggle UI
///   yet, so default-off left the whole feature dormant; default-on makes
///   completion banners work out of the box on every new session.
/// - **The notification gate** — `attach` subscribes to a run-done stream
///   (wire it to [ConnectionManager.runDoneStream] in bootstrap) and, per
///   marker, applies the gates in order:
///   1. app backgrounded (`setBackgrounded`, driven from
///      `didChangeAppLifecycleState` — foreground, the tiles already show
///      working→idle, so a banner would be noise; a FOREGROUND marker
///      instead carries the contextual permission ask below);
///   2. toggle on for that (epk, room);
///   3. marker newer than the last one notified for that room (dedup —
///      belt-and-suspenders against any future relay re-broadcast);
///   4. notification permission granted.
///
/// **Contextual permission ask** (default-on companion): the first
/// FOREGROUND run-done marker with permission missing triggers the
/// POST_NOTIFICATIONS ask — once per install, guarded by the SAME durable
/// flag the waiting-input facade uses ([LocalBoxes.kPermissionAskedKey]),
/// so whichever facade hits first consumes the ask and a denial silences
/// both without ever re-nagging. Without this, default-on would stay
/// silently banner-less on Android 13+ for users who never hit an
/// ask_user prompt.
///
/// **Honest limits** (declared in Plan/132, surfaced in the toggle UI): the
/// notification only fires while the process is alive — i.e. while the
/// plan-103 keep-alive service holds the relay WebSocket in background. It
/// is NOT push; if Android killed the process the user sees the result on
/// the next app open via normal sync.
///
/// Payload of the banner is deliberately generic: session display name +
/// "Task finished — tap to open". No message content ever travels in the
/// notification (same discipline as plan/36 §3).
class SessionCompletionNotifications extends ICompletionNotifications {
  final LocalBoxes _boxes;
  final LocalNotifications _local;

  /// Sessions whose toggle is on — their names resolve from this callback
  /// so the banner can say which session finished (wired in bootstrap to
  /// [roomTitleFor] against the ConnectionManager).
  String? Function(String epk, String roomId)? roomTitle;

  SessionCompletionNotifications({
    required LocalBoxes boxes,
    required LocalNotifications local,
    this.roomTitle,
  }) : _boxes = boxes,
       _local = local;

  StreamSubscription<RunDoneEvent>? _sub;
  bool _backgrounded = false;
  bool _disposed = false;
  bool _askInFlight = false;

  /// Last `ended_at` (ms) notified per `<standardB64(epk)>:<roomId>` — the
  /// dedup gate. Volatile by design: the relay never replays markers
  /// (broadcast-only field), so there is nothing to remember across boots.
  final Map<String, int> _lastNotifiedEndedAt = {};

  // ---- toggle ---------------------------------------------------------------

  /// Canonical storage key for a (epk, room) pair — the epk is normalized so
  /// url-safe (PairingStorage) and standard (relay frames) forms collide to
  /// the same entry.
  static String prefsKey(String epk, String roomId) =>
      LocalBoxes.sessionKey(toStandardB64(epk), roomId);

  /// Whether completion notifications are enabled for this session.
  /// Default ON: a missing key counts as enabled; only an explicit
  /// `false` opts out (so a future toggle UI can never be surprised by a
  /// stale absence — and existing installs with no key — i.e. every
  /// install, since no UI ever wrote one — get the feature live).
  @override
  bool isEnabled(String epk, String roomId) =>
      _boxes.notifyPrefsBox().get(prefsKey(epk, roomId)) != false;

  /// Enable/disable completion notifications for this session. When turning
  /// ON, requests the notification permission first (Android 13+); returns
  /// the resulting permission state so the UI can surface a hint when it was
  /// denied. The toggle is persisted regardless — the user's intent stands
  /// even while permission is missing.
  @override
  Future<bool> setEnabled(String epk, String roomId, bool value) async {
    var granted = true;
    if (value) granted = await _local.requestPermission();
    await _boxes.notifyPrefsBox().put(prefsKey(epk, roomId), value);
    notifyListeners();
    return granted;
  }

  // ---- gate -----------------------------------------------------------------

  /// Subscribe to run-completion markers. Wired in bootstrap to
  /// `ConnectionManager.runDoneStream`.
  void attach(Stream<RunDoneEvent> runDone) {
    _sub?.cancel();
    _sub = runDone.listen(_onRunDone);
  }

  /// Default [roomTitle] resolver against a [ConnectionManager]'s room
  /// cache: room name → cwd tail → null (caller falls back to 'Session').
  static String? roomTitleFor(
    ConnectionManager conn,
    String epk,
    String roomId,
  ) {
    for (final r in conn.roomsFor(epk)) {
      if (r.roomId != roomId) continue;
      final name = r.name;
      if (name != null && name.isNotEmpty) return name;
      final cwd = r.cwd;
      if (cwd != null && cwd.isNotEmpty) {
        final parts = cwd
            .split(RegExp(r"[\\/]"))
            .where((s) => s.isNotEmpty)
            .toList();
        if (parts.isNotEmpty) return parts.last;
      }
      return null;
    }
    return null;
  }

  /// Driven from `didChangeAppLifecycleState`: `true` while the app is NOT
  /// resumed. Mirrors [KeepAliveController.setBackgrounded].
  void setBackgrounded(bool backgrounded) {
    _backgrounded = backgrounded;
  }

  /// Plan 153 — push-assisted delivery uses the exact live-event gate,
  /// including the per-room opt-in and ended_at deduplication.
  Future<void> showPush({
    required String epk,
    required String roomId,
    required int endedAtMs,
  }) => _onRunDone(
    RunDoneEvent(
      epk: epk,
      roomId: roomId,
      marker: RunDoneMarker(turnId: null, endedAtMs: endedAtMs),
    ),
  );

  Future<void> _onRunDone(RunDoneEvent e) async {
    if (_disposed) return;
    // Gate 1 — only worth a banner when the user is not looking at the app.
    // Foreground: no banner, but the default-on companion — the contextual
    // once-per-install permission ask (see class doc).
    if (!_backgrounded) {
      await _maybeAskPermissionOnce();
      return;
    }
    // Gate 2 — per-session opt-in (default ON; explicit `false` opts out).
    if (!isEnabled(e.epk, e.roomId)) return;
    // Gate 3 — dedup: only markers NEWER than the last notified one.
    final key = prefsKey(e.epk, e.roomId);
    final last = _lastNotifiedEndedAt[key];
    if (last != null && e.marker.endedAtMs <= last) return;
    _lastNotifiedEndedAt[key] = e.marker.endedAtMs;
    // Gate 4 — permission.
    if (!await _local.hasPermission()) return;

    final title = roomTitle?.call(e.epk, e.roomId);
    final notificationId = stableNotificationId(key);
    await _local.show(
      id: notificationId,
      title: title == null || title.isEmpty ? 'Session' : title,
      body: 'Task finished — tap to open.',
      payload: key,
    );
  }

  /// Default-on companion (mirrors plan/141's waiting-input ask): once per
  /// install, at the first FOREGROUND run-done marker with permission
  /// missing — the user just watched a task finish in-app, which is the
  /// natural moment to offer background banners. Shares the durable
  /// [LocalBoxes.kPermissionAskedKey] flag with the waiting-input facade:
  /// whichever fires first consumes the ask; a denial silences both
  /// features' banners and neither ever re-asks. Recovery is the OS
  /// notification settings for the app.
  Future<void> _maybeAskPermissionOnce() async {
    if (_askInFlight) return;
    final box = _boxes.notifyPrefsBox();
    if (box.get(LocalBoxes.kPermissionAskedKey) == true) return;
    _askInFlight = true;
    try {
      if (await _local.hasPermission()) {
        // Nothing to ask — remember that too, so the check never runs
        // again on this install.
        await box.put(LocalBoxes.kPermissionAskedKey, true);
        return;
      }
      // Set the flag BEFORE the await so a second concurrent marker can't
      // slip past the guard (Hive updates its in-memory cache eagerly).
      await box.put(LocalBoxes.kPermissionAskedKey, true);
      await _local.requestPermission();
    } finally {
      _askInFlight = false;
    }
  }

  /// Deterministic 31-bit notification id for a prefs key — **must not use
  /// `String.hashCode`**: Dart randomizes string hashes per isolate, so the
  /// id would change across app restarts and a session's fresh completion
  /// would stack a new banner next to the pre-restart one instead of
  /// replacing it. FNV-1a over the UTF-8 bytes is stable forever.
  static int stableNotificationId(String key) {
    var hash = 0x811c9dc5;
    for (final byte in key.codeUnits) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }

  /// Payload format round-tripping for tap routing: the canonical prefs
  /// key `<standardB64(epk)>:<roomId>` — the `:` cannot appear in either
  /// component (base64 alphabet / room-id alphabet).
  static ({String epk, String roomId})? parsePayload(String payload) {
    final i = payload.indexOf(':');
    if (i <= 0 || i == payload.length - 1) return null;
    return (epk: payload.substring(0, i), roomId: payload.substring(i + 1));
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}
