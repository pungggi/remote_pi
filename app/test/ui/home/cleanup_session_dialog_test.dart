// Plan/158 — the consolidated "Clean up session?" confirmation.
// Pins the itemized contract BEFORE confirming: which destructive steps run
// (worktree checkbox when a tracked worktree matched), that history deletion
// is opt-in OFF by default, and that the two non-negotiable parts (PC forgets
// the room → no resurrection; phone copy removed) are spelled out as "Always".
// Pure view widget; the palette falls back to the dark theme outside a themed
// tree.

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/home/widgets/cleanup_session_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _worktree = WireWorktree(
  id: 'w1',
  base: '/src/remote_pi',
  path: '/src/remote_pi_w1',
  branch: 'work/w1',
  createdAt: '2026-10-23T10:00:00Z',
);

Future<void> _open(
  WidgetTester tester,
  void Function(CleanupSessionRequest?) onResult, {
  WireWorktree? worktree = _worktree,
  GhRef? ghRef,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                final req = await showCleanupSessionDialog(
                  ctx,
                  sessionTitle: 'exp-v2',
                  worktree: worktree,
                  ghRef: ghRef,
                );
                onResult(req);
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
  testWidgets('names session, branch and folder when a worktree matched', (
    tester,
  ) async {
    await _open(tester, (_) {});

    expect(find.text('Clean up session?'), findsOneWidget);
    expect(find.text('exp-v2'), findsOneWidget);
    expect(find.text('work/w1'), findsOneWidget);
    expect(find.text('/src/remote_pi_w1'), findsOneWidget);
    // The worktree row exists and starts CHECKED (the clutter case).
    final worktreeCheck = tester.widget<Checkbox>(
      find.descendant(
        of: find.byKey(const Key('cleanup-worktree-check')),
        matching: find.byType(Checkbox),
      ),
    );
    expect(worktreeCheck.value, isTrue);
    // The dirty-tree safety story must be visible before confirming.
    expect(find.textContaining('refused by git'), findsOneWidget);
    // The non-negotiable parts are labelled as such.
    expect(find.textContaining('forgets this session'), findsOneWidget);
    expect(find.textContaining('phone is removed'), findsOneWidget);
  });

  testWidgets('history deletion is OFF by default (user decision '
      '2026-11-06) and follows the checkbox', (tester) async {
    final results = <CleanupSessionRequest?>[];
    await _open(tester, results.add);

    final historyFinder = find.descendant(
      of: find.byKey(const Key('cleanup-history-check')),
      matching: find.byType(Checkbox),
    );
    expect(
      tester.widget<Checkbox>(historyFinder).value,
      isFalse,
      reason: 'cleanup stops the session from SHOWING; transcripts stay as '
          'backup unless explicitly asked',
    );

    await tester.tap(historyFinder);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(historyFinder).value, isTrue);

    await tester.tap(find.text('Clean up'));
    await tester.pumpAndSettle();
    expect(results.single?.deleteHistory, isTrue);
    // Worktree row untouched → still confirmed as checked.
    expect(results.single?.removeWorktree, isTrue);
  });

  testWidgets('Cancel resolves null, confirm carries the checkboxes', (
    tester,
  ) async {
    final results = <CleanupSessionRequest?>[];
    await _open(tester, results.add);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(results, [null]);

    // Re-open, untick the worktree, confirm.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final worktreeFinder = find.descendant(
      of: find.byKey(const Key('cleanup-worktree-check')),
      matching: find.byType(Checkbox),
    );
    await tester.tap(worktreeFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clean up'));
    await tester.pumpAndSettle();
    expect(results.last?.removeWorktree, isFalse);
    expect(results.last?.deleteHistory, isFalse);
  });

  testWidgets('no tracked worktree → no worktree row, request keeps '
      'removeWorktree false (forget + local delete only)', (tester) async {
    final results = <CleanupSessionRequest?>[];
    await _open(tester, results.add, worktree: null);

    expect(find.text('work/w1'), findsNothing);
    expect(find.byKey(const Key('cleanup-worktree-check')), findsNothing);
    expect(find.byKey(const Key('cleanup-history-check')), findsOneWidget);

    await tester.tap(find.text('Clean up'));
    await tester.pumpAndSettle();
    expect(results.single?.removeWorktree, isFalse);
    expect(results.single?.deleteHistory, isFalse);
  });

  testWidgets('open PR → warning row (plan/148 rule carried over)', (
    tester,
  ) async {
    await _open(
      tester,
      (_) {},
      ghRef: const GhRef(
        pr: GhRefSlot(number: 42, state: 'OPEN'),
      ),
    );
    expect(find.text('PR #42'), findsOneWidget);
    expect(find.textContaining('can break the PR'), findsOneWidget);
  });
}
