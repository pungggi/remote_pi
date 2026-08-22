import 'dart:async';

import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Plan 114 (A) — reacts to network changes (Wi-Fi ↔ cellular ↔ none) so
/// recovery starts within ~1 s instead of waiting up to the 30 s backoff
/// ceiling.
///
/// Flap dampening (2026-08-22 follow-up): when the connection is already
/// Online, a connectivity transition no longer tears the socket down. On
/// Android the Tailscale VPN and Wi-Fi interact constantly, and most of
/// those transitions leave a perfectly healthy link — blindly
/// force-reconnecting on each one re-authenticated at the relay every few
/// seconds (observed LAN↔Tailscale flapping: 6 auths in 30 s, each one
/// fanning presence/rooms broadcasts to every subscriber). The monitor now
/// calls [ConnectionManager.reconnectIfStale]: a link with fresh inbound
/// traffic (or one whose ping is answered within the probe window) is left
/// alone; only a genuinely dead (half-open) link redials, and a transition
/// while offline/retrying still recovers immediately (plan 114's core win).
///
/// Only transitions **to** a usable network fire (we ignore `none`), and a
/// burst of changes within [_debounce] coalesces into one probe (mobile
/// handoffs often emit wifi-lost → cellular-gained in quick succession).
///
/// The connectivity stream + clock are injectable so the debounce /
/// transition-filter / probe-window logic is unit-testable without a device.
class NetworkMonitor extends Service {
  NetworkMonitor({
    Stream<List<ConnectivityResult>>? connectivityStream,
    DateTime Function()? now,
    Duration probeWindow = _kDefaultProbeWindow,
  })  : _connectivityStream = connectivityStream,
        _now = now ?? DateTime.now,
        _probeWindow = probeWindow;

  final Stream<List<ConnectivityResult>>? _connectivityStream;
  final DateTime Function() _now;

  /// Liveness window forwarded to [ConnectionManager.reconnectIfStale].
  /// Injectable so tests shrink it to milliseconds.
  final Duration _probeWindow;

  /// Default probe window for the dampened path — mirrors the
  /// ConnectionManager's own [_kStaleProbeWindow] (kept as a local const so
  /// this file stays decoupled from that private symbol).
  static const _kDefaultProbeWindow = Duration(seconds: 4);

  StreamSubscription<List<ConnectivityResult>>? _sub;
  ConnectionManager? _cm;
  DateTime _lastReconnect = DateTime.fromMillisecondsSinceEpoch(0);
  bool _probeInFlight = false;
  bool _disposed = false;

  /// Coalesce a burst of connectivity changes into a single probe.
  /// Mobile handoffs fire several events within ~1 s; we don't want to
  /// probe (let alone tear down + redial) for each.
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
    // A probe already running will conclude with better evidence than this
    // fresh event has — drop the event instead of racing a second probe.
    if (_probeInFlight) return;
    _probeInFlight = true;
    () async {
      try {
        await cm.reconnectIfStale(probeWindow: _probeWindow);
      } finally {
        _probeInFlight = false;
      }
    }();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    _cm = null;
  }
}
