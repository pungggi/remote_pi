// Plan/148 — "Delete worktree & branch" confirmation.
// Pins the copy that makes the action recognisable BEFORE confirming: the
// branch, the base repo and the folder that disappears, plus the dirty-tree
// caveat (a git refusal must not read like a bug). Pure view widget; the
// palette falls back to the dark theme outside a themed tree.

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/home/widgets/cleanup_worktree_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _worktree = WireWorktree(
  id: 'w1',
  base: '/src/remote_pi',
  path: '/src/remote_pi_w1',
  branch: 'work/w1',
  createdAt: '2026-10-23T10:00:00Z',
);

Future<void> _open(WidgetTester tester, void Function(bool) onResult) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                final ok = await showCleanupWorktreeDialog(
                  ctx,
                  sessionTitle: 'exp-v2',
                  worktree: _worktree,
                );
                onResult(ok);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('names session, branch, base repo and folder', (tester) async {
    await _open(tester, (_) {});

    expect(find.text('Delete worktree & branch?'), findsOneWidget);
    expect(find.text('exp-v2'), findsOneWidget);
    expect(find.text('work/w1'), findsOneWidget);
    expect(find.text('/src/remote_pi'), findsOneWidget);
    expect(find.text('/src/remote_pi_w1'), findsOneWidget);
    // The safety story must be visible before the user taps Delete.
    expect(find.textContaining('Uncommitted'), findsOneWidget);
    expect(find.textContaining('refused by git'), findsOneWidget);
  });

  testWidgets('Cancel resolves false, Delete resolves true', (tester) async {
    final results = <bool>[];
    await _open(tester, results.add);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(results, [false]);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(results, [false, true]);
  });
}
