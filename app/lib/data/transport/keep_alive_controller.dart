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
/// 25 s keep-alive pings) then keeps running while the UI is backgrounded. The
/// service itself runs no Dart.
///
/// - Android only; a no-op on every other platform.
/// - Honours [Preferences.keepAliveInBackground] — when off, the service is
///   stopped and never started (background behaviour reverts to today's: the OS
///   freezes the process and the WS drops on focus change).
///
/// Wiring is one-directional: this controller subscribes to
/// [ConnectionManager.statusStream]; ConnectionManager knows nothing about it
/// (avoids an import cycle and keeps the manager platform-agnostic).
class KeepAliveController extends Service {
  KeepAliveController(this._prefs);

  final Preferences _prefs;
  static const _channel = MethodChannel('ch.pungitore.piper/keepalive');

  StreamSubscription<ConnectionStatus>? _sub;
  bool _started = false;
  bool _permissionPrompted = false;
  bool _inFlight = false;
  _Pending? _pending;

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
  }

  /// Reflect the latest connection status. Idempotent and coalesced: safe to
  /// call on every emission from ConnectionManager. If a newer status arrives
  /// while one is mid-flight, the latest is queued and processed last, so the
  /// service never settles on a stale state (notably a NoPeer that arrived
  /// during an in-flight start).
  Future<void> reflect(ConnectionStatus status, {String? peerShort}) async {
    if (!Platform.isAndroid) return;
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

  Future<void> _process(ConnectionStatus status, String? peerShort) async {
    try {
      final wantRunning =
          _prefs.keepAliveInBackground && status is! StatusNoPeer;
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
    if (!Platform.isAndroid) return;
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
    if (Platform.isAndroid && _started) {
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
