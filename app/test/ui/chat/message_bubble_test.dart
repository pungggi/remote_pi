// Agent output (AssistantBubble) must use the FULL content width, not the old
// 340px cap (user-reported: markdown reply not filling the horizontal space).

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/copy_button.dart';
import 'package:app/ui/chat/widgets/linkified_text.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AssistantBubble wraps at the full available width (>340)', (
    tester,
  ) async {
    const longText =
        'This is a sufficiently long agent reply that would have wrapped at '
        'the old 340px cap but should now span the full content width of the '
        'message list so it reads naturally on wide screens.';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            child: AssistantBubble(AssistantMsg(id: 'a1', text: longText)),
          ),
        ),
      ),
    );
    await tester.pump();

    // Markdown rendered + spanning beyond the old 340px cap.
    expect(find.byType(AgentMarkdown), findsOneWidget);
    final width = tester.getSize(find.byType(AgentMarkdown)).width;
    expect(
      width,
      greaterThan(340),
      reason: 'agent markdown should fill beyond the old 340px cap',
    );
  });

  testWidgets('AssistantBubble is selectable (copyable)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AssistantBubble(AssistantMsg(id: 'a1', text: 'reply')),
        ),
      ),
    );
    await tester.pump();
    // AgentMarkdown wraps the reply in a SelectionArea when selectable.
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('AssistantBubble shows a Copy button that copies the reply', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AssistantBubble(AssistantMsg(id: 'a1', text: 'copy me!')),
        ),
      ),
    );
    await tester.pump();

    // The copy affordance is present and labeled.
    expect(find.byType(CopyButton), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);

    await tester.tap(find.byType(CopyButton));
    await tester.pump();

    // The whole reply lands on the clipboard.
    expect(calls, isNotEmpty, reason: 'Clipboard.setData was invoked');
    final text = (calls.first.arguments as Map)['text'] as String;
    expect(text, 'copy me!');

    // Feedback label flips to "Copied".
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets(
    'AssistantBubble Copy handles clipboard failure (no crash, no "Copied")',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'no-clipboard');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AssistantBubble(AssistantMsg(id: 'a1', text: 'fail me')),
          ),
        ),
      );
      await tester.pump();

      // Tapping must not throw an unhandled async error.
      await tester.tap(find.byType(CopyButton));
      await tester.pump();

      // Did NOT flip to the success state…
      expect(find.text('Copied'), findsNothing);
      // …and surfaced the failure as a SnackBar instead.
      expect(find.textContaining("Couldn't copy"), findsOneWidget);
    },
  );

  testWidgets('AssistantBubble hides Copy when the reply is empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AssistantBubble(AssistantMsg(id: 'a1', text: '')),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CopyButton), findsNothing);
  });

  testWidgets('UserBubble text is selectable (copyable)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(UserMsg(id: 'u1', text: 'my message')),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(LinkifiedText), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.text('my message'), findsOneWidget);
  });

  testWidgets('pending steer bubble shows steering label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(
            UserMsg(
              id: 'u1',
              text: 'busy follow-up',
              status: UserMsgStatus.pending,
              steering: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('steering…'), findsOneWidget);
    expect(find.text('sending…'), findsNothing);
  });

  testWidgets('confirmed steer bubble keeps steering label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(
            UserMsg(id: 'u1', text: 'accepted follow-up', steering: true),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('steering…'), findsOneWidget);
  });

  testWidgets('pending normal bubble keeps sending label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(
            UserMsg(
              id: 'u1',
              text: 'normal send',
              status: UserMsgStatus.pending,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('sending…'), findsOneWidget);
  });

  // --- Bare HTTP(S) links are tappable anywhere in the chat ---------------

  /// Walks an [InlineSpan] tree and yields every [TextSpan] that carries a
  /// gesture recognizer (i.e. a tappable link span).
  Iterable<TextSpan> spansWithRecognizer(InlineSpan span) sync* {
    if (span is TextSpan) {
      if (span.recognizer != null) yield span;
      for (final child in span.children ?? const <InlineSpan>[]) {
        yield* spansWithRecognizer(child);
      }
    }
  }

  testWidgets('UserBubble makes a bare URL a tappable span', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: UserBubble(
              UserMsg(id: 'u1', text: 'check https://example.com/a/b out'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The user text is rendered by the link-aware widget.
    expect(find.byType(LinkifiedText), findsOneWidget);

    // The URL run is its own TextSpan carrying a tap recognizer + link style.
    final rich = tester.widget<RichText>(
      find.descendant(
        of: find.byType(LinkifiedText),
        matching: find.byType(RichText),
      ),
    );
    final urlSpans =
        spansWithRecognizer(rich.text)
            .where((s) => s.toPlainText() == 'https://example.com/a/b')
            .toList();
    expect(urlSpans, hasLength(1));
    expect(urlSpans.first.recognizer, isA<TapGestureRecognizer>());
    expect(
      urlSpans.first.style?.decoration?.contains(TextDecoration.underline),
      true,
    );
  });

  testWidgets(
    'AgentMarkdown autolinks a bare URL (tappable + underlined)',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              // selectable=false → no SelectionArea, isolating the link widget.
              child: AgentMarkdown(
                'see https://example.com/now for details',
                selectable: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The bare URL is rendered as its own tappable text widget.
      expect(find.text('https://example.com/now'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('https://example.com/now'),
          matching: find.byType(GestureDetector),
        ),
        findsWidgets,
        reason: 'the autolinked URL is wrapped in a tappable GestureDetector',
      );
      final style = tester.widget<Text>(
        find.text('https://example.com/now'),
      ).style;
      expect(style?.decoration?.contains(TextDecoration.underline), true);
    },
  );

  testWidgets(
    'AgentMarkdown keeps an explicit [text](url) link working',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: AgentMarkdown(
                '[docs](https://example.com/docs)',
                selectable: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The AutoLink component must not break explicit Markdown links.
      expect(find.text('docs'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('docs'),
          matching: find.byType(GestureDetector),
        ),
        findsWidgets,
      );
    },
  );
}
