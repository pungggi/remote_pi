import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Cancela o zoom global do app para a subárvore do terminal.
///
/// O `_AppZoom` (app_widget.dart) faz o app inteiro ser layoutado numa tela
/// lógica menor (`size / scale`) e depois amplia tudo com um `FittedBox`. Para
/// vetor isso é perfeito (o Skia re-rasteriza); para o terminal não, porque o
/// flterm pinta a partir de um atlas de glifos **já rasterizado**, e ampliar
/// bitmap borra. Medido num monitor de DPR 1: 1.14x de ampliação.
///
/// Aqui a operação inversa é aplicada: o filho é layoutado numa caixa [scale]
/// vezes MAIOR (ou seja, de volta ao tamanho lógico real da janela) e reduzido
/// por `1/scale`. Composto com o zoom externo a matriz resultante é a
/// identidade, então nada é reamostrado. Quem repõe o tamanho visual é o
/// **tamanho da fonte**, multiplicado por [scale] pelo chamador.
///
/// **Por que um RenderObject próprio e NÃO um `LayoutBuilder`+`FittedBox`:** o
/// filho aqui é a `TerminalView` do flterm, uma StatefulWidget que faz *lease*
/// da view do controller no `initState` (`attachView`). Dentro do `builder:` de
/// um `LayoutBuilder`, a subárvore é RECONSTRUÍDA durante o layout; a cada
/// mudança de constraints (abrir/fechar um pane, split, rotação) o Flutter
/// RECRIA o Element da `TerminalView` — novo `initState`/`attachView` antes do
/// `dispose`/detach do antigo → "TerminalController already has an active
/// view". E no mount simultâneo (restore de 2+ panes no mesmo frame) esse mesmo
/// churn de Element cruzava a State entre panes → terminais ESPELHADOS. Como
/// `SingleChildRenderObjectWidget`, o [child] é filho DIRETO e estável: o
/// Element da `TerminalView` nunca é recriado por mudança de layout; só o
/// [RenderObject] recalcula tamanho e transform. Some o crash e o espelho.
class TerminalUnzoomBox extends SingleChildRenderObjectWidget {
  const TerminalUnzoomBox({
    super.key,
    required this.scale,
    required Widget super.child,
  });

  /// Zoom do `_AppZoom` a desfazer (`interfaceSize / 14`). `1.0` é no-op.
  final double scale;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTerminalUnzoom(scale);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTerminalUnzoom renderObject,
  ) => renderObject.scale = scale;
}

/// Layouta o filho numa caixa [scale]x MAIOR e o apresenta reduzido por
/// `1/scale`, sem reconstruir a subárvore (ao contrário de LayoutBuilder).
class _RenderTerminalUnzoom extends RenderProxyBox {
  _RenderTerminalUnzoom(this._scale);

  double _scale;
  set scale(double value) {
    if (value == _scale) return;
    _scale = value;
    markNeedsLayout();
  }

  bool get _active => (_scale - 1.0).abs() >= 0.001;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    // Sem zoom (1.0x) ou sem caixa definida: passa as constraints direto. O
    // filho é o MESMO Element em qualquer caso — nada remonta.
    if (!_active ||
        !constraints.hasBoundedWidth ||
        !constraints.hasBoundedHeight) {
      child.layout(constraints, parentUsesSize: true);
      size = child.size;
      return;
    }
    // Caixa real que apresentamos (o tamanho que o pai enxerga).
    final box = constraints.biggest;
    // O filho é layoutado numa grade `scale`x maior; o paint reduz por 1/scale.
    child.layout(
      BoxConstraints.tight(Size(box.width * _scale, box.height * _scale)),
      parentUsesSize: true,
    );
    size = box;
  }

  Matrix4 get _matrix => Matrix4.diagonal3Values(1 / _scale, 1 / _scale, 1.0);

  @override
  bool get alwaysNeedsCompositing => _active;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null || !_active) {
      // `layer` herdado do RenderObject é um LayerHandle interno: setar null
      // solta o TransformLayer anterior com o ref-count correto.
      layer = null;
      if (child != null) context.paintChild(child, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _matrix,
      (ctx, off) => ctx.paintChild(child, off),
      oldLayer: layer as TransformLayer?,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    if (!_active) return child.hitTest(result, position: position);
    return result.addWithPaintTransform(
      transform: _matrix,
      position: position,
      hitTest: (r, p) => child.hitTest(r, position: p),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (_active) transform.multiply(_matrix);
  }
}
