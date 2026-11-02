import 'package:app/data/preferences/preferences.dart' show HomeGroupBy;
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart'
    show
        PlanResetCard,
        PlanResetResult,
        PlanUsage,
        PlanUsageWindow,
        ResetCardInventory,
        ResetCardKindInventory,
        RoomInfo;
import 'package:app/ui/home/states/home_state.dart'
    show HomeGroup, HomeItem, firstOnlinePlanUsage;
import 'package:app/ui/home/widgets/session_grouping.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Plan/156 — shared fixture: the decoded shape of the real z.ai Max-plan
  // response (mo MCP credits + 5h prompts + weekly tokens).
  const planUsageFixture = PlanUsage(
    provider: 'zai',
    plan: 'max',
    fetchedAt: 1,
    windows: [
      PlanUsageWindow(kind: 'time', label: 'mo', percent: 0, minutes: 43200),
      PlanUsageWindow(kind: 'tokens', label: '5h', percent: 3, minutes: 300),
      PlanUsageWindow(
          kind: 'tokens', label: 'wk', percent: 4, minutes: 10080),
    ],
  );

  group('HomeGroupingControl', () {
    testWidgets('shows the selected mode and reports changes', (tester) async {
      HomeGroupBy? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeGroupingControl(
              value: HomeGroupBy.model,
              onChanged: (value) => changed = value,
            ),
          ),
        ),
      );

      final control = tester.widget<SegmentedButton<HomeGroupBy>>(
        find.byType(SegmentedButton<HomeGroupBy>),
      );
      expect(control.selected, {HomeGroupBy.model});
      expect(find.text('GROUP BY'), findsOneWidget);
      expect(find.text('Model'), findsOneWidget);
      expect(find.text('Repo'), findsOneWidget);

      await tester.tap(find.text('Repo'));
      expect(changed, HomeGroupBy.repository);
    });
  });

  group('SessionGroupHeader', () {
    testWidgets('shows the group label and session count', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SessionGroupHeader(label: 'pungggi/pi-reflex', count: 2),
          ),
        ),
      );

      expect(find.text('pungggi/pi-reflex'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });
  });

  group('SessionGroupHeader plan usage (plan/156)', () {
    const usage = planUsageFixture;

    testWidgets('renders all windows shortest-first, count, and the bar',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SessionGroupHeader(label: 'GLM-4.6', count: 3, usage: usage),
          ),
        ),
      );

      expect(find.text('GLM-4.6'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      // Plan/156.2 — windows at 0% are NOT shown (space): the mo MCP marker
      // sits at 0% almost always. Non-zero windows stay shortest-first.
      expect(find.textContaining('5h 3% · wk 4%'), findsOneWidget);
      expect(find.textContaining('mo'), findsNothing);
      // Plan/156.1 — bar width tracks the SHORTEST non-zero window (5h 3%).
      final bar = tester.widget<AnimatedFractionallySizedBox>(
        find.byType(AnimatedFractionallySizedBox),
      );
      expect(bar.widthFactor, closeTo(0.03, 0.0001));
    });

    testWidgets('all-zero usage renders no usage line and no bar (plan/156.2)',
        (tester) async {
      const zero = PlanUsage(
        provider: 'zai',
        fetchedAt: 1,
        windows: [
          PlanUsageWindow(kind: 'tokens', label: '5h', percent: 0, minutes: 300),
        ],
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SessionGroupHeader(label: 'GLM-4.6', count: 1, usage: zero)),
        ),
      );

      expect(find.textContaining('%'), findsNothing);
      expect(find.byType(AnimatedFractionallySizedBox), findsNothing);
    });

    testWidgets('0% shortest lane is skipped: text and bar fall to weekly (plan/156.2)',
        (tester) async {
      const rolled = PlanUsage(
        provider: 'zai',
        fetchedAt: 1,
        windows: [
          PlanUsageWindow(kind: 'tokens', label: '5h', percent: 0, minutes: 300),
          PlanUsageWindow(
              kind: 'tokens', label: 'wk', percent: 40, minutes: 10080),
        ],
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
              body: SessionGroupHeader(label: 'GLM-4.6', count: 1, usage: rolled)),
        ),
      );

      // 5h at 0% is no constraint — hidden; weekly carries the line + bar.
      expect(find.textContaining('wk 40%'), findsOneWidget);
      expect(find.textContaining('5h'), findsNothing);
      final bar = tester.widget<AnimatedFractionallySizedBox>(
        find.byType(AnimatedFractionallySizedBox),
      );
      expect(bar.widthFactor, closeTo(0.40, 0.0001));
    });

    testWidgets('bar falls back to weekly when the 5h window is absent (plan/156.1)',
        (tester) async {
      const wkOnly = PlanUsage(
        provider: 'zai',
        fetchedAt: 1,
        windows: [
          PlanUsageWindow(
              kind: 'tokens', label: 'wk', percent: 4, minutes: 10080),
        ],
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
              body: SessionGroupHeader(label: 'GLM-4.6', count: 1, usage: wkOnly)),
        ),
      );

      expect(find.textContaining('wk 4%'), findsOneWidget);
      final bar = tester.widget<AnimatedFractionallySizedBox>(
        find.byType(AnimatedFractionallySizedBox),
      );
      expect(bar.widthFactor, closeTo(0.04, 0.0001));
    });

    testWidgets('each window is tinted by its own pressure (plan/156.1)',
        (tester) async {
      const pressure = PlanUsage(
        provider: 'zai',
        fetchedAt: 1,
        windows: [
          PlanUsageWindow(
              kind: 'tokens', label: '5h', percent: 90, minutes: 300),
          PlanUsageWindow(
              kind: 'tokens', label: 'wk', percent: 10, minutes: 10080),
        ],
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
              body: SessionGroupHeader(label: 'GLM-4.6', count: 1, usage: pressure)),
        ),
      );

      final text = tester.widget<Text>(find.textContaining('5h 90%'));
      final children = (text.textSpan as TextSpan?)?.children
              ?.whereType<TextSpan>()
              .toList() ??
          const <TextSpan>[];
      expect(children.length, 3, reason: 'window · separator · window');
      final fiveHour = children[0].style!.color;
      final weekly = children[2].style!.color;
      // Pressure ladder is per window: a 90% lane reads as error while a
      // 10% lane stays calm — one shared tint could never differ.
      expect(fiveHour, isNot(equals(weekly)));
      // The pressure bar (5h is the shortest) matches the 90% error tint
      // family, not the calm weekly one.
      final bar = tester.widget<AnimatedFractionallySizedBox>(
        find.byType(AnimatedFractionallySizedBox),
      );
      expect(bar.widthFactor, closeTo(0.90, 0.0001));
    });

    testWidgets('the usage line is centered in the header (plan/156.1)',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SessionGroupHeader(label: 'GLM-4.6', count: 3, usage: usage),
          ),
        ),
      );

      final headerCenter = tester.getCenter(
        find.byType(SessionGroupHeader),
      );
      final usageCenter = tester.getCenter(find.textContaining('5h 3%'));
      // Truly centered between label and count — not end-packed next to
      // the count (Stack overlay, not a Row slot).
      expect(usageCenter.dx, closeTo(headerCenter.dx, 1.0));
    });

    testWidgets('no usage → plain header, no bar', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SessionGroupHeader(label: 'GLM-4.6', count: 1),
          ),
        ),
      );

      expect(find.text('GLM-4.6'), findsOneWidget);
      expect(find.byType(AnimatedFractionallySizedBox), findsNothing);
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('countdown text appears when a reset is plausible',
        (tester) async {
      final reset = DateTime.now().millisecondsSinceEpoch +
          const Duration(hours: 2, minutes: 14).inMilliseconds;
      final withReset = PlanUsage(
        provider: 'zai',
        fetchedAt: 1,
        windows: [
          PlanUsageWindow(
            kind: 'tokens', label: '5h', percent: 30, minutes: 300, resetAt: reset),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionGroupHeader(label: 'GLM-4.6', count: 1, usage: withReset),
          ),
        ),
      );

      // Plan/157: exact datetime (weekday + HH:mm for the 5h lane), not
      // remaining time. The spans render inside ONE RichText.
      final rich = tester.widget<RichText>(find.byType(RichText).first);
      final plain = rich.text.toPlainText();
      expect(plain, contains('⏳ '));
      expect(RegExp(r'⏳ (Mo|Di|Mi|Do|Fr|Sa|So)\. \d{2}:\d{2}').hasMatch(plain),
          isTrue,
          reason: '5h lane must render weekday + HH:mm, got: $plain');
    });

    test('debugFormatReset — German reset datetime shapes (plan/157)', () {
      // 2026-11-06 is a Friday; constructed LOCAL (no TZ dependency).
      final d = DateTime(2026, 11, 6, 15, 14);
      expect(SessionGroupHeader.debugFormatReset(d, 300), 'Fr. 15:14');
      expect(SessionGroupHeader.debugFormatReset(d, 10080), 'Fr. 6.11 15:14');
      expect(SessionGroupHeader.debugFormatReset(d, 43200), 'Fr. 6. Nov');
      // Unknown window length falls back to distance-based shaping.
      expect(SessionGroupHeader.debugFormatReset(d, null, msLeft: 3 * 3600000),
          'Fr. 15:14');
      expect(
          SessionGroupHeader.debugFormatReset(d, null, msLeft: 5 * 24 * 3600000),
          'Fr. 6.11 15:14');
      expect(
          SessionGroupHeader.debugFormatReset(d, null, msLeft: 25 * 24 * 3600000),
          'Fr. 6. Nov');
      // Leading-zero sanity: day/month stay unpadded.
      final d2 = DateTime(2026, 12, 3, 5, 7); // Thursday 3.12
      expect(SessionGroupHeader.debugFormatReset(d2, 10080), 'Do. 3.12 05:07');
    });

    testWidgets('deadline label drops once the reset passes (PR #89 ticker)',
        (tester) async {
      // Pin "now": the fake async clock advances timers but not
      // DateTime.now(), so the header computes against this fixed instant
      // (shifted by however far the fake clock has advanced).
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final fakeBase = tester.binding.clock.now().millisecondsSinceEpoch;
      SessionGroupHeader.debugNowMs = () =>
          t0 +
          (tester.binding.clock.now().millisecondsSinceEpoch - fakeBase);
      addTearDown(() => SessionGroupHeader.debugNowMs = null);
      final reset = t0 + const Duration(hours: 2, minutes: 14).inMilliseconds;
      String plainText() {
        final rich = tester.widget<RichText>(find.byType(RichText).first);
        return rich.text.toPlainText();
      }

      final usage = PlanUsage(
        provider: 'zai',
        fetchedAt: 1,
        windows: [
          PlanUsageWindow(
              kind: 'tokens', label: '5h', percent: 30, minutes: 300, resetAt: reset),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionGroupHeader(label: 'GLM-4.6', count: 1, usage: usage),
          ),
        ),
      );
      expect(plainText(), contains('⏳'));

      // 2h15m of wall time with no plan_usage push: the header's own 1-min
      // ticker must notice the reset has passed and drop the label.
      await tester.pump(const Duration(hours: 2, minutes: 15));
      await tester.pump();
      expect(plainText(), isNot(contains('⏳')));
    });
  });

  group('firstOnlinePlanUsage (plan/156)', () {
    const peer = PeerRecord(
      remoteEpk: 'epk',
      sessionName: 'pi',
      relayUrl: 'ws://localhost',
      pairedAt: '2026-01-01T00:00:00Z',
    );

    HomeItem item(String room, {PlanUsage? usage}) => HomeItem(
      peer: peer,
      room: RoomInfo(roomId: room, startedAt: 1, planUsage: usage),
    );

    HomeGroup groupOf(List<HomeItem> items) =>
        HomeGroup(label: 'GLM-4.6', items: items);

    test('null when every session is offline (stale quota stays hidden)', () {
      final g = groupOf([item('a', usage: planUsageFixture), item('b')]);
      expect(firstOnlinePlanUsage(g, (_) => false), isNull);
    });

    test('first ONLINE session with usage wins', () {
      final g = groupOf([
        item('offline-with-usage', usage: planUsageFixture),
        item('live'),
      ]);
      expect(firstOnlinePlanUsage(g, (it) => it.room.roomId == 'live'), isNull,
          reason: 'the online room has no usage; offline data must not leak');

      final g2 = groupOf([
        item('a', usage: planUsageFixture),
        item('b', usage: planUsageFixture),
      ]);
      final got = firstOnlinePlanUsage(g2, (it) => it.room.roomId == 'b');
      expect(got?.provider, 'zai');
    });

    test('no usage anywhere → null even when online', () {
      final g = groupOf([item('a'), item('b')]);
      expect(firstOnlinePlanUsage(g, (_) => true), isNull);
    });
  });

  group('reset cards (plan/157)', () {
    ResetCardInventory cards({int week = 0, int fiveHour = 0}) =>
        ResetCardInventory(
          week: ResetCardKindInventory(
              count: week, earliestExpire: week > 0 ? '2026-12-01 23:59:59' : null),
          fiveHour: ResetCardKindInventory(count: fiveHour),
        );

    PlanUsage usageWith({required int wkPct, required int fivePct, ResetCardInventory? inv}) =>
        PlanUsage(
          provider: 'zai',
          fetchedAt: 1,
          windows: [
            PlanUsageWindow(
                kind: 'tokens', label: '5h', percent: fivePct, minutes: 300),
            PlanUsageWindow(
                kind: 'tokens', label: 'wk', percent: wkPct, minutes: 10080),
          ],
          resetCards: inv,
        );

    test('PlanUsage.resetCards parses (and stays null when absent)', () {
      final j = {
        'provider': 'zai',
        'fetchedAt': 1,
        'windows': [
          {'kind': 'tokens', 'label': 'wk', 'percent': 100, 'minutes': 10080},
        ],
        'resetCards': {
          'fiveHour': {'count': 0, 'earliestExpire': null},
          'week': {'count': 3, 'earliestExpire': '2026-12-22 23:59:59'},
        },
      };
      final u = PlanUsage.fromJson(j)!;
      expect(u.resetCards?.week.count, 3);
      expect(u.resetCards?.week.earliestExpire, '2026-12-22 23:59:59');
      expect(u.resetCards?.fiveHour.count, 0);
      // Roundtrip of the new field (windows carry legacy always-present
      // null keys; toJson omits null earliestExpire — both shapes parse).
      final out = u.toJson()['resetCards'] as Map<String, dynamic>?;
      expect(out?['week'], (j['resetCards'] as Map)['week']);
      expect(((out?['fiveHour']) as Map?)?['count'], 0);
      expect(
        ResetCardInventory.fromJson(Map<String, dynamic>.from(out!))..toString(),
        u.resetCards,
      );
      // Absent field (inventory call failed extension-side) → null.
      expect(
          PlanUsage.fromJson({
            ...j,
            'resetCards': null,
          })!.resetCards,
          isNull);
    });

    test('PlanResetCard wire shape', () {
      expect(PlanResetCard(id: 'r1', kind: 'week').toJson(), {
        'type': 'plan_reset_card_request',
        'id': 'r1',
        'kind': 'week',
      });
    });

    test('PlanResetResult parses ok/failure shapes', () {
      expect(
        PlanResetResult.fromJson({
          'type': 'plan_reset_card_result',
          'in_reply_to': 'r1',
          'ok': true,
          'kind': 'week',
          'remaining': 1,
          'message': null,
        }),
        isA<PlanResetResult>().having((r) => r.ok, 'ok', isTrue),
      );
      final fail = PlanResetResult.fromJson({
        'type': 'plan_reset_card_result',
        'in_reply_to': 'r1',
        'ok': false,
        'kind': 'week',
        'remaining': 2,
        'message': 'card expired',
      });
      expect(fail.ok, isFalse);
      expect(fail.message, 'card expired');
    });

    test('redeemableCardKind — weekly priority, exhaustion gate, null rules',
        () {
      // Weekly exhausted + week cards → week (even when 5h also dead and
      // 5h cards exist — weekly restores both).
      expect(
        usageWith(wkPct: 100, fivePct: 100, inv: cards(week: 2, fiveHour: 1))
            .redeemableCardKind(),
        'week');
      // Only 5h dead + 5h cards → five_hour.
      expect(
        usageWith(wkPct: 40, fivePct: 100, inv: cards(fiveHour: 1))
            .redeemableCardKind(),
        'five_hour');
      // Exhausted but no cards of that kind → null.
      expect(usageWith(wkPct: 100, fivePct: 40, inv: cards()).redeemableCardKind(),
          isNull);
      // 5h dead, 5h cards, but weekly ALSO dead with NO week cards →
      // five_hour (weekly rule doesn't apply without weekly cards).
      expect(
        usageWith(wkPct: 100, fivePct: 100, inv: cards(fiveHour: 2))
            .redeemableCardKind(),
        'five_hour');
      // Not exhausted → null even with cards.
      expect(
        usageWith(wkPct: 94, fivePct: 60, inv: cards(week: 3))
            .redeemableCardKind(),
        isNull);
      // No inventory at all → null.
      expect(usageWith(wkPct: 100, fivePct: 100).redeemableCardKind(), isNull);
    });

    Future<void> pumpHeader(
      WidgetTester tester, {
      required PlanUsage usage,
      void Function(String kind)? onRedeem,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SessionGroupHeader(
            label: 'GLM-4.6',
            count: 1,
            usage: usage,
            onRedeemResetCard: onRedeem,
          ),
        ),
      ));
    }

    testWidgets('chip 🔄×N shows for exhausted weekly + cards; tap fires kind',
        (tester) async {
      String? fired;
      await pumpHeader(
        tester,
        usage: usageWith(wkPct: 100, fivePct: 100, inv: cards(week: 2)),
        onRedeem: (kind) => fired = kind,
      );
      expect(find.text('🔄×2'), findsOneWidget);
      await tester.tap(find.text('🔄×2'));
      expect(fired, 'week');
    });

    testWidgets('chip falls back to five_hour when only the 5h lane is dead',
        (tester) async {
      String? fired;
      await pumpHeader(
        tester,
        usage: usageWith(wkPct: 40, fivePct: 100, inv: cards(fiveHour: 1)),
        onRedeem: (kind) => fired = kind,
      );
      expect(find.text('🔄×1'), findsOneWidget);
      await tester.tap(find.text('🔄×1'));
      expect(fired, 'five_hour');
    });

    testWidgets('no chip below 100% — even with a pile of cards',
        (tester) async {
      await pumpHeader(
        tester,
        usage: usageWith(wkPct: 99, fivePct: 60, inv: cards(week: 3)),
        onRedeem: (_) {},
      );
      expect(find.textContaining('🔄'), findsNothing);
    });

    testWidgets('no chip without a wired handler (safety: display-only)',
        (tester) async {
      await pumpHeader(
        tester,
        usage: usageWith(wkPct: 100, fivePct: 100, inv: cards(week: 3)),
      );
      expect(find.textContaining('🔄'), findsNothing);
    });
  });
}
