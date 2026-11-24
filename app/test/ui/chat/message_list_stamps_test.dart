// Plan/172 — the transcript passes the "Show message timestamps" setting down
// to the user and assistant bubbles (`MessageList.showStamps`).
//
// `MessageList` is public for exactly this kind of test: mount it directly,
// without the ChatPage / Provider tree, and assert what the bubbles render.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:app/ui/chat/widgets/message_stamp.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<ChatMessage> _transcript(DateTime ts) => [
  UserMsg(id: 'u1', text: 'when did I ask?', ts: ts),
  AssistantMsg(
    id: 'a1',
    text: 'just now',
    ts: ts.add(const Duration(seconds: 9)),
  ),
];

Widget _harness(List<ChatMessage> messages, {required bool showStamps}) =>
    MaterialApp(
      home: Scaffold(
        body: MessageList(
          messages: messages,
          streaming: null,
          onDecide: (_, _) {},
          truncated: false,
          showStamps: showStamps,
        ),
      ),
    );

void main() {
  final sent = DateTime.now().subtract(const Duration(minutes: 4));
  final replied = sent.add(const Duration(seconds: 9));

  testWidgets('showStamps on → both bubbles carry their own stamp', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(_transcript(sent), showStamps: true));
    await tester.pumpAndSettle();

    expect(find.byType(UserBubble), findsOneWidget);
    expect(find.byType(AssistantBubble), findsOneWidget);
    expect(find.byType(MessageStamp), findsNWidgets(2));
    // Each stamp sits in its own bubble and shows that message's time.
    final sentTexts = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(UserBubble),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data)
        .toList();
    expect(sentTexts.last, endsWith(_hms(sent)));
    final replyTexts = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(AssistantBubble),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data)
        .toList();
    expect(replyTexts.last, endsWith(_hms(replied)));
    expect(replyTexts.last, isNot(sentTexts.last));
  });

  testWidgets(
    'showStamps off (the default) → the transcript renders no stamp',
    (tester) async {
      await tester.pumpWidget(_harness(_transcript(sent), showStamps: false));
      await tester.pumpAndSettle();

      expect(find.byType(MessageStamp), findsNothing);
      expect(find.textContaining(RegExp(r'\d\d:\d\d:\d\d')), findsNothing);
    },
  );
}

String _two(int v) => v.toString().padLeft(2, '0');

/// Local `hh:mm:ss` of [t] — the stable tail of a stamp.
String _hms(DateTime t) {
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}
