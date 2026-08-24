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

/// Pump fixed clock time in 100ms frames (never pumpAndSettle — the
/// streaming bubble's cursor blink never settles).
Future<void> _pumpMs(WidgetTester tester, int ms) async {
  var left = ms;
  while (left > 0) {
    final step = left >= 100 ? 100 : left;
    await tester.pump(Duration(milliseconds: step));
    left -= step;
  }
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

  // Plan/stopscroll — the middle nav-pill button that pauses the
  // follow-the-newest auto-scroll so incoming messages stop moving the
  // viewport while the user reads past ones, and resumes "like before".
  testWidgets(
    'pause freezes the viewport even while pinned; resume follows again',
    (tester) async {
      await tester.pumpWidget(_harness(
        _transcript(),
        const StreamingMessage(inReplyTo: 'u2', buffer: _seed),
      ));
      await _settle(tester);

      final p = _position(tester);
      expect(p.pixels, p.minScrollExtent); // following the live reply

      // Pause via the middle nav button → icon flips to ▶ "resume".
      await tester.tap(find.byKey(const ValueKey('chat-nav-pause')));
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-nav-resume')), findsOneWidget);

      final maxBefore = p.maxScrollExtent;
      await _grow(tester, List.filled(120, 'more generated text ').join());

      // Pinned BUT paused → hold, not follow: the offset grew by exactly the
      // bottom growth, so the SAME content stays on screen while the reply
      // grows below the fold.
      expect(
        p.pixels - p.minScrollExtent,
        closeTo(p.maxScrollExtent - maxBefore, 1.0),
      );

      // Resume → land back on the newest…
      await tester.tap(find.byKey(const ValueKey('chat-nav-resume')));
      await _pumpMs(tester, 900); // run the landing animation
      expect(p.pixels, p.minScrollExtent);
      expect(find.byKey(const ValueKey('chat-nav-pause')), findsOneWidget);

      // …and continue following like before.
      await _grow(tester, List.filled(60, 'even more generated text ').join());
      expect(p.pixels, p.minScrollExtent);
    },
  );

  testWidgets(
    'jump-to-newest while paused resumes the follow',
    (tester) async {
      await tester.pumpWidget(_harness(
        _transcript(),
        const StreamingMessage(inReplyTo: 'u2', buffer: _seed),
      ));
      await _settle(tester);

      final p = _position(tester);
      await tester.tap(find.byKey(const ValueKey('chat-nav-pause')));
      await tester.pump();
      await _grow(tester, List.filled(120, 'more generated text ').join());
      expect(p.pixels, greaterThan(p.minScrollExtent)); // frozen

      // "Jump to newest" is an explicit "take me back to live": it must also
      // clear the pause, or the very next growth would freeze the view
      // again right after the jump.
      await tester.tap(find.byKey(const ValueKey('chat-nav-bottom')));
      await _pumpMs(tester, 900);
      expect(p.pixels, p.minScrollExtent);
      expect(find.byKey(const ValueKey('chat-nav-pause')), findsOneWidget);

      await _grow(tester, List.filled(60, 'even more generated text ').join());
      expect(p.pixels, p.minScrollExtent); // following again
    },
  );

  testWidgets(
    'history replacement clears the pause (fresh chat follows)',
    (tester) async {
      await tester.pumpWidget(_harness(
        _transcript(),
        const StreamingMessage(inReplyTo: 'u2', buffer: _seed),
      ));
      await _settle(tester);

      final p = _position(tester);
      await tester.tap(find.byKey(const ValueKey('chat-nav-pause')));
      await tester.pump();
      await _grow(tester, List.filled(120, 'more generated text ').join());
      expect(p.pixels, greaterThan(p.minScrollExtent)); // frozen

      // Session switch / reload → TranscriptGrow.replace → land at the newest
      // AND resume the follow. Two user messages keep the nav pill mounted.
      final reloaded = [
        UserMsg(id: 'n0', text: 'new session first question'),
        AssistantMsg(id: 'n1', text: _tallReply()),
        UserMsg(id: 'n2', text: 'second question'),
        AssistantMsg(id: 'n3', text: _tallReply()),
      ];
      await tester.pumpWidget(_harness(
        reloaded,
        const StreamingMessage(inReplyTo: 'n0', buffer: _seed),
      ));
      await tester.pump();

      expect(p.pixels, p.minScrollExtent);
      // Pause cleared: the button is back to ❚❚ "pause".
      expect(find.byKey(const ValueKey('chat-nav-pause')), findsOneWidget);
    },
  );
}
