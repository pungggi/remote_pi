import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter/widgets.dart';

/// Scroll vertical com **seleção de texto que não escorrega ao rolar**.
///
/// ## A regra: `SelectionArea` vai DENTRO do scroll, nunca em volta dele
///
/// Parece o contrário do intuitivo (e do que a doc do Flutter sugere), mas
/// envolver um `Scrollable` numa `SelectionArea` quebra a seleção **neste app**
/// por causa do zoom global do "Interface size" (`_AppZoom` em
/// `app_widget.dart`, um `FittedBox` que escala o app inteiro).
///
/// Quando há um `Scrollable` **descendente** da `SelectionArea`, o Flutter
/// instala o `_ScrollableSelectionContainerDelegate` (scrollable.dart). Pra
/// manter a seleção ancorada no conteúdo enquanto rola, ele guarda a âncora do
/// arraste somada ao offset do scroll e depois reconstrói uma "globalPosition"
/// subtraindo `position.pixels` (`_getDeltaToScrollOrigin` →
/// `ensureChildUpdated`). Só que `position.pixels` está em pixels **locais do
/// scrollable** e o resultado é usado como coordenada **global** (de janela).
/// Com qualquer escala entre o scrollable e a raiz, as duas unidades divergem e
/// a seleção erra por `offsetDoScroll * (escala - 1)`.
///
/// Daí o sintoma: seleção certa enquanto o scroll está no topo (erro zero) e
/// cada vez mais deslocada **para baixo** conforme se rola — em 16pt de
/// interface (escala 1.14), ~1 linha a cada 300px rolados.
///
/// Com a `SelectionArea` dentro do scroll não há `Scrollable` descendente, o
/// delegate nunca entra e a seleção usa só `globalToLocal` (que atravessa o
/// `FittedBox` corretamente).
///
/// **Custo aceito**: perde-se o auto-scroll ao arrastar a seleção além da borda
/// do viewport. Seleção correta vale mais que o auto-scroll.
///
/// Um `Scrollable` **dentro** do conteúdo (ex.: bloco de código com scroll
/// horizontal) reintroduz o problema no eixo dele — se isso incomodar, a mesma
/// regra vale lá: `SelectionArea` mais interna que o scroll.
class SelectableScroll extends StatelessWidget {
  const SelectableScroll({
    super.key,
    required this.child,
    this.padding,
    this.controller,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: controller,
      padding: padding,
      child: SelectionArea(child: child),
    );
  }
}
