import 'dart:async';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/keep_alive_controller.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/protocol/protocol.dart';

enum BalancedPhase { inactive, foreground, active, grace, sleeping }

/// Plan 153 — owns Balanced active/grace/sleep transitions.
///
/// Relevant run and wake activity keeps the relay connection alive. Routine
/// metadata never extends the grace period. ConnectionManager remains the
/// socket owner and KeepAliveController remains the sole FGS owner.
class BalancedConnectionController extends Service {
  BalancedConnectionController(
    this._prefs,
    this._conn,
    this._keepAlive, {
    this.gracePeriod = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Preferences _prefs;
  final ConnectionManager _conn;
  final KeepAliveController _keepAlive;
  final Duration gracePeriod;
  final DateTime Function() _now;

  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  StreamSubscription<RunDoneEvent>? _runDoneSub;
  StreamSubscription<WaitingForInputEvent>? _waitingSub;
  Timer? _graceTimer;
  DateTime? _graceEndsAt;
  BalancedPhase _phase = BalancedPhase.inactive;
  bool _backgrounded = false;
  bool _attached = false;
  bool _disposed = false;

  BalancedPhase get phase => _phase;
  bool get isBackgrounded => _backgrounded;
  DateTime? get graceEndsAt => _graceEndsAt;

  void attach() {
    if (_attached || _disposed) return;
    _attached = true;
    _prefs.addListener(_onModeChanged);
    _roomsSub = _conn.roomsStream.listen((_) => _reconcileRooms());
    _runDoneSub = _conn.runDoneStream.listen((_) => noteRunFinished());
    _waitingSub = _conn.waitingForInputStream.listen((event) {
      if (event.waiting) {
        wakeForWaiting();
      }
    });
    _phase = _prefs.keepAliveMode == KeepAliveMode.balanced
        ? BalancedPhase.foreground
        : BalancedPhase.inactive;
  }

  void setBackgrounded(bool backgrounded) {
    if (_disposed) return;
    final changed = _backgrounded != backgrounded;
    _backgrounded = backgrounded;
    if (!backgrounded) {
      _graceTimer?.cancel();
      _graceTimer = null;
      _graceEndsAt = null;
      _phase = _prefs.keepAliveMode == KeepAliveMode.balanced
          ? BalancedPhase.foreground
          : BalancedPhase.inactive;
      _keepAlive.setBalancedActive(false);
      _conn.onForeground();
      return;
    }
    if (_prefs.keepAliveMode != KeepAliveMode.balanced) return;
    if (changed || _phase == BalancedPhase.inactive) _reconcileRooms();
  }

  /// Registration validation is an explicit wake with no active snapshot yet.
  Future<void> wakeForValidation() => _wakeWithGrace();

  /// Accepted run_started push, or an equivalent explicit wake request.
  Future<void> wakeForRunStarted() => _wakeWithGrace();

  /// A waiting alert gets a bounded connection window, never an infinite FGS.
  Future<void> wakeForWaiting() => _wakeWithGrace();

  /// Completion and run-finished events only shorten an already awake window.
  /// They never open a new socket from deep sleep just to show an alert.
  void noteRunFinished() {
    if (!_canBalanceInBackground || _phase == BalancedPhase.sleeping) return;
    _startGrace();
  }

  Future<void> handleForegroundServiceTimeout() async {
    if (_disposed || !_backgrounded) return;
    _graceTimer?.cancel();
    _graceTimer = null;
    _graceEndsAt = null;
    _phase = _prefs.keepAliveMode == KeepAliveMode.balanced
        ? BalancedPhase.sleeping
        : BalancedPhase.inactive;
    _keepAlive.setBalancedActive(false);
    await _conn.suspendForBalancedSleep();
  }

  void _onModeChanged() {
    if (_disposed) return;
    if (_prefs.keepAliveMode != KeepAliveMode.balanced) {
      _graceTimer?.cancel();
      _graceTimer = null;
      _graceEndsAt = null;
      _phase = BalancedPhase.inactive;
      _keepAlive.setBalancedActive(false);
      if (_conn.status is StatusSleeping) {
        // Legacy modes keep their own semantics after leaving Balanced.
        // ignore: unawaited_futures
        _conn.resumeFromBalancedSleep();
      }
      return;
    }
    _phase = _backgrounded ? BalancedPhase.grace : BalancedPhase.foreground;
    if (_backgrounded) {
      _reconcileRooms();
    } else {
      _conn.onForeground();
    }
  }

  void _reconcileRooms() {
    if (!_canBalanceInBackground) return;
    if (_conn.hasActiveRuns) {
      _graceTimer?.cancel();
      _graceTimer = null;
      _graceEndsAt = null;
      _phase = BalancedPhase.active;
      _keepAlive.setBalancedActive(true);
      return;
    }
    if (_phase == BalancedPhase.active ||
        _phase == BalancedPhase.inactive ||
        _phase == BalancedPhase.foreground) {
      _startGrace();
    }
    // Metadata changes during grace or sleeping do not extend the timer.
  }

  bool get _canBalanceInBackground =>
      _attached &&
      !_disposed &&
      _backgrounded &&
      _prefs.keepAliveMode == KeepAliveMode.balanced;

  Future<void> _wakeWithGrace() async {
    if (!_canBalanceInBackground) return;
    _startGrace();
    if (_conn.status is! StatusOnline) {
      await _conn.resumeFromBalancedSleep();
    }
  }

  void _startGrace() {
    if (!_canBalanceInBackground) return;
    _phase = BalancedPhase.grace;
    _keepAlive.setBalancedActive(true);
    _graceEndsAt = _now().add(gracePeriod);
    _graceTimer?.cancel();
    _graceTimer = Timer(gracePeriod, _onGraceElapsed);
  }

  void _onGraceElapsed() {
    if (!_canBalanceInBackground) return;
    if (_conn.hasActiveRuns) {
      _reconcileRooms();
      return;
    }
    final deadline = _graceEndsAt;
    final now = _now();
    if (deadline != null && now.isBefore(deadline)) {
      _graceTimer = Timer(deadline.difference(now), _onGraceElapsed);
      return;
    }
    _graceTimer = null;
    _graceEndsAt = null;
    _phase = BalancedPhase.sleeping;
    _keepAlive.setBalancedActive(false);
    // ignore: unawaited_futures
    _conn.suspendForBalancedSleep();
  }

  @override
  void dispose() {
    _disposed = true;
    _graceTimer?.cancel();
    _roomsSub?.cancel();
    _runDoneSub?.cancel();
    _waitingSub?.cancel();
    if (_attached) _prefs.removeListener(_onModeChanged);
    _keepAlive.setBalancedActive(false);
  }
}
