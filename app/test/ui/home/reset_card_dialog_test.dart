import 'package:app/ui/home/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Plan/157 — the reset-card redemption CONSENT GATE: nothing may reach the
/// wire unless the user explicitly pressed Redeem. Cancel, and a barrier
/// dismiss, must both return false.
void main() {
  Future<void> pumpOpener(WidgetTester tester, ValueSetter<bool?> done) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                done(await HomePage.showResetCardConfirm(
                  ctx,
                  weekly: true,
                  remainingAfter: 1,
                  earliestExpire: '2026-12-01 23:59:59',
                ));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('dialog shows kind, remaining count, expiry; Redeem → true',
      (tester) async {
    bool? result;
    await pumpOpener(tester, (v) => result = v);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Redeem weekly reset card?'), findsOneWidget);
    expect(
        find.textContaining('1 card(s) left after this'), findsOneWidget);
    expect(find.textContaining('2026-12-01 23:59:59'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);

    await tester.tap(find.text('Redeem'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('Cancel → false (nothing would be sent)', (tester) async {
    bool? result;
    await pumpOpener(tester, (v) => result = v);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('barrier dismiss → false, never null/true', (tester) async {
    bool? result;
    await pumpOpener(tester, (v) => result = v);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(10, 10)); // outside the dialog
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('5h wording for five_hour kind', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => HomePage.showResetCardConfirm(
                ctx,
                weekly: false,
                remainingAfter: 0,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Redeem 5h reset card?'), findsOneWidget);
    expect(find.textContaining('Resets the 5h window'), findsOneWidget);
  });
}
