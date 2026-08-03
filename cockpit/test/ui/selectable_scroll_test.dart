import 'package:cockpit/app/core/ui/widgets/selectable_scroll.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regressão da seleção que escorrega ao rolar.
///
/// O app é escalado inteiro pelo "Interface size" (`_AppZoom` = MediaQuery
/// reduzida + FittedBox). Com um `Scrollable` DENTRO de uma `SelectionArea`, o
/// Flutter reconstrói a âncora do arraste subtraindo `position.pixels` (pixels
/// locais do scrollable) de uma coordenada tratada como **global** — as duas
/// unidades divergem sob escala e a seleção erra por
/// `offsetDoScroll * (escala - 1)`. Zero no topo, crescendo conforme rola.
///
/// O invariante testado: clicar no meio de uma linha DESENHADA seleciona
/// aquela linha — antes e depois de rolar, com e sem zoom.
final _ctrl = ScrollController();

Widget host({required double scale, required bool selectionOutsideScroll}) {
  final content = Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < 40; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('Linha ${i.toString().padLeft(2, '0')} conteudo'),
        ),
    ],
  );
  return MaterialApp(
    // Espelha o _AppZoom do app.
    builder: (context, child) {
      if ((scale - 1.0).abs() < 0.001) return child!;
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
            child: child,
          ),
        ),
      );
    },
    home: Scaffold(
      body: selectionOutsideScroll
          // Arranjo antigo (bugado): SelectionArea em volta do scroll.
          ? SelectionArea(
              child: SingleChildScrollView(controller: _ctrl, child: content),
            )
          : SelectableScroll(controller: _ctrl, child: content),
    ),
  );
}

/// Centro vertical (em coordenadas de janela) da linha [label] como desenhada.
double centerOf(WidgetTester tester, String label) {
  final e = find
      .byType(RichText)
      .evaluate()
      .firstWhere((e) => (e.widget as RichText).text.toPlainText() == label);
  final box = e.renderObject! as RenderBox;
  final top = box.localToGlobal(Offset.zero).dy;
  final bottom = box.localToGlobal(box.size.bottomRight(Offset.zero)).dy;
  return (top + bottom) / 2;
}

/// Arrasta na horizontal na altura [y] e devolve o texto copiado.
Future<String?> selectAt(WidgetTester tester, double y) async {
  String? copied;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    },
  );
  final g = await tester.startGesture(
    Offset(30, y),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await g.moveTo(Offset(500, y));
  await tester.pump();
  await g.up();
  await tester.pump();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
  return copied;
}

void main() {
  const target = 'Linha 20 conteudo';

  for (final scale in const [1.0, 16 / 14]) {
    testWidgets('SelectableScroll: seleção certa após rolar — zoom $scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(scale: scale, selectionOutsideScroll: false),
      );
      await tester.pumpAndSettle();
      _ctrl.jumpTo(300);
      await tester.pumpAndSettle();

      final copied = await selectAt(tester, centerOf(tester, target));
      expect(copied, isNotNull);
      expect(
        target.contains(copied!.trim()),
        isTrue,
        reason: 'copiou "$copied"',
      );
    });
  }

  testWidgets(
    'arranjo antigo (SelectionArea em volta do scroll) erra com zoom',
    (tester) async {
      await tester.pumpWidget(
        host(scale: 16 / 14, selectionOutsideScroll: true),
      );
      await tester.pumpAndSettle();
      _ctrl.jumpTo(300);
      await tester.pumpAndSettle();

      final copied = await selectAt(tester, centerOf(tester, target));
      expect(
        target.contains(copied?.trim() ?? ''),
        isFalse,
        reason: 'era pra escorregar pra outra linha, mas copiou "$copied"',
      );
    },
  );
}
