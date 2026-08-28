import 'dart:ui' as ui;

import 'package:cockpit/app/core/ui/menu/workspace_menu_bridge.dart';
import 'package:cockpit/app/core/ui/widgets/devtools_inspector.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

void main() {
  testWidgets('Select Widget mode toggles without Tooltip overlay errors', (
    tester,
  ) async {
    final previousErrorHandler = FlutterError.onError;
    final previousInspectorOverride =
        WidgetsBinding.instance.debugShowWidgetInspectorOverride;
    final previousExcludeRootInspector =
        WidgetsBinding.instance.debugExcludeRootWidgetInspector;
    final previousSelectionOnTap =
        WidgetsBinding.instance.debugWidgetInspectorSelectionOnTapEnabled.value;
    final errors = <FlutterErrorDetails>[];
    FlutterError.onError = errors.add;
    addTearDown(() {
      WidgetsBinding.instance.debugShowWidgetInspectorOverride =
          previousInspectorOverride;
      WidgetsBinding.instance.debugExcludeRootWidgetInspector =
          previousExcludeRootInspector;
      WidgetsBinding.instance.debugWidgetInspectorSelectionOnTapEnabled.value =
          previousSelectionOnTap;
      FlutterError.onError = previousErrorHandler;
    });

    WidgetsBinding.instance.debugExcludeRootWidgetInspector = true;
    WidgetsBinding.instance.debugShowWidgetInspectorOverride = false;
    await tester.pumpWidget(
      ShadcnApp(
        theme: const ThemeData(),
        home: const DevToolsInspector(
          child: ColoredBox(color: Color(0xFF000000)),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Exit Select Widget mode'), findsNothing);

    WidgetsBinding.instance.debugShowWidgetInspectorOverride = true;
    await tester.pump();

    final exitButton = find.bySemanticsLabel('Exit Select Widget mode');
    final tapModeButton = find.bySemanticsLabel(
      'Change widget selection mode for taps',
    );
    expect(exitButton, findsOneWidget);
    expect(tapModeButton, findsOneWidget);
    expect(find.bySemanticsLabel('Move to the right'), findsOneWidget);
    expect(find.byType(material.Tooltip), findsNothing);

    // Exercise the inspector's own HUD tooltip path. The buttons must not ask
    // Material Tooltip for an Overlay because the inspector is below ShadcnApp.
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(exitButton));
    await tester.pump(const Duration(milliseconds: 200));
    await mouse.removePointer();
    await tester.pump();

    final selectionOnTap =
        WidgetsBinding.instance.debugWidgetInspectorSelectionOnTapEnabled;
    final selectionOnTapBefore = selectionOnTap.value;
    await tester.tap(tapModeButton);
    await tester.pump();
    expect(selectionOnTap.value, isNot(selectionOnTapBefore));

    await tester.tap(exitButton);
    await tester.pump();
    expect(WidgetsBinding.instance.debugShowWidgetInspectorOverride, isFalse);
    expect(find.bySemanticsLabel('Exit Select Widget mode'), findsNothing);
    expect(errors, isEmpty);
  });

  testWidgets('clearing the workspace menu during disposal is deferred', (
    tester,
  ) async {
    final previous = FlutterError.onError;
    final errors = <FlutterErrorDetails>[];
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    final bridge = WorkspaceMenuBridge();
    bridge.setWorkspace(hasWorkspace: true);
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: bridge,
        builder: (context, child) =>
            _ClearBridgeOnDispose(bridge: bridge, child: child!),
        child: const SizedBox(),
      ),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(bridge.hasWorkspace, isFalse);
    expect(errors, isEmpty);
  });
}

class _ClearBridgeOnDispose extends StatefulWidget {
  const _ClearBridgeOnDispose({required this.bridge, required this.child});

  final WorkspaceMenuBridge bridge;
  final Widget child;

  @override
  State<_ClearBridgeOnDispose> createState() => _ClearBridgeOnDisposeState();
}

class _ClearBridgeOnDisposeState extends State<_ClearBridgeOnDispose> {
  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    widget.bridge.setWorkspace(hasWorkspace: false);
    super.dispose();
  }
}
