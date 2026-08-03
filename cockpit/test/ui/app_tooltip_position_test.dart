import 'package:cockpit/app/core/ui/overlay/app_popover_handler.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/app_tooltip.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Reproduz a topologia real do app: o zoom (`_AppZoom` = MediaQuery reduzida +
/// FittedBox) fica no `builder` do ShadcnApp, ACIMA do Navigator/Overlay.
Widget host({required double scale, required Widget child}) => ShadcnApp(
  theme: buildTheme(
    brightness: Brightness.dark,
  ).copyWith(platform: () => TargetPlatform.macOS),
  // Mesmos handlers do app real — é quem converte a âncora pro espaço do
  // Overlay (que vive dentro do zoom).
  popoverHandler: const AppPopoverOverlayHandler(),
  menuHandler: const AppPopoverOverlayHandler(),
  tooltipHandler: const AppPopoverOverlayHandler(),
  builder: (context, appChild) {
    if ((scale - 1.0).abs() < 0.001) return appChild!;
    final mq = MediaQuery.of(context);
    final scaled = mq.size / scale;
    return MediaQuery(
      data: mq.copyWith(size: scaled),
      child: FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: scaled.width,
          height: scaled.height,
          child: appChild,
        ),
      ),
    );
  },
  home: Align(
    alignment: Alignment.centerLeft,
    child: Padding(padding: const EdgeInsets.only(left: 300), child: child),
  ),
);

Future<Rect> showBalloon(WidgetTester tester) async {
  final trigger = find.byType(AppTooltip);
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(trigger));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 300));
  final balloon = find.byType(TooltipContainer);
  expect(balloon, findsOneWidget);
  return tester.getRect(balloon);
}

void main() {
  const tip = AppTooltip(
    message: 'Split right',
    child: SizedBox(width: 13, height: 13),
  );

  testWidgets('zoom 1.0 — balão logo abaixo do trigger', (tester) async {
    await tester.pumpWidget(host(scale: 1.0, child: tip));
    final triggerRect = tester.getRect(find.byType(AppTooltip));
    final balloonRect = await showBalloon(tester);
    expect((balloonRect.center.dx - triggerRect.center.dx).abs(), lessThan(30));
    expect(balloonRect.top - triggerRect.bottom, inInclusiveRange(0, 24));
  });

  testWidgets('zoom 1.5 — balão logo abaixo do trigger', (tester) async {
    await tester.pumpWidget(host(scale: 21 / 14, child: tip));
    final triggerRect = tester.getRect(find.byType(AppTooltip));
    final balloonRect = await showBalloon(tester);
    expect((balloonRect.center.dx - triggerRect.center.dx).abs(), lessThan(30));
    expect(balloonRect.top - triggerRect.bottom, inInclusiveRange(0, 36));
  });

  // Caso dos Select/menus: popover SEM `position`, ancorado no próprio widget
  // (o handler mede a âncora). Era o que abria deslocado com zoom ≠ 1.
  for (final scale in const [1.0, 21 / 14]) {
    testWidgets('popover ancorado abre colado no trigger — zoom $scale', (
      tester,
    ) async {
      const key = Key('trigger');
      await tester.pumpWidget(
        host(
          scale: scale,
          child: Builder(
            builder: (context) => GestureDetector(
              key: key,
              behavior: HitTestBehavior.opaque,
              onTap: () => showPopover<void>(
                context: context,
                alignment: Alignment.topLeft,
                anchorAlignment: Alignment.bottomLeft,
                builder: (_) => const SizedBox(
                  width: 120,
                  height: 40,
                  child: Text('menu'),
                ),
              ),
              child: const SizedBox(width: 60, height: 20),
            ),
          ),
        ),
      );
      final triggerRect = tester.getRect(find.byKey(key));
      await tester.tap(find.byKey(key));
      // pump manual (não pumpAndSettle): com o handler do shadcn o ticker de
      // `follow` roda pra sempre e o settle nunca chega.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final popoverRect = tester.getRect(find.text('menu'));
      expect((popoverRect.left - triggerRect.left).abs(), lessThan(12));
      expect(popoverRect.top - triggerRect.bottom, inInclusiveRange(-4, 24));
    });
  }
}
