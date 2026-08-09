// Plan/100 — ExtensionUiSheet behavior around submit enablement, rejection
// retry, and system back. Covers the riskiest interactive logic of the
// ask_user modal (the protocol surface is covered by
// test/protocol/extension_ui_test.dart).

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/extension_ui_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ExtensionUiRequest _richRequest({String id = 'tool:tc_1'}) =>
    ExtensionUiRequest(
      id: id,
      method: ExtensionUiMethod.select,
      title: 'Direction',
      options: const ['Alpha', 'Beta'],
      ask: AskEnrichmentWire(
        flowId: id,
        toolCallId: 'tc_1',
        source: 'tool',
        title: 'Direction',
        questions: const [
          AskQuestionWire(
            id: 'goal',
            label: 'Goal',
            prompt: "What's the goal?",
            type: AskQuestionWireType.single,
            required: true,
            options: [
              AskOptionWire(value: 'a', label: 'Alpha'),
              AskOptionWire(value: 'b', label: 'Beta'),
            ],
          ),
        ],
      ),
    );

ExtensionUiRequest _degradedInput() => const ExtensionUiRequest(
  id: 'flow:input',
  method: ExtensionUiMethod.input,
  title: 'Describe',
  placeholder: 'Describe the goal',
);

void main() {
  Future<void> pumpSheet(
    WidgetTester tester, {
    required ExtensionUiRequest request,
    String? error,
    Future<void> Function(ExtensionUiResponse)? onRespond,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: ExtensionUiSheet(
          key: ValueKey(request.id),
          request: request,
          error: error,
          onRespond: onRespond ?? (_) async {},
        ),
      ),
    );
  }

  Finder submitButton() => find.widgetWithText(FilledButton, 'Submit');

  bool submitEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(submitButton()).onPressed != null;

  testWidgets('typing custom text alone enables Submit (rich flow)', (
    tester,
  ) async {
    await pumpSheet(tester, request: _richRequest());
    expect(submitEnabled(tester), isFalse, reason: 'nothing answered yet');

    await tester.enterText(find.byType(TextField).first, 'my own answer');
    await tester.pump();

    expect(
      submitEnabled(tester),
      isTrue,
      reason: 'custom text counts as an answer without any option selected',
    );
  });

  testWidgets('typing enables Submit on the degraded input method', (
    tester,
  ) async {
    await pumpSheet(tester, request: _degradedInput());
    expect(submitEnabled(tester), isFalse);

    await tester.enterText(find.byType(TextField), 'free text');
    await tester.pump();

    expect(submitEnabled(tester), isTrue);
  });

  testWidgets('selecting an option enables Submit and submit sends answers', (
    tester,
  ) async {
    final sent = <ExtensionUiResponse>[];
    await pumpSheet(
      tester,
      request: _richRequest(),
      onRespond: (r) async => sent.add(r),
    );

    await tester.tap(find.text('Beta'));
    await tester.pump();
    expect(submitEnabled(tester), isTrue);

    await tester.tap(submitButton());
    await tester.pump();

    expect(sent, hasLength(1));
    final ask = sent.single.ask!;
    expect(ask.flowId, 'tool:tc_1');
    expect(ask.isCancel, isFalse);
    expect(ask.answers['goal']!.values, ['b']);
    // Modal does NOT close optimistically: it spins until completed/error.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets(
    'rejection stops the spinner for retry; clearing the error mid-retry '
    'does not un-spin the in-flight submit',
    (tester) async {
      final sent = <ExtensionUiResponse>[];
      Future<void> onRespond(ExtensionUiResponse r) async => sent.add(r);

      await pumpSheet(tester, request: _richRequest(), onRespond: onRespond);
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.tap(submitButton());
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // pi-ask rejected → error arrives → spinner off, message shown.
      await pumpSheet(
        tester,
        request: _richRequest(),
        error: 'Unknown option value.',
        onRespond: onRespond,
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Unknown option value.'), findsOneWidget);
      expect(submitEnabled(tester), isTrue, reason: 'retry possible');

      // Retry → viewmodel clears the error (non-null → null). The submit is
      // in flight again; the cleared error must NOT reset the spinner (that
      // would re-enable the buttons and allow a double submit).
      await tester.tap(submitButton());
      await tester.pump();
      await pumpSheet(tester, request: _richRequest(), onRespond: onRespond);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(sent, hasLength(2));
    },
  );

  testWidgets('system back cancels the flow instead of popping the route', (
    tester,
  ) async {
    final sent = <ExtensionUiResponse>[];
    await pumpSheet(
      tester,
      request: _richRequest(),
      onRespond: (r) async => sent.add(r),
    );

    final popped = await tester.binding.handlePopRoute();
    await tester.pump();

    expect(popped, isTrue, reason: 'PopScope intercepted the back gesture');
    expect(sent, hasLength(1));
    expect(sent.single.cancelled, isTrue);
    expect(sent.single.ask?.isCancel, isTrue);
  });

  testWidgets('required question renders the advisory chip', (tester) async {
    await pumpSheet(tester, request: _richRequest());
    expect(find.text('required'), findsOneWidget);
  });

  testWidgets('defensive degraded notify renders its message once', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      request: const ExtensionUiRequest(
        id: 'notify:1',
        method: ExtensionUiMethod.notify,
        message: 'Clarification resolved.',
      ),
    );

    expect(find.text('Clarification resolved.'), findsOneWidget);
  });

  // ── Plan/101 — bottom sheet layout ──────────────────────────────────────────

  double screenHeight(WidgetTester tester) =>
      tester.view.physicalSize.height / tester.view.devicePixelRatio;

  testWidgets('sheet opens partially, leaving the chat visible above it', (
    tester,
  ) async {
    await pumpSheet(tester, request: _richRequest());

    // The header sits well below the top of the screen: that gap is the chat
    // the user needs in order to answer. A full-screen modal would put this
    // at ~0.
    final headerTop = tester.getTopLeft(find.text('Direction')).dy;
    expect(headerTop, greaterThan(screenHeight(tester) * 0.25));

    // Actions are pinned regardless of extent.
    expect(submitButton(), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);
  });

  testWidgets('focusing a text field lifts the sheet clear of the keyboard', (
    tester,
  ) async {
    await pumpSheet(tester, request: _richRequest());
    final before = tester.getTopLeft(find.text('Direction')).dy;

    // showKeyboard focuses without hit-testing, so the assertion doesn't
    // depend on the field happening to be above the fold at rest.
    await tester.showKeyboard(find.byType(TextField).first);
    await tester.pumpAndSettle();

    final after = tester.getTopLeft(find.text('Direction')).dy;
    expect(
      after,
      lessThan(before),
      reason: 'sheet must expand so the field cannot open behind the keyboard',
    );
  });

  testWidgets('rejection banner is on screen while the sheet is partial', (
    tester,
  ) async {
    const msg = 'Not connected — check the link to Pi and retry.';
    await pumpSheet(tester, request: _richRequest(), error: msg);

    final banner = find.text(msg);
    expect(banner, findsOneWidget);

    // Pinned above the actions, so it stays readable at any extent — which is
    // exactly when the user is looking at the chat behind the sheet.
    final rect = tester.getRect(banner);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(screenHeight(tester)));
  });

  // ── Plan/128 — notes (pi-ask `n` / Shift+N) ─────────────────────────────────

  testWidgets('a question note alone enables Submit and is sent as note', (
    tester,
  ) async {
    final sent = <ExtensionUiResponse>[];
    await pumpSheet(
      tester,
      request: _richRequest(),
      onRespond: (r) async => sent.add(r),
    );
    expect(submitEnabled(tester), isFalse);

    // The "Add note" affordance sits below the custom field; scroll it into the
    // sheet's viewport before tapping (it's clipped at the partial extent).
    await tester.ensureVisible(find.text('Add note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add note')); // opens the question note editor
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Add a note to this answer…'),
      'see context above',
    );
    await tester.pump();

    expect(
      submitEnabled(tester),
      isTrue,
      reason: 'a question note is a valid answer without any selection',
    );
    await tester.tap(submitButton());
    await tester.pump();

    expect(sent, hasLength(1));
    expect(sent.single.ask!.answers['goal']!.note, 'see context above');
    expect(sent.single.ask!.answers['goal']!.values, isEmpty);
    expect(sent.single.ask!.answers['goal']!.customText, isNull);
  });

  testWidgets('an option note is sent for the selected option', (tester) async {
    final sent = <ExtensionUiResponse>[];
    await pumpSheet(
      tester,
      request: _richRequest(),
      onRespond: (r) async => sent.add(r),
    );

    await tester.tap(find.text('Beta'));
    await tester.pump();
    // Question note + the selected option's note affordance.
    expect(find.text('Add note'), findsNWidgets(2));

    // The selected option's note affordance precedes the question note in the
    // widget tree (it renders inside the option tile, above the custom field).
    await tester.ensureVisible(find.text('Add note').at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add note').at(0)); // Beta's option note
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Note for this option…'),
      'pick b',
    );
    await tester.pump();

    await tester.tap(submitButton());
    await tester.pump();

    expect(sent, hasLength(1));
    final ans = sent.single.ask!.answers['goal']!;
    expect(ans.values, ['b']);
    expect(ans.optionNotes, {'b': 'pick b'});
    expect(ans.note, isNull);
  });

  testWidgets(
    'option note affordance appears only for a selected option',
    (tester) async {
      await pumpSheet(tester, request: _richRequest());
      expect(
        find.text('Add note'),
        findsOneWidget,
        reason: 'only the question note before any selection',
      );

      await tester.tap(find.text('Beta'));
      await tester.pump();
      expect(
        find.text('Add note'),
        findsNWidgets(2),
        reason: 'question note + the selected option note',
      );
    },
  );

  testWidgets(
    'custom text on a single question drops the option note (values empty)',
    (tester) async {
      final sent = <ExtensionUiResponse>[];
      await pumpSheet(
        tester,
        request: _richRequest(),
        onRespond: (r) async => sent.add(r),
      );

      await tester.tap(find.text('Beta'));
      await tester.pump();
      // The option note affordance precedes the question note in the tree.
      await tester.ensureVisible(find.text('Add note').at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add note').at(0));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Note for this option…'),
        'why b',
      );
      await tester.pump();

      // Custom text overrides the single selection: values becomes empty, so
      // the option note rides nothing and must be dropped — matching pi-ask's
      // serializeAnswer (option notes survive for selected options only).
      await tester.enterText(
        find.widgetWithText(TextField, 'Type your own…'),
        'my own',
      );
      await tester.pump();

      await tester.tap(submitButton());
      await tester.pump();

      final ans = sent.single.ask!.answers['goal']!;
      expect(ans.customText, 'my own');
      expect(ans.values, isEmpty);
      expect(ans.optionNotes, isEmpty);
    },
  );

  testWidgets('a filled note collapses to a chip and reopens on tap', (
    tester,
  ) async {
    await pumpSheet(tester, request: _richRequest());

    await tester.ensureVisible(find.text('Add note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add note')); // question note editor
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Add a note to this answer…'),
      'kept',
    );
    await tester.pump();

    // Collapse (expand_less) keeps the text → the note renders as a chip, not
    // an open field and not the "Add note" button.
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pump();
    expect(find.text('kept'), findsOneWidget, reason: 'chip shows the note');
    expect(
      find.text('Add note'),
      findsNothing,
      reason: 'closed + filled shows the chip, not the empty affordance',
    );

    // Tapping the chip reopens the editor with the text preserved.
    await tester.ensureVisible(find.text('kept'));
    await tester.tap(find.text('kept'));
    await tester.pumpAndSettle();
    final reopened = find
        .byType(TextField)
        .evaluate()
        .where((e) => (e.widget as TextField).controller?.text == 'kept')
        .toList();
    expect(reopened, hasLength(1), reason: 'editor reopened with the note text');
  });

  testWidgets('Remove note clears it and reverts to the Add note affordance', (
    tester,
  ) async {
    final sent = <ExtensionUiResponse>[];
    await pumpSheet(
      tester,
      request: _richRequest(),
      onRespond: (r) async => sent.add(r),
    );

    await tester.ensureVisible(find.text('Add note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add note'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Add a note to this answer…'),
      'temp',
    );
    await tester.pump();
    expect(submitEnabled(tester), isTrue, reason: 'note alone enables Submit');

    // Remove note wipes it and closes → back to the empty affordance, nothing
    // answered. (find.byTooltip disambiguates from the header close button.)
    await tester.tap(find.byTooltip('Remove note'));
    await tester.pump();
    expect(find.text('Add note'), findsOneWidget);
    expect(submitEnabled(tester), isFalse);
  });
}
