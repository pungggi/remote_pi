// Plan/stopscroll — regression tests for the DEVICE bug report: "pause
// doesn't work when there are tool calls". The first freeze iteration only
// clipped the streaming bubble's own growth; tool cards / finalized replies
// appended during a tool-heavy turn grew the list extent (cards AND their
// separators) and the paused view crept.
//
// Freeze semantics under test (chat_page.dart, _MessageListState):
// - while paused, the list builds only messages OLDER than the pause cut
//   (_pausedAfterSeq): tool cards, finalized replies, whole new turns and
//   their separators are simply not in the coordinate space → the scroll
//   extent cannot change;
// - the streaming slot stays mounted, frozen at its pause-time height, and
//   collapses to a zero-height placeholder when the turn ends while paused
//   (streaming → null swap) so even that transition keeps the item count;
// - resume (▶ or jump-to-newest) restores the full list in place, lands on
//   the newest and follows again.
//
// Assertions use the live ScrollPosition and on-screen coordinates — the
// ground truth the device sees — because paused-hidden content paints
// nothing, so Finder-based text assertions can't see it (by design).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_page.dart';

String _tall() =>
    List.filled(40, 'a reasonably long sentence that wraps across the full width')
        .join('\n');

List<ChatMessage> _transcript() => [
  UserMsg(id: 'u0', text: 'question zero'),
  AssistantMsg(id: 'a0', text: _tall()),
  UserMsg(id: 'u1', text: 'question one'),
  AssistantMsg(id: 'a1', text: _tall()),
  UserMsg(id: 'u2', text: 'question two'),
];

const _seed = 'streaming seed ';

Widget _harness(List<ChatMessage> messages, StreamingMessage? streaming) =>
    MaterialApp(
      home: Scaffold(
        // ToolRequestCard reads Preferences in initState (collapse default).
        body: ChangeNotifierProvider<Preferences>(
          create: (_) => Preferences(),
          child: MessageList(
            messages: messages,
            streaming: streaming,
            onDecide: (_, _) {},
            truncated: false,
          ),
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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ToolEvent _tool(String id, {String tool = 'bash'}) => ToolEvent(
  id: id,
  toolCallId: id,
  tool: tool,
  args: const {'command': 'ls -la'},
  status: ToolEventStatus.completed,
);

void main() {
  testWidgets(
    'tool calls appended while paused do not move the viewport (device bug)',
    (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(
        _transcript(),
        const StreamingMessage(inReplyTo: 'u2', buffer: _seed),
      ));
      await _settle(tester);

      final p = _position(tester);
      await tester.tap(find.byKey(const ValueKey('chat-nav-pause')));
      await tester.pump();
      p.jumpTo(300); // reader is up in older history
      await tester.pump();
      final maxAtPause = p.maxScrollExtent;

      // A tool-heavy turn keeps landing below the pause point: tool calls
      // and finalized reply segments ACCUMULATE (stable ids, like the real
      // sync service) while the user reads.
      final grown = [..._transcript()];
      for (var i = 0; i < 3; i++) {
        grown
          ..add(AssistantMsg(
            id: 'a2$i',
            text: 'Let me check the files.\n${_tall()}',
          ))
          ..add(_tool('t$i', tool: i == 0 ? 'bash' : 'read_file'));
        await tester.pumpWidget(_harness(List.of(grown), null));
        await tester.pump();
      }

      // Frozen exactly: none of the cards/segments took any space, so not a
      // single pixel of the extent (and with it the reading position)
      // moved — this is the exact device failure mode.
      expect(p.pixels, 300);
      expect(p.maxScrollExtent, maxAtPause);

      // Still paused (resume is explicit).
      expect(find.byKey(const ValueKey('chat-nav-resume')), findsOneWidget);
    },
  );

  testWidgets(
    'turn ending while paused holds the reading position through the swap',
    (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(
        _transcript(),
        const StreamingMessage(inReplyTo: 'u2', buffer: _seed),
      ));
      await _settle(tester);

      final p = _position(tester);
      await tester.tap(find.byKey(const ValueKey('chat-nav-pause')));
      await tester.pump();
      p.jumpTo(300);
      await tester.pump();
      final maxAtPause = p.maxScrollExtent;

      // agent_done: streaming → null while the finalized reply + a tool
      // card land. The frozen slot KEEPS its captured height (painting the
      // finalized reply clipped in place) and the new rows are cut — so
      // even the swap moves not a single pixel.
      await tester.pumpWidget(_harness([
        ..._transcript(),
        AssistantMsg(id: 'a2', text: _tall()),
        _tool('t0'),
      ], null));
      await tester.pump();

      expect(p.pixels, 300);
      expect(p.maxScrollExtent, maxAtPause);
      expect(find.byKey(const ValueKey('chat-nav-resume')), findsOneWidget);
    },
  );

  testWidgets(
    'resume after paused tool calls un-hides them and follows again',
    (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(
        _transcript(),
        const StreamingMessage(inReplyTo: 'u2', buffer: _seed),
      ));
      await _settle(tester);

      final p = _position(tester);
      await tester.tap(find.byKey(const ValueKey('chat-nav-pause')));
      await tester.pump();

      // Tool-heavy turn completes fully while paused (short segments keep
      // the tool card inside the built window after resume).
      await tester.pumpWidget(_harness([
        ..._transcript(),
        AssistantMsg(id: 'a2', text: 'checking files'),
        _tool('t0'),
        AssistantMsg(id: 'a3', text: 'final segment'),
      ], null));
      await tester.pump();

      // Resume → lands on the newest, everything visible again, and the
      // NEXT growth follows like an un-paused chat.
      await tester.tap(find.byKey(const ValueKey('chat-nav-resume')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(p.pixels, p.minScrollExtent);
      // Tool card visible again after resume (collapsed row shows the name).
      expect(find.text('bash'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-nav-pause')), findsOneWidget);

      await tester.pumpWidget(_harness([
        ..._transcript(),
        AssistantMsg(id: 'a2', text: 'checking files'),
        _tool('t0'),
        AssistantMsg(id: 'a3', text: 'final segment'),
        AssistantMsg(id: 'a4', text: 'final answer'),
      ], null));
      await tester.pump();
      expect(p.pixels, p.minScrollExtent); // following again
    },
  );
}
