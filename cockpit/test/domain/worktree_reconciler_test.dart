import 'dart:async';

import 'package:cockpit/app/cockpit/domain/contracts/worktree_manager.dart';
import 'package:cockpit/app/cockpit/domain/entities/worktree.dart';
import 'package:cockpit/app/cockpit/domain/services/worktree_reconciler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('blocking WorktreeManager is single-flight with one rerun', () async {
    final manager = _BlockingWorktreeManager();
    final reconciler = WorktreeReconciler(manager);

    Future<void> operation(WorktreeManager worktrees) async {
      await worktrees.list('/repo');
    }

    final first = reconciler.run('root', operation);
    reconciler.run('root', operation);
    reconciler.run('root', operation);
    expect(manager.runs, 1);

    manager.releaseNext();
    await Future<void>.delayed(Duration.zero);
    expect(manager.runs, 2, reason: 'current operation plus one rerun');

    reconciler.run('root', operation);
    reconciler.run('root', operation);
    manager.releaseNext();
    await first;

    expect(manager.maxConcurrent, 1);
    expect(
      manager.runs,
      2,
      reason: 'calls during rerun do not add a third run',
    );
  });
}

class _BlockingWorktreeManager implements WorktreeManager {
  final List<Completer<void>> _releases = [];
  var runs = 0;
  var concurrent = 0;
  var maxConcurrent = 0;

  @override
  Future<List<Worktree>> list(String repoPath) async {
    runs++;
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    final release = Completer<void>();
    _releases.add(release);
    await release.future;
    concurrent--;
    return const [];
  }

  void releaseNext() =>
      _releases.firstWhere((item) => !item.isCompleted).complete();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
