import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regressão do foco de pane: clicar **dentro do terminal** tem que focar o
/// pane.
///
/// O corpo do terminal (flterm) registra Tap + Pan + LongPress próprios. Na
/// arena de gestos o reconhecedor mais interno vence (no tap, o sweep do
/// pointer-up escolhe o primeiro membro — o mais profundo), então um
/// `GestureDetector.onTapDown` ANCESTRAL nunca dispara. Era por isso que
/// `vm.focus(pane.id)` só rodava ao clicar fora do terminal, e o pane clicado
/// ficava com o teclado sem a VM saber — o próximo `tabFocusGen` devolvia o
/// foco pro pane anterior.
///
/// O `Listener` do `_PaneView` não participa da arena: sempre recebe o
/// pointer-down.
Widget terminalLike({required Widget child}) => RawGestureDetector(
  behavior: HitTestBehavior.opaque,
  gestures: <Type, GestureRecognizerFactory>{
    TapGestureRecognizer:
        GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          TapGestureRecognizer.new,
          (i) => i.onTapDown = (_) {},
        ),
    PanGestureRecognizer:
        GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
          () => PanGestureRecognizer(
            supportedDevices: const {PointerDeviceKind.mouse},
          ),
          (i) => i
            ..dragStartBehavior = DragStartBehavior.down
            ..onStart = (_) {},
        ),
  },
  child: child,
);

void main() {
  const body = SizedBox(width: 200, height: 200);

  testWidgets('Listener do pane recebe o clique dentro do terminal', (
    tester,
  ) async {
    var focused = 0;
    await tester.pumpWidget(
      Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => focused++,
        child: terminalLike(child: body),
      ),
    );
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(focused, 1);
  });

  testWidgets('GestureDetector ancestral perde a arena (o bug)', (
    tester,
  ) async {
    var focused = 0;
    await tester.pumpWidget(
      GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) => focused++,
        child: terminalLike(child: body),
      ),
    );
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(focused, 0, reason: 'o tap interno do terminal vence o sweep');
  });
}
