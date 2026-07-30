import 'dart:async';
import 'dart:io' show Platform;

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/pairing/storage.dart';
import 'package:flutter/services.dart';

/// Plan 103 — keeps the Android foreground service in sync with the relay
/// connection so the WebSocket survives the app being backgrounded.
///
/// The service is a "priority anchor": it holds a persistent notification,
/// which elevates the whole app process to foreground priority, so Android does
/// not freeze it. The Dart root isolate (ConnectionManager + WsTransport + the
/// keep-alive pings, adaptive cadence — plan 125) then keeps running while the UI is backgrounded. The
/// service itself runs no Dart.
///
/// - Android only; a no-op on every other platform.
/// - Honours [Preferences.keepAliveMode] (plan 125 Layer 4): `off` → never
///   started; `always` → started on background+peer; `whenCharging` (default)
///   → additionally gated on the device charging state.
/// - Plan 125 — only runs while the app is backgrounded. The process is already
///   foreground-priority while the UI is open, so running the service then just
///   burns the Android-15 `dataSync` 6 h budget for nothing. Driven from
///   `didChangeAppLifecycleState` via [setBackgrounded].
///
/// Wiring is one-directional: this controller subscribes to
/// [ConnectionManager.statusStream]; ConnectionManager knows nothing about it
/// (avoids an import cycle and keeps the manager platform-agnostic).
class KeepAliveController extends Service {
  /// `isAndroid` is injectable so unit tests can exercise the Android-only
  /// branch on a desktop host (where `dart:io Platform.isAndroid` is false).
  /// `chargingPollInterval` (plan 125 Layer 4) is how often the cached charging
  /// state is refreshed while backgrounded.
  KeepAliveController(
    this._prefs, {
    bool Function()? isAndroid,
    Duration chargingPollInterval = const Duration(seconds: 60),
    this.enableChargingPoll = true,
  }) : _isAndroid = isAndroid ?? _defaultIsAndroid,
       _chargingPollInterval = chargingPollInterval;

  final Preferences _prefs;
  final bool Function() _isAndroid;
  final Duration _chargingPollInterval;

  /// Plan 125 (Layer 4) — when false, the background charging poll is a no-op
  /// (tests drive charging via [setCharging] directly, avoiding a real timer
  /// that would trip flutter_test's pending-timer check).
  final bool enableChargingPoll;
  static const _channel = MethodChannel('ch.pungitore.piper/keepalive');

  StreamSubscription<ConnectionStatus>? _sub;
  bool _started = false;
  bool _permissionPrompted = false;
  bool _inFlight = false;
  _Pending? _pending;
  // Plan 125 — the service only earns its keep while the app is backgrounded.
  // `_backgrounded` is driven by `didChangeAppLifecycleState` (main.dart);
  // `_lastStatus` / `_lastPeerShort` let [setBackgrounded] re-evaluate the
  // cached status without waiting for a fresh emission.
  bool _backgrounded = false;
  // Plan 125 (Layer 4) — cached charging state for the `whenCharging` mode.
  bool _isCharging = false;
  // Plan 125 (Layer 4) — periodic refresh of [_isCharging] while backgrounded.
  Timer? _chargingTimer;
  ConnectionStatus _lastStatus = const StatusNoPeer();
  String? _lastPeerShort;

  /// Subscribe to [ConnectionManager.statusStream] and mirror every change into
  /// the foreground service. Also reflects the current status once on attach so
  /// a connection already Online at attach time starts the notification.
  void attach(ConnectionManager cm) {
    _sub?.cancel();
    _sub = cm.statusStream.listen((s) {
      final peer = cm.activePeer;
      reflect(s, peerShort: peer == null ? null : _peerShort(peer));
    });
    // The stream only fires on *change* — reflect the status as-of attach.
    final peer = cm.activePeer;
    reflect(cm.status, peerShort: peer == null ? null : _peerShort(peer));
    // Plan 125 (Layer 4) — pre-populate the charging state so the first
    // backgrounding already knows whether to start the service.
    // ignore: unawaited_futures
    _refreshCharging();
  }

  /// Reflect the latest connection status. Idempotent and coalesced: safe to
  /// call on every emission from ConnectionManager. If a newer status arrives
  /// while one is mid-flight, the latest is queued and processed last, so the
  /// service never settles on a stale state (notably a NoPeer that arrived
  /// during an in-flight start).
  Future<void> reflect(ConnectionStatus status, {String? peerShort}) async {
    if (!_isAndroid()) return;
    // Plan 125 — cache the latest status so [setBackgrounded] can re-evaluate
    // without a fresh emission from ConnectionManager.
    _lastStatus = status;
    _lastPeerShort = peerShort;
    if (_inFlight) {
      _pending = _Pending(status, peerShort);
      return;
    }
    _inFlight = true;
    try {
      await _process(status, peerShort);
    } finally {
      _inFlight = false;
    }
    final next = _pending;
    if (next != null) {
      _pending = null;
      // ignore: unawaited_futures
      reflect(next.status, peerShort: next.peerShort);
    }
  }

  /// Plan 125 — set from `didChangeAppLifecycleState`. True while the app is
  /// NOT `resumed` (i.e. backgrounded). The foreground service is only worth
  /// running then; while foregrounded the process is already foreground
  /// priority, so the service would just burn the Android-15 `dataSync` 6 h
  /// budget. Re-evaluates the cached status: starts on background-with-peer,
  /// stops on foreground. Idempotent.
  void setBackgrounded(bool backgrounded) {
    if (!_isAndroid()) return;
    if (_backgrounded == backgrounded) return;
    _backgrounded = backgrounded;
    if (backgrounded) {
      _startChargingPoll();
    } else {
      _stopChargingPoll();
    }
    // ignore: unawaited_futures
    reflect(_lastStatus, peerShort: _lastPeerShort);
  }

  /// Plan 125 (Layer 4) — set the cached charging state (push-driven for
  /// testability; in production refreshed by [_startChargingPoll]). Re-evaluates
  /// the service so the `whenCharging` mode reacts to plug/unplug.
  void setCharging(bool charging) {
    if (_isCharging == charging) return;
    _isCharging = charging;
    // ignore: unawaited_futures
    reflect(_lastStatus, peerShort: _lastPeerShort);
  }

  /// Plan 125 (Layer 4) — while backgrounded, poll the native charging state so
  /// an unplug while the service is running is noticed within the poll window.
  /// The relay's ~60 s inbound already wakes the radio, so this rides its tail.
  void _startChargingPoll() {
    _stopChargingPoll();
    if (!_isAndroid() || !enableChargingPoll) return;
    _refreshCharging(); // immediate refresh, then periodic
    _chargingTimer = Timer.periodic(
      _chargingPollInterval,
      (_) => _refreshCharging(),
    );
  }

  void _stopChargingPoll() {
    _chargingTimer?.cancel();
    _chargingTimer = null;
  }

  Future<void> _refreshCharging() async {
    if (!_isAndroid()) return;
    try {
      final charging = await _channel.invokeMethod<bool>('isCharging') ?? false;
      // A poll completing after resume is harmless: setCharging is a no-op once
      // _isCharging already matches, and reflect re-evaluates to "stopped".
      setCharging(charging);
    } on PlatformException {
      // Channel not ready (early bootstrap) → leave _isCharging as-is; the next
      // poll or status emission retries.
    }
  }

  Future<void> _process(ConnectionStatus status, String? peerShort) async {
    try {
      // Plan 125 (Layer 0) — only while backgrounded. (Layer 4) — three-way
      // mode, with the `whenCharging` mode additionally gated on [_isCharging].
      final mode = _prefs.keepAliveMode;
      final wantRunning =
          mode != KeepAliveMode.off &&
          status is! StatusNoPeer &&
          _backgrounded &&
          (mode == KeepAliveMode.always || _isCharging);
      if (!wantRunning) {
        if (_started) {
          _started = false;
          await _invoke('stop');
        }
        return;
      }
      final text = _notificationText(status, peerShort);
      if (!_started) {
        await _ensurePermission();
        _started = true; // set before await to narrow the re-entrancy window
        final ok = await _invoke('start', <String, dynamic>{'text': text});
        if (!ok) _started = false;
      } else {
        await _invoke('update', <String, dynamic>{'text': text});
      }
    } on PlatformException {
      // Channel not ready (early bootstrap) or service rejected the call.
      // Non-fatal: the next status emission retries from scratch.
    }
  }

  /// Called when the user disables the pref: tear the service down now rather
  /// than waiting for the next status emission.
  Future<void> disableNow() async {
    if (!_isAndroid()) return;
    if (_started) {
      _started = false;
      try {
        await _invoke('stop');
      } on PlatformException {
        /* best-effort */
      }
    }
  }

  String _notificationText(ConnectionStatus status, String? peerShort) {
    if (status is StatusOnline) {
      final label = peerShort;
      return (label != null && label.isNotEmpty)
          ? 'Connected · $label'
          : 'Connected';
    }
    // Connecting / Retrying / Offline (transient) — still driving a peer.
    return 'Reconnecting…';
  }

  Future<void> _ensurePermission() async {
    if (_permissionPrompted) return;
    _permissionPrompted = true;
    try {
      final granted =
          await _channel.invokeMethod<bool>('hasNotificationPermission') ??
          false;
      if (!granted) {
        // Best-effort prompt (no-op if backgrounded). We do NOT gate start on
        // the outcome: the service runs regardless; the notification is simply
        // hidden until the user grants permission.
        await _channel.invokeMethod<bool>('requestNotificationPermission');
      }
    } on PlatformException {
      _permissionPrompted = false; // allow a later retry
    }
  }

  Future<bool> _invoke(String method, [Map<String, dynamic>? args]) async {
    final res = await _channel.invokeMethod<bool>(method, args);
    return res ?? false;
  }

  /// Human-readable peer label — mirrors the UI resolution (nickname →
  /// sessionName → epk prefix) so the notification matches Home / Chat.
  static String _peerShort(PeerRecord peer) {
    final nick = peer.nickname;
    if (nick != null && nick.isNotEmpty) return nick;
    if (peer.sessionName.isNotEmpty) return peer.sessionName;
    return peer.remoteEpk.substring(0, 8);
  }

  /// App teardown — cancel the subscription + best-effort stop (fire-and-forget;
  /// dispose is synchronous).
  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _chargingTimer?.cancel();
    _chargingTimer = null;
    if (_isAndroid() && _started) {
      _started = false;
      // ignore: unawaited_futures
      _channel.invokeMethod<bool>('stop');
    }
  }
}

class _Pending {
  const _Pending(this.status, this.peerShort);
  final ConnectionStatus status;
  final String? peerShort;
}

// Plan 125 — default platform probe; injectable via the constructor so unit
// tests can exercise the Android-only branch on a desktop host.
bool _defaultIsAndroid() => Platform.isAndroid;
