import 'package:cockpit/app/core/ui/widgets/context_menu_gesture.dart';
import 'package:cockpit/app/core/utils/platform_kind.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<Offset>> pump(
    WidgetTester tester, {
    bool longPressOnMobile = true,
    bool enabled = true,
  }) async {
    final hits = <Offset>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: ContextMenuGesture(
            enabled: enabled,
            longPressOnMobile: longPressOnMobile,
            behavior: HitTestBehavior.opaque,
            onMenu: hits.add,
            child: const SizedBox(width: 100, height: 40),
          ),
        ),
      ),
    );
    return hits;
  }

  testWidgets('botão direito abre o menu na posição do cursor', (tester) async {
    final hits = await pump(tester);
    final target = tester.getCenter(find.byType(SizedBox));
    final gesture = await tester.startGesture(
      target,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();
    expect(hits, [target]);
  });

  testWidgets('toque longo: abre no mobile, é ignorado no desktop', (
    tester,
  ) async {
    final hits = await pump(tester);
    await tester.longPress(find.byType(SizedBox));
    await tester.pump();
    // A plataforma do teste é o host (desktop); no mobile o gesto vale.
    expect(hits.isEmpty, isDesktopPlatform);
    expect(hits.isNotEmpty, isMobilePlatform);
  });

  testWidgets('longPressOnMobile: false nunca abre por toque longo', (
    tester,
  ) async {
    final hits = await pump(tester, longPressOnMobile: false);
    await tester.longPress(find.byType(SizedBox));
    await tester.pump();
    expect(hits, isEmpty);
  });

  testWidgets('enabled: false desliga o botão direito também', (tester) async {
    final hits = await pump(tester, enabled: false);
    final target = tester.getCenter(find.byType(SizedBox));
    final gesture = await tester.startGesture(
      target,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();
    expect(hits, isEmpty);
  });
}
