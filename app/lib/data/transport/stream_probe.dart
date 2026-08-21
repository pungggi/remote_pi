// Per-turn streaming probe (perf diagnosis 2026-08-21).
//
// Splits "the reply keeps rendering word-by-word after the PC finished" into:
//   H1 upstream — WS frames ARRIVE late (relay/network/daemon): inter-arrival
//                 gap p95 well above the daemon's 50ms coalescing cadence.
//   H2 verify   — frames arrive promptly but the serialized Ed25519 chain
//                 (arrival-order processFrame) falls behind: enqueue delay
//                 (arrival → post-verify _queue.add) grows through the turn.
//   H3 UI       — pipeline keeps up but the UI can't paint fast enough:
//                  FrameTiming build/raster p95 large during the turn.
//
// Events come from ws_transport (arrived / verified / enqueued) and
// sync_service (chunk / emitted / turnDone). A one-line SUMMARY is printed
// ~2.5s after agent_done (late UI frames land first); a ticker line every 2s
// shows backlog growth live in logcat. Compare against the daemon's own
// `[probe] daemon turn: ... sendSpan=...` line (supervisord.log) to attribute
// arrival lag upstream (H1) vs on-device (H2/H3).
//
// Deliberately allocation-light so it is safe in profile builds; zero-op
// bookkeeping when no turn is active.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

const int _kMaxSamples = 4000;

class StreamProbe {
  StreamProbe._();
  static final StreamProbe instance = StreamProbe._();

  /// Master gate — no-ops (zero timers, zero binding access) when:
  ///   • release builds (kReleaseMode): production stays silent — the probe
  ///     is a diagnosis tool for debug/profile runs, not shipping telemetry;
  ///   • no Flutter binding exists (pure Dart unit tests feed AgentChunk
  ///     through SyncService — SchedulerBinding.instance would THROW there,
  ///     and arming dump/failsafe timers would trip testWidgets' pending-
  ///     timer check). Probed once, cached.
  bool _bindingOkCache = false;
  bool _bindingProbed = false;
  bool get _enabled {
    if (kReleaseMode) return false;
    if (!_bindingProbed) {
      _bindingProbed = true;
      try {
        SchedulerBinding.instance; // throws when no binding is initialized
        _bindingOkCache = true;
      } on Error {
        _bindingOkCache = false;
      }
    }
    return _bindingOkCache;
  }

  String? _turn;
  DateTime? _turnStart;

  // WS arrival (every relay line, any shape).
  int _frames = 0;
  DateTime? _firstArrival;
  DateTime? _lastArrival;
  final List<int> _gapsMs = [];

  // Verify chain — per signed frame: Ed25519Worker round-trip, which includes
  // queue-wait behind prior verifies (exactly the serialized-chain cost, H2).
  int _verifies = 0;
  double _verifySumMs = 0;
  double _verifyMaxMs = 0;

  // Arrival → enqueued: the observable backlog of the serialized chain (H2).
  final List<int> _enqDelaysMs = [];
  int _enqueued = 0;
  int _enqBytes = 0;

  // Payload + UI emit.
  int _chunks = 0;
  int _chars = 0;
  int _emits = 0;
  DateTime? _doneReceived;
  DateTime? _lastEmit;

  // FrameTiming during the turn (H3).
  final List<double> _buildMs = [];
  final List<double> _rasterMs = [];
  bool _timingsHooked = false;

  Timer? _ticker;
  Timer? _dumpTimer;
  Timer? _failsafe;

  // ── ws_transport hooks ───────────────────────────────────────────────────

  void arrived(DateTime at) {
    if (!_enabled) return;
    _firstArrival ??= at;
    if (_lastArrival != null) {
      _push(_gapsMs, at.difference(_lastArrival!).inMilliseconds);
    }
    _lastArrival = at;
    _frames++;
  }

  void verified(double ms) {
    if (!_enabled) return;
    _verifies++;
    _verifySumMs += ms;
    if (ms > _verifyMaxMs) _verifyMaxMs = ms;
  }

  void enqueued(DateTime arrivedAt, int bytes) {
    if (!_enabled) return;
    _enqueued++;
    _enqBytes += bytes;
    _push(
      _enqDelaysMs,
      DateTime.now().difference(arrivedAt).inMilliseconds,
    );
  }

  // ── sync_service hooks ───────────────────────────────────────────────────

  void chunk(String turn, int chars) {
    if (!_enabled) return;
    if (_turn != turn) _resetTurn(turn);
    _chunks++;
    _chars += chars;
  }

  void emitted() {
    if (!_enabled) return;
    _emits++;
    _lastEmit = DateTime.now();
  }

  void turnDone(String turn) {
    if (!_enabled || _turn != turn) return;
    _doneReceived ??= DateTime.now();
    _dumpTimer?.cancel();
    _dumpTimer = Timer(const Duration(milliseconds: 2500), _dump);
  }

  // ── turn lifecycle ───────────────────────────────────────────────────────

  void _resetTurn(String turn) {
    _teardownTimers();
    _turn = turn;
    _turnStart = DateTime.now();
    _frames = 0;
    _firstArrival = null;
    _lastArrival = null;
    _gapsMs.clear();
    _verifies = 0;
    _verifySumMs = 0;
    _verifyMaxMs = 0;
    _enqDelaysMs.clear();
    _enqueued = 0;
    _enqBytes = 0;
    _chunks = 0;
    _chars = 0;
    _emits = 0;
    _doneReceived = null;
    _lastEmit = null;
    _buildMs.clear();
    _rasterMs.clear();
    _hookTimings();
    debugPrint('[probe] turn start $turn');
    _ticker = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    // Failsafe: a turn whose agent_done never arrives (error/kill) still
    // dumps after 3 minutes instead of ticking forever.
    _failsafe = Timer(const Duration(minutes: 3), _dump);
  }

  void _tick() {
    if (_turn == null) return;
    final backlog = _enqDelaysMs.isEmpty ? 0 : _enqDelaysMs.last;
    debugPrint(
      '[probe] t=${DateTime.now().difference(_turnStart!).inMilliseconds}ms '
      'frames=$_frames chunks=$_chunks chars=$_chars '
      'verifySum=${_verifySumMs.toStringAsFixed(0)}ms '
      'backlog(last enqDelay)=$backlog ms',
    );
  }

  void _dump() {
    if (_turn == null) return;
    final arrSpan = (_firstArrival != null && _lastArrival != null)
        ? _lastArrival!.difference(_firstArrival!).inMilliseconds
        : 0;
    final tail = (_doneReceived != null && _lastEmit != null)
        ? _lastEmit!.difference(_doneReceived!).inMilliseconds
        : 0;
    final avgVerify = _verifies == 0 ? 0.0 : _verifySumMs / _verifies;
    debugPrint(
      '[probe] SUMMARY turn=$_turn frames=$_frames enq=$_enqueued '
      '(${_enqBytes}B) chunks=$_chunks chars=$_chars '
      'arrSpan=${arrSpan}ms gaps(p50/p95/max)=${_pct(_gapsMs)}ms '
      'enqDelay(p50/p95/max)=${_pct(_enqDelaysMs)}ms '
      'verify(n/sum/avg/max)=$_verifies/${_verifySumMs.toStringAsFixed(0)}/'
      '${avgVerify.toStringAsFixed(1)}/${_verifyMaxMs.toStringAsFixed(1)}ms '
      'tail(done→lastEmit)=$tail ms emits=$_emits '
      'uiBuild(p50/p95/max)=${_pctD(_buildMs)}ms '
      'uiRaster(p50/p95/max)=${_pctD(_rasterMs)}ms',
    );
    _teardownTimers();
    _unhookTimings();
    _turn = null;
  }

  void _teardownTimers() {
    _ticker?.cancel();
    _ticker = null;
    _dumpTimer?.cancel();
    _dumpTimer = null;
    _failsafe?.cancel();
    _failsafe = null;
  }

  // ── FrameTiming (H3) ─────────────────────────────────────────────────────

  void _hookTimings() {
    if (_timingsHooked) return;
    _timingsHooked = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _unhookTimings() {
    if (!_timingsHooked) return;
    _timingsHooked = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    if (_turn == null) return;
    for (final t in timings) {
      if (_buildMs.length < _kMaxSamples) {
        _buildMs.add(t.buildDuration.inMicroseconds / 1000);
      }
      if (_rasterMs.length < _kMaxSamples) {
        _rasterMs.add(t.rasterDuration.inMicroseconds / 1000);
      }
    }
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  void _push(List<int> list, int v) {
    if (list.length >= _kMaxSamples) list.removeAt(0);
    list.add(v);
  }

  String _pct(List<int> l) {
    if (l.isEmpty) return '0/0/0';
    final s = [...l]..sort();
    return '${_q(s, .5)}/${_q(s, .95)}/${s.last}';
  }

  String _pctD(List<double> l) {
    if (l.isEmpty) return '0/0/0';
    final s = [...l]..sort();
    String f(double v) => v.toStringAsFixed(1);
    return '${f(_q(s, .5))}/${f(_q(s, .95))}/${f(s.last)}';
  }

  T _q<T>(List<T> s, double q) => s[((s.length - 1) * q).floor()];
}
