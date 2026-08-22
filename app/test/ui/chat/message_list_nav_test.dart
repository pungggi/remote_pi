// Regression test (bug 2026-08-21): "navigate between user messages
// doesn't work at all".
//
// `_jump` used to bail with `ctx == null → return` whenever the target
// user message sat beyond the ListView's lazy build window (viewport ±
// 1500px cache). With long agent replies between questions — the normal
// case in real transcripts — the neighbouring question is >2 screens away,
// so BOTH nav buttons were silent no-ops. The fix hops one viewport at a
// time toward the target until the builder mounts it, then centers it.
//
// These tests mount `MessageList` directly (it is public for exactly this
// reason) with replies tall enough to push the target far outside the
// cache, and assert the hop lands on the question.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_page.dart';

/// ~130 markdown lines ≈ 2.5k px — well beyond viewport (800) + cacheExtent
/// (1500), so the adjacent user message is NOT built until we hop to it.
String _tallReply() => List.filled(130, 'filler line to make the reply tall')
    .join('\n');

List<ChatMessage> _transcript() => [
      UserMsg(id: 'u0', text: 'question zero'),
      AssistantMsg(id: 'a0', text: _tallReply()),
      UserMsg(id: 'u1', text: 'question one'),
      AssistantMsg(id: 'a1', text: _tallReply()),
      UserMsg(id: 'u2', text: 'question two'),
    ];

/// Two questions with one-line replies — the whole transcript fits the
/// 800px test viewport (scroll extents are equal), so end jumps have
/// nothing to animate and must still re-anchor the guided pointer.
List<ChatMessage> _shortTranscript() => [
      UserMsg(id: 'u0', text: 'question zero'),
      AssistantMsg(id: 'a0', text: 'ok'),
      UserMsg(id: 'u1', text: 'question one'),
    ];

Widget _harness(
  List<ChatMessage> messages, {
  StreamingMessage? streaming,
}) => MaterialApp(
      home: Scaffold(
        body: MessageList(
          messages: messages,
          streaming: streaming,
          onDecide: (_, _) {},
          truncated: false,
        ),
      ),
    );

/// Drives the async hop chain to completion. `pumpAndSettle` alone can stop
/// between two hops (the next `animateTo` is scheduled in a microtask after
/// settle's "no frames pending" check), so pump explicit clock time first.
Future<void> _settleJumps(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'jump-to-older hops across a reply taller than the build cache',
    (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(_transcript()));
      await tester.pumpAndSettle();

      // Start pinned at the newest (reverse list → offset 0 = bottom).
      // `question one` is >1500px above the viewport → not built yet.
      expect(find.textContaining('question two'), findsOneWidget);
      expect(find.textContaining('question one'), findsNothing);

      // Before the fix this press was a silent no-op (no context, no hop).
      await tester.tap(find.byKey(const ValueKey('chat-nav-older')));
      await _settleJumps(tester);

      expect(find.textContaining('question one'), findsOneWidget);
      final dy = tester.getCenter(find.textContaining('question one')).dy;
      expect(dy, greaterThan(0));
      expect(dy, lessThan(800)); // centered in the viewport
      expect(find.text('2/3'), findsOneWidget); // guided counter

      // Second hop — another tall reply further up.
      await tester.tap(find.byKey(const ValueKey('chat-nav-older')));
      await _settleJumps(tester);

      expect(find.textContaining('question zero'), findsOneWidget);
      final dy0 = tester.getCenter(find.textContaining('question zero')).dy;
      expect(dy0, greaterThan(0));
      expect(dy0, lessThan(800));
      expect(find.text('1/3'), findsOneWidget);
    },
  );

  testWidgets('newer is bounded at the newest user message', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(_transcript()));
    await tester.pumpAndSettle();

    // Walk to the oldest question, then back down to the newest.
    await tester.tap(find.byKey(const ValueKey('chat-nav-older')));
    await _settleJumps(tester);
    await tester.tap(find.byKey(const ValueKey('chat-nav-older')));
    await _settleJumps(tester);
    expect(find.textContaining('question zero'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-nav-newer')));
    await _settleJumps(tester);
    expect(find.textContaining('question one'), findsOneWidget);
    expect(find.text('2/3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-nav-newer')));
    await _settleJumps(tester);
    expect(find.textContaining('question two'), findsOneWidget);
    expect(find.text('3/3'), findsOneWidget);

    // One more "newer" past the newest → clamped, stays at 3/3.
    await tester.tap(find.byKey(const ValueKey('chat-nav-newer')));
    await _settleJumps(tester);
    expect(find.text('3/3'), findsOneWidget);
    expect(
      tester.getCenter(find.textContaining('question two')).dy,
      allOf(greaterThan(0), lessThan(800)),
    );
  });

  testWidgets('jump to top lands on the oldest question', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(_transcript()));
    await tester.pumpAndSettle();

    // Start pinned at the newest; the oldest question is ~2 transcripts'
    // worth of tall replies above → far outside the build window.
    expect(find.textContaining('question two'), findsOneWidget);
    expect(find.textContaining('question zero'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-nav-top')));
    await _settleJumps(tester);

    // Landed at the top: the oldest question is on screen (and built),
    // the newest is far below the build window.
    expect(find.textContaining('question zero'), findsOneWidget);
    final dy = tester.getCenter(find.textContaining('question zero')).dy;
    expect(dy, greaterThan(0));
    expect(dy, lessThan(800));
    expect(find.textContaining('question two'), findsNothing);
    // Guided pointer re-anchored at the oldest → counter + bounded step.
    expect(find.text('1/3'), findsOneWidget);
  });

  testWidgets('jump to bottom returns to the newest question', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(_transcript()));
    await tester.pumpAndSettle();

    // Walk to the top first (guided hops), then jump straight back down.
    await tester.tap(find.byKey(const ValueKey('chat-nav-top')));
    await _settleJumps(tester);
    expect(find.textContaining('question zero'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-nav-bottom')));
    await _settleJumps(tester);

    expect(find.textContaining('question two'), findsOneWidget);
    final dy = tester.getCenter(find.textContaining('question two')).dy;
    expect(dy, greaterThan(0));
    expect(dy, lessThan(800));
    expect(find.textContaining('question zero'), findsNothing);
    expect(find.text('3/3'), findsOneWidget);
  });

  testWidgets(
    'end jump re-anchors even when the transcript fits the viewport',
    (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(_shortTranscript()));
      await tester.pumpAndSettle();

      // Both questions are on screen → extents equal, nothing to scroll.
      expect(find.textContaining('question zero'), findsOneWidget);
      expect(find.textContaining('question one'), findsOneWidget);
      // No guided position yet → no counter.
      expect(find.text('1/2'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('chat-nav-top')));
      await _settleJumps(tester);
      // Re-anchor must still happen: counter appears and bounds the steps.
      expect(find.text('1/2'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-nav-bottom')));
      await _settleJumps(tester);
      expect(find.text('2/2'), findsOneWidget);
      expect(find.text('1/2'), findsNothing);
    },
  );

  testWidgets(
    'end jump survives streaming growth mid-flight (review 2026-08-22)',
    (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(
        _transcript(),
        streaming: const StreamingMessage(
          inReplyTo: 'u2',
          buffer: 'starting the reply…',
        ),
      ));
      // StreamingBubble's blinking cursor never settles → fixed pumps only.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      await tester.tap(find.byKey(const ValueKey('chat-nav-top')));
      await tester.pump(); // animateTo scheduled, still mid-flight
      // A streaming token lands while the 220-600ms end-jump animation runs.
      // didUpdateWidget bumps `_navGen` on EVERY token — the old shared
      // guard aborted the end jump here, so it never snapped or re-anchored.
      await tester.pumpWidget(_harness(
        _transcript(),
        streaming: StreamingMessage(inReplyTo: 'u2', buffer: _tallReply()),
      ));
      // Pump past the longest animation (600ms) + a post-frame policy tick.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // Landed on the CURRENT top bound (grown by ~2.5k mid-flight), not the
      // one captured at press time.
      expect(find.textContaining('question zero'), findsOneWidget);
      final dy = tester.getCenter(find.textContaining('question zero')).dy;
      expect(dy, greaterThan(0));
      expect(dy, lessThan(800));
      expect(find.text('1/3'), findsOneWidget);
    },
  );

  testWidgets('nav pill hidden with fewer than two user messages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _harness([
        UserMsg(id: 'u0', text: 'the only question'),
        AssistantMsg(id: 'a0', text: 'short reply'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('chat-nav-older')), findsNothing);
    expect(find.byKey(const ValueKey('chat-nav-newer')), findsNothing);
    expect(find.byKey(const ValueKey('chat-nav-top')), findsNothing);
    expect(find.byKey(const ValueKey('chat-nav-bottom')), findsNothing);
  });
}
