// Regression test (bug 2026-08-21): "scrolling up to read older messages
// while the agent is still generating snaps back to the end".
//
// The scroll policy held the viewport via `jumpTo(pixels + delta)` on every
// streaming growth. jumpTo ends the current scroll activity (goIdle) — it
// KILLS an in-flight user drag — so during generation every scroll attempt
// died mid-gesture and the viewport fought its way back toward the newest
// message.
//
// The fix compensates with `correctBy` (silent: no activity is canceled, no
// notifications) and never jumps while a user drag owns the list (tracked
// from drag-carrying ScrollStart/End notifications).
//
// NOTE on driving gestures: this Flutter build's test harness does not
// deliver synthetic pointer drags to `reverse: true` list views (a bare
// reversed ListView ignores tester.drag entirely), so the tests use
// `ScrollPosition.hold()` — the exact activity a finger-down creates — and
// assert that streaming growth COMPENSATES the offset via correctBy while
// LEAVING that hold activity alive (the old jumpTo policy replaced it with
// an idle activity, which on a real device is the killed drag).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_page.dart';

String _tallReply() => List.filled(
  40,
  'a reasonably long sentence that wraps across the full width',
).join('\n');

List<ChatMessage> _transcript() => [
  UserMsg(id: 'u0', text: 'question zero'),
  AssistantMsg(id: 'a0', text: _tallReply()),
  UserMsg(id: 'u1', text: 'question one'),
  AssistantMsg(id: 'a1', text: _tallReply()),
  UserMsg(id: 'u2', text: 'question two'),
];

const _seed = 'streaming seed ';

Widget _harness(List<ChatMessage> messages, StreamingMessage? streaming) =>
    MaterialApp(
      home: Scaffold(
        body: MessageList(
          messages: messages,
          streaming: streaming,
          onDecide: (_, _) {},
          truncated: false,
        ),
      ),
    );

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(MessageList),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

/// StreamingBubble's blinking-cursor animation never settles, so
/// pumpAndSettle times out whenever streaming is mounted — pump fixed clock
/// time instead.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _grow(WidgetTester tester, String extra) async {
  await tester.pumpWidget(_harness(
    _transcript(),
    StreamingMessage(inReplyTo: 'u2', buffer: _seed + extra),
  ));
  await tester.pump(); // post-frame _applyScrollPolicy runs here
}

void main() {
  testWidgets(
    'streaming growth compensates the offset and keeps a hold (finger-down) '
    'activity alive',
    (tester) async {
      await tester.pumpWidget(_harness(
        _transcript(),
        const StreamingMessage(inReplyTo: 'u2', buffer: _seed),
      ));
      await _settle(tester);

      final p = _position(tester);
      // Reader is up in the transcript (unpinned), finger down (hold).
      p.jumpTo(150);
      final hold = p.hold(() {});
      expect(p.pixels, 150);
      expect(p.activity, same(hold));

      final maxBefore = p.maxScrollExtent;
      await _grow(tester, List.filled(120, 'more generated text ').join());

      // Viewport held: offset grew by exactly the bottom growth...
      expect(p.pixels - 150, closeTo(p.maxScrollExtent - maxBefore, 1.0));
      // ...and the hold activity SURVIVED the growth frame. The old jumpTo
      // policy goIdle'd it — on a real device that is the killed drag.
      expect(p.activity, same(hold));

      hold.cancel();
      await _settle(tester);
    },
  );

  testWidgets(
    'pinned with no finger down stays glued to the bottom while streaming',
    (tester) async {
      await tester.pumpWidget(_harness(
        _transcript(),
        const StreamingMessage(inReplyTo: 'u2', buffer: _seed),
      ));
      await _settle(tester);

      final p = _position(tester);
      expect(p.pixels, p.minScrollExtent); // at the bottom, no gesture

      await _grow(tester, List.filled(120, 'more generated text ').join());

      expect(p.pixels, p.minScrollExtent); // still following the live reply
    },
  );

  testWidgets(
    'history replacement re-lands at the bottom even when unpinned',
    (tester) async {
      await tester.pumpWidget(_harness(
        _transcript(),
        const StreamingMessage(inReplyTo: 'u2', buffer: _seed),
      ));
      await _settle(tester);

      final p = _position(tester);
      p.jumpTo(200); // reader is up in older history
      expect(p.pixels, 200);

      // Session switch / reload: the messages list instance changes with
      // different content → TranscriptGrow.replace → land at the newest.
      final reloaded = [
        UserMsg(id: 'n0', text: 'new session first question'),
        AssistantMsg(id: 'n1', text: _tallReply()),
      ];
      await tester.pumpWidget(_harness(
        reloaded,
        const StreamingMessage(inReplyTo: 'n0', buffer: _seed),
      ));
      await tester.pump();

      expect(p.pixels, p.minScrollExtent);
    },
  );
}
