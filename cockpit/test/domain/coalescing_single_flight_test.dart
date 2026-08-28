import 'dart:async';

import 'package:cockpit/app/cockpit/domain/utils/coalescing_single_flight.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a burst has maximum concurrency 1 and at most one rerun', () async {
    final gate = CoalescingSingleFlight<String>();
    final releases = <Completer<void>>[];
    var running = 0;
    var maxRunning = 0;
    var runs = 0;

    Future<void> operation() async {
      runs++;
      running++;
      if (running > maxRunning) maxRunning = running;
      final release = Completer<void>();
      releases.add(release);
      await release.future;
      running--;
    }

    final first = gate.run('repo', operation);
    gate.run('repo', operation);
    gate.run('repo', operation);
    expect(runs, 1);

    releases.first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(runs, 2, reason: 'the burst schedules exactly one rerun');

    gate.run('repo', operation);
    gate.run('repo', operation);
    releases.last.complete();
    await first;

    expect(maxRunning, 1);
    expect(
      runs,
      2,
      reason: 'calls during the rerun do not schedule a third run',
    );
  });
}
