// Plan/163 — DocViewerPage Save flow: the native side returns {name, uri}
// and the snackbar offers an Open action that VIEWs the saved file. Covers
// the happy path, the legacy-native fallback (name string only, no Open),
// and the "no app handles this type" toast when Android returns false.

import 'package:app/ui/doc_viewer/doc_viewer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ch.pungitore.piper/files');
  Object? Function(MethodCall call)? handler;
  final savedNames = <String?>[];

  setUp(() {
    handler = null;
    savedNames.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'saveToDownloads') {
        savedNames.add((call.arguments as Map<Object?, Object?>)['name'] as String?);
      }
      return handler?.call(call);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  DocViewerPage page() => DocViewerPage(
        bytes: Uint8List.fromList([1, 2, 3]),
        kind: 'file',
        mime: 'application/octet-stream',
        title: 'Backup.jwlibrary',
      );

  Future<void> tapSave(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: page()));
    await tester.tap(find.byIcon(Icons.save_alt));
    await tester.pump(); // save resolves → snackbar starts animating in
    await tester.pumpAndSettle(); // snackbar fully visible → tappable
  }

  /// Snackbars hold a 4 s dismiss timer; drain it or the test ends with
  /// pending timers.
  Future<void> drain(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 5));

  testWidgets('save returns {name, uri} → snackbar with working Open action',
      (tester) async {
    final opened = <Map<Object?, Object?>>[];
    handler = (call) async {
      switch (call.method) {
        case 'saveToDownloads':
          return {
            'name': 'Backup.jwlibrary',
            'uri': 'content://media/downloads/1',
          };
        case 'openSavedFile':
          opened.add(call.arguments as Map<Object?, Object?>);
          return true;
      }
      return null;
    };

    await tapSave(tester);
    expect(find.text('Saved to Downloads · Backup.jwlibrary'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);

    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(opened, hasLength(1));
    expect(opened.single['uri'], 'content://media/downloads/1');
    expect(opened.single['mime'], 'application/octet-stream');
    expect(find.text('No app can open this file type'), findsNothing);

    await drain(tester);
  });

  testWidgets('legacy native (name string only) → toast, no Open action',
      (tester) async {
    handler = (call) => 'Backup.jwlibrary';

    await tapSave(tester);
    expect(find.text('Saved to Downloads · Backup.jwlibrary'), findsOneWidget);
    expect(find.text('Open'), findsNothing);

    await drain(tester);
  });

  /// Plan/163 follow-up — the announced basename must reach MediaStore
  /// unchanged. `.jwlibrary` (9 chars) used to trip the 1-5 char extension
  /// heuristic and become `Backup.jwlibrary.bin`.
  testWidgets('save keeps real long extensions, appends fallback only when absent',
      (tester) async {
    handler = (call) => {'name': 'x', 'uri': 'content://x'};

    await tester.pumpWidget(MaterialApp(home: page())); // title: Backup.jwlibrary
    await tester.tap(find.byIcon(Icons.save_alt));
    await tester.pump();
    expect(savedNames.single, 'Backup.jwlibrary');
    await drain(tester);

    savedNames.clear();
    await tester.pumpWidget(MaterialApp(
      home: DocViewerPage(
        bytes: Uint8List.fromList([1]),
        kind: 'file',
        title: 'no-extension',
      ),
    ));
    await tester.tap(find.byIcon(Icons.save_alt));
    await tester.pump();
    expect(savedNames.single, 'no-extension.bin');
    await drain(tester);

    savedNames.clear();
    await tester.pumpWidget(MaterialApp(
      home: DocViewerPage(
        bytes: Uint8List.fromList([1]),
        kind: 'file',
        mime: 'application/pdf',
        title: 'report.pdf',
      ),
    ));
    await tester.tap(find.byIcon(Icons.save_alt));
    await tester.pump();
    expect(savedNames.single, 'report.pdf');
    await drain(tester);
  });

  testWidgets('openSavedFile false → "no app" toast', (tester) async {
    handler = (call) async {
      switch (call.method) {
        case 'saveToDownloads':
          return {'name': 'Backup.jwlibrary', 'uri': 'content://media/x'};
        case 'openSavedFile':
          return false;
      }
      return null;
    };

    await tapSave(tester);
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pumpAndSettle(); // old snackbar exits, toast enters
    expect(find.text('No app can open this file type'), findsOneWidget);

    await drain(tester);
  });
}
