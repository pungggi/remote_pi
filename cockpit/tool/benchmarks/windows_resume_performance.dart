// ignore_for_file: avoid_print

// Synthetic microbenchmark for the Windows resume policies in plan 59.
//
// This isolates scheduling/coalescing overhead. It does not measure Flutter
// frame time, GPU/raster performance, process startup, or perceived smoothness.
// Counts and peak concurrency are the primary results; asynchronous wall time
// is included only as a noisy host-dependent drain-time indicator.
//
// Run from cockpit/:
//   dart run tool/benchmarks/windows_resume_performance.dart
//   dart compile exe tool/benchmarks/windows_resume_performance.dart -o <exe>

import 'dart:async';
import 'dart:io';

import 'package:cockpit/app/cockpit/domain/utils/coalescing_single_flight.dart';

const _burstTriggers = 1000;
const _slowRefresh = Duration(milliseconds: 20);
const _warmupSamples = 2;
const _measuredSamples = 31;
const _inactiveWindow = Duration(minutes: 10);
const _pollInterval = Duration(seconds: 3);
const _projectCount = 12;
const _resumeEvents = 1000;

Future<void> main() async {
  print('Windows resume policy synthetic microbenchmark');
  print(
    'Runtime: ${Platform.version.split(' ').first} (${Platform.operatingSystem})',
  );
  print(
    'Config: burst=$_burstTriggers, slowRefresh=${_slowRefresh.inMilliseconds}ms, '
    'warmup=$_warmupSamples, samples=$_measuredSamples',
  );
  print(
    'Virtual inactivity: ${_inactiveWindow.inMinutes}min, '
    'poll=${_pollInterval.inSeconds}s, '
    'poll targets/open root projects=$_projectCount',
  );
  print('Resume storm: $_resumeEvents focus/restore events in one cycle');
  print('');

  for (var i = 0; i < _warmupSamples; i++) {
    await _measureOldBurst();
    await _measureNewBurst();
  }

  final oldBurst = <_BurstResult>[];
  final newBurst = <_BurstResult>[];
  for (var i = 0; i < _measuredSamples; i++) {
    // Alternate order to reduce a consistent first-run/second-run bias.
    if (i.isEven) {
      oldBurst.add(await _measureOldBurst());
      newBurst.add(await _measureNewBurst());
    } else {
      newBurst.add(await _measureNewBurst());
      oldBurst.add(await _measureOldBurst());
    }
  }

  final oldRepresentative = oldBurst.first;
  final newRepresentative = newBurst.first;
  final oldTiming = _TimingSummary.from(oldBurst);
  final newTiming = _TimingSummary.from(newBurst);
  final inactive = _measureVirtualInactivity();
  final resume = _measureResumeStorm();

  _printTable([
    _Row(
      'slow burst',
      'effective calls',
      '${oldRepresentative.calls}',
      '${newRepresentative.calls}',
      _countChange(oldRepresentative.calls, newRepresentative.calls),
    ),
    _Row(
      'slow burst',
      'peak concurrency',
      '${oldRepresentative.peakConcurrency}',
      '${newRepresentative.peakConcurrency}',
      _countChange(
        oldRepresentative.peakConcurrency,
        newRepresentative.peakConcurrency,
      ),
    ),
    _Row(
      'slow burst',
      'drain median',
      _formatMicros(oldTiming.medianMicros),
      _formatMicros(newTiming.medianMicros),
      _durationDelta(oldTiming.medianMicros, newTiming.medianMicros),
    ),
    _Row(
      'slow burst',
      'drain p95',
      _formatMicros(oldTiming.p95Micros),
      _formatMicros(newTiming.p95Micros),
      _durationDelta(oldTiming.p95Micros, newTiming.p95Micros),
    ),
    _Row(
      'inactive 10min',
      'poll ticks/onPoll callbacks',
      '${inactive.oldPollCallbacks}',
      '${inactive.newPollCallbacks}',
      _countChange(inactive.oldPollCallbacks, inactive.newPollCallbacks),
    ),
    _Row(
      'inactive 10min',
      'Git refresh operations',
      '${inactive.oldGitRefreshOperations}',
      '${inactive.newGitRefreshOperations}',
      _countChange(
        inactive.oldGitRefreshOperations,
        inactive.newGitRefreshOperations,
      ),
    ),
    _Row(
      'inactive 10min',
      'worktree root-level ops',
      '${inactive.oldWorktreeRootOperations}',
      '${inactive.newWorktreeRootOperations}',
      _countChange(
        inactive.oldWorktreeRootOperations,
        inactive.newWorktreeRootOperations,
      ),
    ),
    _Row(
      'resume storm',
      'coalesced immediate cycle',
      '${resume.oldImmediatePollCallbacks}',
      '${resume.newImmediatePollCallbacks}',
      'n/a',
    ),
    _Row(
      'resume storm',
      'Git refresh operations',
      '${resume.oldGitRefreshOperations}',
      '${resume.newGitRefreshOperations}',
      'n/a',
    ),
    _Row(
      'resume storm',
      'worktree root-level ops',
      '${resume.oldWorktreeRootOperations}',
      '${resume.newWorktreeRootOperations}',
      'n/a',
    ),
    _Row(
      'resume storm',
      'periodic timers',
      '${resume.oldPeriodicTimers}',
      '${resume.newPeriodicTimers}',
      _countChange(resume.oldPeriodicTimers, resume.newPeriodicTimers),
    ),
  ]);

  print('');
  print(
    'Old policy: the historical Timer.periodic stays armed while inactive and '
    'each tick dispatches unawaited work without lifecycle or single-flight.',
  );
  print(
    'Resume note: the historical policy had no lifecycle hook, so the event '
    'storm itself caused 0 immediate poll cycles; its original timer stayed at 1.',
  );
  print(
    'Shared gate: Git refresh, Git History load, and worktree reconciliation '
    'use the same CoalescingSingleFlight policy. The burst result is not '
    'duplicated as invented component-specific measurements.',
  );
  print(
    'Timing note: median/p95 use $_measuredSamples samples after '
    '$_warmupSamples warmups. The p95 is a host-dependent indicator, not a '
    'rigorous tail-latency benchmark; counts are deterministic and primary.',
  );
  print(
    'Wall-time note: a positive delta means the new policy drained more slowly '
    'because it serialized two waits instead of overlapping 1000 operations; '
    'it is not reported as an improvement.',
  );

  final failures = <String>[
    if (oldBurst.any((sample) => sample.calls != _burstTriggers))
      'old burst calls were not $_burstTriggers in every sample',
    if (oldBurst.any((sample) => sample.peakConcurrency != _burstTriggers))
      'old burst peak concurrency was not $_burstTriggers in every sample',
    if (newBurst.any((sample) => sample.peakConcurrency != 1))
      'new burst peak concurrency was not 1 in every sample',
    if (newBurst.any((sample) => sample.calls > 2))
      'new burst exceeded 2 calls in at least one sample',
    if (inactive.oldPollCallbacks != 200)
      'old inactive poll callbacks were ${inactive.oldPollCallbacks}, expected 200',
    if (inactive.oldGitRefreshOperations != 2400)
      'old inactive Git operations were '
          '${inactive.oldGitRefreshOperations}, expected 2400',
    if (inactive.oldWorktreeRootOperations != 2400)
      'old inactive worktree root operations were '
          '${inactive.oldWorktreeRootOperations}, expected 2400',
    if (inactive.newPollCallbacks != 0 ||
        inactive.newGitRefreshOperations != 0 ||
        inactive.newWorktreeRootOperations != 0)
      'new inactive work was non-zero',
    if (resume.oldImmediatePollCallbacks != 0 ||
        resume.oldGitRefreshOperations != 0 ||
        resume.oldWorktreeRootOperations != 0)
      'old resume storm unexpectedly performed immediate work',
    if (resume.newImmediatePollCallbacks != 1)
      'new resume immediate callback count was '
          '${resume.newImmediatePollCallbacks}, expected 1',
    if (resume.newGitRefreshOperations != _projectCount)
      'new resume Git operations were ${resume.newGitRefreshOperations}, '
          'expected $_projectCount',
    if (resume.newWorktreeRootOperations != _projectCount)
      'new resume worktree root operations were '
          '${resume.newWorktreeRootOperations}, expected $_projectCount',
    if (resume.oldPeriodicTimers != 1)
      'old periodic timer count was ${resume.oldPeriodicTimers}, expected 1',
    if (resume.newPeriodicTimers != 1)
      'new periodic timer count was ${resume.newPeriodicTimers}, expected 1',
  ];

  print('');
  if (failures.isEmpty) {
    print('INVARIANTS: PASS');
    return;
  }

  for (final failure in failures) {
    stderr.writeln('INVARIANT FAILED: $failure');
  }
  exitCode = 1;
}

/// Historical dispatch: Timer.periodic callbacks called refresh with
/// `unawaited`, so every trigger starts another operation immediately.
Future<_BurstResult> _measureOldBurst() async {
  final probe = _OperationProbe(_slowRefresh);
  final watch = Stopwatch()..start();
  for (var i = 0; i < _burstTriggers; i++) {
    unawaited(probe.run());
  }
  await probe.drained;
  watch.stop();
  return probe.result(watch.elapsed);
}

/// Current dispatch: this imports and executes the production gate rather than
/// a benchmark-local approximation.
Future<_BurstResult> _measureNewBurst() async {
  final gate = CoalescingSingleFlight<String>();
  final probe = _OperationProbe(_slowRefresh);
  final watch = Stopwatch()..start();
  late final Future<void> drained;
  for (var i = 0; i < _burstTriggers; i++) {
    final run = gate.run('project', probe.run);
    if (i == 0) drained = run;
    unawaited(run);
  }
  await drained;
  watch.stop();
  return probe.result(watch.elapsed);
}

_InactiveResult _measureVirtualInactivity() {
  final ticks = _inactiveWindow.inMicroseconds ~/ _pollInterval.inMicroseconds;

  // Historical Timer.periodic kept firing. Every tick invoked _pollTick once,
  // which called onPoll once after dispatching one unawaited Git refresh per
  // target. That one onPoll callback then dispatched one unawaited worktree
  // operation per open root. Keep callback and root-level counts separate.
  final oldPollCallbacks = ticks;
  final oldGitRefreshOperations = ticks * _projectCount;
  final oldWorktreeRootOperations = ticks * _projectCount;

  // Current lifecycle cancels the periodic timer on the inactive transition.
  const newPollCallbacks = 0;
  const newGitRefreshOperations = 0;
  const newWorktreeRootOperations = 0;
  return _InactiveResult(
    oldPollCallbacks: oldPollCallbacks,
    newPollCallbacks: newPollCallbacks,
    oldGitRefreshOperations: oldGitRefreshOperations,
    newGitRefreshOperations: newGitRefreshOperations,
    oldWorktreeRootOperations: oldWorktreeRootOperations,
    newWorktreeRootOperations: newWorktreeRootOperations,
  );
}

_ResumeResult _measureResumeStorm() {
  // Historical code did not observe focus/restore. Its one Timer.periodic was
  // never cancelled, and these native events performed no immediate work.
  const oldImmediatePollCallbacks = 0;
  const oldGitRefreshOperations = 0;
  const oldWorktreeRootOperations = 0;
  const oldPeriodicTimers = 1;

  // Current lifecycle emits only on an active-state edge. Model the real
  // blur+minimize -> focus* -> restore* sequence used by the focused test.
  var focused = false;
  var minimized = true;
  var wasActive = false;
  var immediatePollCallbacks = 0;
  var gitRefreshOperations = 0;
  var worktreeRootOperations = 0;
  var periodicTimers = 0;

  void update({bool? nextFocused, bool? nextMinimized}) {
    focused = nextFocused ?? focused;
    minimized = nextMinimized ?? minimized;
    final isActive = focused && !minimized;
    if (!wasActive && isActive) {
      // The one coalesced _pollTick is a cycle/callback, not one Git/worktree
      // operation: it visits every target, then onPoll visits every open root.
      immediatePollCallbacks++;
      gitRefreshOperations += _projectCount;
      worktreeRootOperations += _projectCount;
      periodicTimers = 1; // _armPoll cancels/replaces instead of accumulating.
    }
    wasActive = isActive;
  }

  final focusEvents = _resumeEvents ~/ 2;
  final restoreEvents = _resumeEvents - focusEvents;
  for (var i = 0; i < focusEvents; i++) {
    update(nextFocused: true);
  }
  for (var i = 0; i < restoreEvents; i++) {
    update(nextMinimized: false);
  }

  return _ResumeResult(
    oldImmediatePollCallbacks: oldImmediatePollCallbacks,
    newImmediatePollCallbacks: immediatePollCallbacks,
    oldGitRefreshOperations: oldGitRefreshOperations,
    newGitRefreshOperations: gitRefreshOperations,
    oldWorktreeRootOperations: oldWorktreeRootOperations,
    newWorktreeRootOperations: worktreeRootOperations,
    oldPeriodicTimers: oldPeriodicTimers,
    newPeriodicTimers: periodicTimers,
  );
}

void _printTable(List<_Row> rows) {
  const scenarioWidth = 16;
  const metricWidth = 28;
  const valueWidth = 14;
  const changeWidth = 21;
  print(
    '${'Scenario'.padRight(scenarioWidth)} '
    '${'Metric'.padRight(metricWidth)} '
    '${'Old (repro)'.padLeft(valueWidth)} '
    '${'New'.padLeft(valueWidth)} '
    '${'Change'.padLeft(changeWidth)}',
  );
  print('-' * 97);
  for (final row in rows) {
    print(
      '${row.scenario.padRight(scenarioWidth)} '
      '${row.metric.padRight(metricWidth)} '
      '${row.oldValue.padLeft(valueWidth)} '
      '${row.newValue.padLeft(valueWidth)} '
      '${row.change.padLeft(changeWidth)}',
    );
  }
}

String _formatMicros(int micros) => '${(micros / 1000).toStringAsFixed(2)} ms';

String _countChange(num oldValue, num newValue) {
  if (oldValue == newValue) return 'no change';
  if (oldValue == 0) return '+$newValue';
  final percent = (oldValue - newValue) * 100 / oldValue;
  if (percent > 0) return '${percent.toStringAsFixed(1)}% less';
  return '${(-percent).toStringAsFixed(1)}% more';
}

String _durationDelta(int oldMicros, int newMicros) {
  final deltaMillis = (newMicros - oldMicros) / 1000;
  if (deltaMillis == 0) return 'no change';
  final sign = deltaMillis > 0 ? '+' : '';
  final direction = deltaMillis > 0 ? 'slower' : 'faster';
  return '$sign${deltaMillis.toStringAsFixed(2)} ms $direction';
}

class _OperationProbe {
  _OperationProbe(this.delay);

  final Duration delay;
  final Completer<void> _drained = Completer<void>();
  var calls = 0;
  var _running = 0;
  var peakConcurrency = 0;

  Future<void> get drained => _drained.future;

  Future<void> run() async {
    calls++;
    _running++;
    if (_running > peakConcurrency) peakConcurrency = _running;
    await Future<void>.delayed(delay);
    _running--;
    if (_running == 0 && !_drained.isCompleted) _drained.complete();
  }

  _BurstResult result(Duration drainTime) => _BurstResult(
    calls: calls,
    peakConcurrency: peakConcurrency,
    drainTime: drainTime,
  );
}

class _BurstResult {
  const _BurstResult({
    required this.calls,
    required this.peakConcurrency,
    required this.drainTime,
  });

  final int calls;
  final int peakConcurrency;
  final Duration drainTime;
}

class _TimingSummary {
  const _TimingSummary({required this.medianMicros, required this.p95Micros});

  factory _TimingSummary.from(List<_BurstResult> samples) {
    final sorted =
        samples.map((sample) => sample.drainTime.inMicroseconds).toList()
          ..sort();
    final median = sorted[sorted.length ~/ 2];
    final p95Index = ((sorted.length * 0.95).ceil() - 1).clamp(
      0,
      sorted.length - 1,
    );
    return _TimingSummary(medianMicros: median, p95Micros: sorted[p95Index]);
  }

  final int medianMicros;
  final int p95Micros;
}

class _InactiveResult {
  const _InactiveResult({
    required this.oldPollCallbacks,
    required this.newPollCallbacks,
    required this.oldGitRefreshOperations,
    required this.newGitRefreshOperations,
    required this.oldWorktreeRootOperations,
    required this.newWorktreeRootOperations,
  });

  final int oldPollCallbacks;
  final int newPollCallbacks;
  final int oldGitRefreshOperations;
  final int newGitRefreshOperations;
  final int oldWorktreeRootOperations;
  final int newWorktreeRootOperations;
}

class _ResumeResult {
  const _ResumeResult({
    required this.oldImmediatePollCallbacks,
    required this.newImmediatePollCallbacks,
    required this.oldGitRefreshOperations,
    required this.newGitRefreshOperations,
    required this.oldWorktreeRootOperations,
    required this.newWorktreeRootOperations,
    required this.oldPeriodicTimers,
    required this.newPeriodicTimers,
  });

  final int oldImmediatePollCallbacks;
  final int newImmediatePollCallbacks;
  final int oldGitRefreshOperations;
  final int newGitRefreshOperations;
  final int oldWorktreeRootOperations;
  final int newWorktreeRootOperations;
  final int oldPeriodicTimers;
  final int newPeriodicTimers;
}

class _Row {
  const _Row(
    this.scenario,
    this.metric,
    this.oldValue,
    this.newValue,
    this.change,
  );

  final String scenario;
  final String metric;
  final String oldValue;
  final String newValue;
  final String change;
}
