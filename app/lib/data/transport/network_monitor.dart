import 'dart:async';

import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Plan 114 (A) — reacts to network changes (Wi-Fi ↔ cellular ↔ none) and
/// nudges [ConnectionManager.forceReconnect] so recovery starts within ~1 s
/// instead of waiting up to the 30 s backoff ceiling.
///
/// The reported problem: switching VLAN → mobile leaves the WebSocket
/// *half-open* (the OS never delivers a close event), and even once Tailscale
/// re-routes, the app sits on its backoff schedule before the next attempt.
/// This is the "I just got a usable network again" trigger that resets the
/// backoff and redials immediately.
///
/// Only transitions **to** a usable network fire (we ignore `none`), and a
/// burst of changes within [_debounce] coalesces into one reconnect (mobile
/// handoffs often emit wifi-lost → cellular-gained in quick succession).
///
/// The connectivity stream + clock are injectable so the debounce / transition
/// filter is unit-testable without a device.
class NetworkMonitor extends Service {
  NetworkMonitor({
    Stream<List<ConnectivityResult>>? connectivityStream,
    DateTime Function()? now,
  })  : _connectivityStream = connectivityStream,
        _now = now ?? DateTime.now;

  final Stream<List<ConnectivityResult>>? _connectivityStream;
  final DateTime Function() _now;

  StreamSubscription<List<ConnectivityResult>>? _sub;
  ConnectionManager? _cm;
  DateTime _lastReconnect = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  /// Coalesce a burst of connectivity changes into a single reconnect.
  /// Mobile handoffs fire several events within ~1 s; we don't want to
  /// tear down + redial the WS for each.
  static const _debounce = Duration(seconds: 1);

  /// Subscribe to connectivity changes and wire them to [cm]. Idempotent;
  /// safe to call once during boot. No-op if disposed.
  void attach(ConnectionManager cm) {
    if (_disposed) return;
    _cm = cm;
    _sub?.cancel();
    final stream = _connectivityStream ?? Connectivity().onConnectivityChanged;
    _sub = stream.listen(_handle);
  }

  /// Exposed for tests: process a raw connectivity snapshot. Applies the
  /// same transition-filter + debounce as a live event.
  @visibleForTesting
  void handle(List<ConnectivityResult> results) => _handle(results);

  void _handle(List<ConnectivityResult> results) {
    final cm = _cm;
    if (cm == null || _disposed) return;
    // Only react to transitions TO a usable network. "none" means we lost
    // connectivity entirely — nothing to redial until it returns.
    final connected = results.any((r) => r != ConnectivityResult.none);
    if (!connected) return;
    final at = _now();
    if (at.difference(_lastReconnect) < _debounce) return;
    _lastReconnect = at;
    // ignore: unawaited_futures
    cm.forceReconnect();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    _cm = null;
  }
}
