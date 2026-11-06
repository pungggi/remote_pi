// Plan/158 — the batch cleanup sheet's result pairing + failure isolation.
// PR #94 review regression pins:
//   1. Results pair by (epk, roomId) identity, never by index — the VM
//      groups work per PC and _run may run a SUBSET of the plans, so index
//      pairing showed the wrong session titles (HIGH finding).
//   2. An unexpected onConfirm exception must not leave the sheet stuck on
//      "Cleaning up…" — it becomes failure reports (LOW finding).
// Pure view widget; the palette falls back to the dark theme outside a
// themed tree (same pattern as cleanup_session_dialog_test.dart).

import 'package:app/ui/home/viewmodels/session_cleanup_report.dart';
import 'package:app/ui/home/widgets/cleanup_batch_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SessionCleanupPlan _plan(String epk, String roomId, String title) =>
    SessionCleanupPlan(epk: epk, roomId: roomId, sessionTitle: title);

Future<void> _open(
  WidgetTester tester, {
  required CleanupBatchPrep prep,
  required Future<List<SessionCleanupReport>> Function(
    List<SessionCleanupPlan>,
    bool,
  )
  onConfirm,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CleanupBatchSheet(prep: prep, onConfirm: onConfirm),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final plans = [
    _plan('epk_A', 'r1', 'S1 · work/w1'),
    _plan('epk_A', 'r9', 'S9 · main-checkout'),
    _plan('epk_B', 'b1', 'B1 · other'),
  ];

  testWidgets('results pair by identity when a SUBSET ran, reports '
      'scrambled', (tester) async {
    await _open(
      tester,
      prep: CleanupBatchPrep(plans: plans, unreachablePeers: const []),
      onConfirm: (selected, _) async {
        // The VM honors the input order of the GIVEN (selected) plans, but
        // this stub scrambles on purpose: pairing must survive it.
        expect(selected.map((p) => p.roomId), ['r9', 'b1']);
        return [
          SessionCleanupReport(epk: 'epk_B', roomId: 'b1', ok: false, message: 'no worktree — kept'),
          SessionCleanupReport(epk: 'epk_A', roomId: 'r9', ok: true, message: 'forgotten'),
        ];
      },
    );

    // Uncheck the first row, run the remaining two.
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('cleanup-batch-row-0')),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clean up 2'));
    await tester.pumpAndSettle();

    expect(find.text('Cleanup results'), findsOneWidget);
    // The UNSELECTED plan's title must not appear, the two selected ones
    // must — under the old index pairing, r9's row showed S1's title.
    expect(find.text('S1 · work/w1'), findsNothing);
    expect(find.text('S9 · main-checkout'), findsOneWidget);
    expect(find.text('B1 · other'), findsOneWidget);
    expect(find.text('forgotten'), findsOneWidget);
    expect(find.text('no worktree — kept'), findsOneWidget);
  });

  testWidgets('an unexpected onConfirm exception becomes failure rows, '
      'not a stuck sheet', (tester) async {
    await _open(
      tester,
      prep: CleanupBatchPrep(plans: plans, unreachablePeers: const []),
      onConfirm: (_, _) async => throw StateError('boom'),
    );

    await tester.tap(find.text('Clean up 3'));
    await tester.pumpAndSettle();

    expect(find.text('Cleaning up…'), findsNothing);
    expect(find.text('Cleanup results'), findsOneWidget);
    expect(find.textContaining('Unexpected error'), findsExactly(3));
  });
}
