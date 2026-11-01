import 'package:app/data/preferences/preferences.dart' show HomeGroupBy;
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart'
    show PlanUsage, PlanUsageWindow, RoomInfo;
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
      // One mono text: every window, ordered shortest-first (5h before wk
      // before mo), as the user chose ("all windows incl. 5h").
      expect(find.textContaining('5h 3% · wk 4% · mo 0%'), findsOneWidget);
      // Bar width tracks the WORST window (wk 4%).
      final bar = tester.widget<AnimatedFractionallySizedBox>(
        find.byType(AnimatedFractionallySizedBox),
      );
      expect(bar.widthFactor, closeTo(0.04, 0.0001));
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

    testWidgets('zero usage renders text but no bar', (tester) async {
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

      expect(find.textContaining('5h 0%'), findsOneWidget);
      expect(find.byType(AnimatedFractionallySizedBox), findsNothing);
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

      expect(find.textContaining('resets 2h 14m'), findsOneWidget);
    });

    testWidgets('countdown ticks down every minute without a new push (PR #89 review)',
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
      expect(find.textContaining('resets 2h 14m'), findsOneWidget);

      // 2 minutes of wall time, no plan_usage push in between: the header's
      // own 1-min ticker must rebuild the countdown twice.
      await tester.pump(const Duration(minutes: 1));
      expect(find.textContaining('resets 2h 13m'), findsOneWidget);
      await tester.pump(const Duration(minutes: 1));
      expect(find.textContaining('resets 2h 12m'), findsOneWidget);
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
}
