// Plan/158 — AgentFileBubble's reference mode: tap-to-download pill, fetch →
// progress → DocViewerPage, and the typed error cards (gone inert, changed
// re-fetch, transient retry). Legacy inline cards keep their old behaviour.

import 'dart:typed_data';

import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/agent_file_bubble.dart';
import 'package:app/ui/doc_viewer/doc_viewer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// '# Plan' — valid markdown so DocViewerPage's MarkdownViewer is pure Flutter.
const _mdBytes = 'IyBQbGFu';

/// Every test card displays the filename `plan.md` (ref name, or the inline
/// path's basename) — the in-card text to tap, wherever the card is laid out
/// (the Align puts the tappable card at the left edge, so tapping the widget
/// center would miss it).
const _tapTarget = 'plan.md';

AgentFileMsg _ref({String? caption}) => AgentFileMsg(
      id: 'af_ref',
      kind: 'markdown',
      data: null,
      fileId: 'af_ref',
      name: 'plan.md',
      bytes: 7,
      caption: caption ?? '',
    );

AgentFileMsg _inline() => AgentFileMsg(
      id: 'af_inline',
      kind: 'markdown',
      data: _mdBytes,
      path: 'docs/plan.md',
    );

void main() {
  Future<void> pump(
    WidgetTester tester,
    AgentFileMsg msg,
    Fetch? fetcher,
  ) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: AgentFileBubble(msg, fetcher: fetcher)),
        ),
      ),
    );
  }

  group('reference bubble (plan/158)', () {
    testWidgets('shows name + size + tap-to-download, opens nothing on its own',
        (tester) async {
      await pump(tester, _ref(caption: 'the plan'), null);
      await tester.pump();
      expect(find.text('plan.md'), findsOneWidget);
      expect(find.text('7 B'), findsOneWidget);
      expect(find.text('tap to download'), findsOneWidget);
      expect(find.byType(DocViewerPage), findsNothing);
    });

    testWidgets('tap fetches chunks then opens the viewer with the bytes',
        (tester) async {
      final fetches = <String>[];
      Future<Uint8List> fetch(
        String fileId, {
        void Function(int received, int total)? onProgress,
      }) async {
        fetches.add(fileId);
        // Two-stage: one rendered frame in the receiving state (43%), then
        // completion — otherwise the whole fetch flushes inside a single
        // pump() and the progress frame never exists.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        onProgress?.call(3, 7);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return Uint8List.fromList('# Plan'.codeUnits);
      }

      await pump(tester, _ref(), fetch);
      await tester.pump();

      await tester.tap(find.text(_tapTarget));
      await tester.pump(); // busy state: progress row at 0%
      await tester.pump(const Duration(milliseconds: 20)); // fake clock → onProgress
      expect(find.text('Receiving… 43%'), findsOneWidget);
      expect(fetches, ['af_ref']);

      await tester.pumpAndSettle(); // fetch completes + route animation
      expect(find.byType(DocViewerPage), findsOneWidget);
      final viewer = tester.widget<DocViewerPage>(
        find.byType(DocViewerPage),
      );
      expect(viewer.bytes, Uint8List.fromList('# Plan'.codeUnits));
      expect(viewer.title, 'plan.md');
    });

    testWidgets('changed error card offers refetch and retries on tap',
        (tester) async {
      var calls = 0;
      Future<Uint8List> fetch(
        String fileId, {
        void Function(int received, int total)? onProgress,
      }) async {
        calls++;
        if (calls == 1) throw AgentFileChangedException();
        return Uint8List.fromList('# Plan'.codeUnits);
      }

      await pump(tester, _ref(), fetch);
      await tester.pump();
      await tester.tap(find.text(_tapTarget));
      await tester.pumpAndSettle();

      expect(find.text('plan.md'), findsOneWidget);
      expect(find.text('Changed on the Pi · tap for current version'),
          findsOneWidget);
      expect(find.byType(DocViewerPage), findsNothing);

      // Tap again → the second fetch succeeds and the viewer opens.
      await tester.tap(find.text(_tapTarget));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.byType(DocViewerPage), findsOneWidget);
    });

    testWidgets('gone error card is inert (no retry burn)', (tester) async {
      var calls = 0;
      Future<Uint8List> fetch(
        String fileId, {
        void Function(int received, int total)? onProgress,
      }) async {
        calls++;
        throw AgentFileGoneException();
      }

      await pump(tester, _ref(), fetch);
      await tester.pump();
      await tester.tap(find.text(_tapTarget));
      await tester.pumpAndSettle();
      expect(find.text('No longer on the Pi'), findsOneWidget);
      expect(calls, 1);

      await tester.tap(find.text(_tapTarget));
      await tester.pumpAndSettle();
      expect(calls, 1, reason: 'a gone file must not re-request');
    });

    testWidgets('transient failure card retries on tap', (tester) async {
      var calls = 0;
      Future<Uint8List> fetch(
        String fileId, {
        void Function(int received, int total)? onProgress,
      }) async {
        calls++;
        if (calls == 1) throw AgentFileUnavailableException('timed out');
        return Uint8List.fromList('# Plan'.codeUnits);
      }

      await pump(tester, _ref(), fetch);
      await tester.pump();
      await tester.tap(find.text(_tapTarget));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't fetch · tap to retry"), findsOneWidget);

      await tester.tap(find.text(_tapTarget));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.byType(DocViewerPage), findsOneWidget);
    });

    testWidgets('without a fetcher the ref card stays static', (tester) async {
      await pump(tester, _ref(), null);
      await tester.pump();
      await tester.tap(find.text(_tapTarget));
      await tester.pumpAndSettle();
      expect(find.byType(DocViewerPage), findsNothing);
      expect(find.text('tap to download'), findsOneWidget);
    });
  });

  group('legacy inline bubble', () {
    testWidgets('opens the viewer directly without fetching', (tester) async {
      var calls = 0;
      Future<Uint8List> fetch(
        String fileId, {
        void Function(int received, int total)? onProgress,
      }) async {
        calls++;
        return Uint8List(0);
      }

      await pump(tester, _inline(), fetch);
      await tester.pump();
      expect(find.text('tap to download'), findsNothing);
      expect(find.text('plan.md'), findsOneWidget);

      await tester.tap(find.text(_tapTarget));
      await tester.pumpAndSettle();
      expect(find.byType(DocViewerPage), findsOneWidget);
      expect(
        tester.widget<DocViewerPage>(find.byType(DocViewerPage)).title,
        'docs/plan.md',
        reason: 'legacy cards keep the repo path as viewer title',
      );
      expect(calls, 0, reason: 'inline bytes never hit the fetch loop');
    });

    testWidgets('undecodable inline base64 shows the decode-error card',
        (tester) async {
      await pump(
        tester,
        AgentFileMsg(
          id: 'af_bad',
          kind: 'text',
          data: 'not base64 !!',
          path: 'x.txt',
        ),
        null,
      );
      await tester.pump();
      expect(find.text("Couldn't decode this file"), findsOneWidget);
    });
  });

  group('binary file kind (plan/162)', () {
    // Raw zip bytes: PK\x03\x04 magic — NOT valid UTF-8, which is exactly
    // the payload the text kinds reject and kind=file must carry through.
    final jwlBytes = Uint8List.fromList(
      [...'PK\u0003\u0004'.codeUnits, ...'rest-of-archive'.codeUnits],
    );

    AgentFileMsg jwlRef() => AgentFileMsg(
          id: 'af_jwl',
          kind: 'file',
          data: null,
          fileId: 'af_jwl',
          name: 'backup.jwlibrary',
          bytes: jwlBytes.length,
          caption: '',
        );

    testWidgets('ref card shows File pill + size, fetch opens save/share page',
        (tester) async {
      Future<Uint8List> fetch(
        String fileId, {
        void Function(int received, int total)? onProgress,
      }) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return jwlBytes;
      }

      await pump(tester, jwlRef(), fetch);
      await tester.pump();
      expect(find.text('backup.jwlibrary'), findsOneWidget);
      expect(find.text('File'), findsOneWidget);
      expect(find.text('tap to download'), findsOneWidget);

      await tester.tap(find.text('backup.jwlibrary'));
      await tester.pumpAndSettle();

      final viewer = tester.widget<DocViewerPage>(find.byType(DocViewerPage));
      expect(viewer.kind, 'file');
      expect(viewer.bytes, jwlBytes);
      // The binary body explains there is no preview and points at the
      // save/share actions instead of a renderer.
      expect(find.textContaining('No preview for this file type'),
          findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
    });
  });
}

/// Local alias mirroring the widget's fetcher signature (keeps the test
/// literals short).
typedef Fetch = Future<Uint8List> Function(
  String fileId, {
  void Function(int received, int total)? onProgress,
});
