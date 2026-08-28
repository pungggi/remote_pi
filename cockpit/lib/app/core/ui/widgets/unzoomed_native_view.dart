import 'dart:io';

import 'package:cockpit/app/core/terminal/terminal_zoom.dart';
import 'package:cockpit/app/core/ui/settings_controller.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Cancela o zoom do app ([_AppZoom] em `app_widget.dart`) no ramo de uma
/// **platform view nativa** (hoje: os `InAppWebView` do navegador e dos previews
/// de markdown/HTML).
///
/// Por que existe: o zoom do app é um `FittedBox` que envolve a árvore inteira.
/// Ele converte o hit-test **do Flutter**, mas uma platform view recebe os
/// eventos de mouse direto do sistema (AppKit → `WKWebView`), sem saber da
/// escala. A camada aparece escalada e o hit-test acontece na escala original:
/// a seleção de texto "pega" deslocada, com erro proporcional à distância do
/// canto superior esquerdo (medido: fator igual ao `interfaceSize / 14`).
///
/// A correção é geométrica: dentro do espaço lógico reduzido, damos ao filho um
/// tamanho `scale` vezes maior e o encolhemos de volta por `1/scale`. O zoom do
/// app multiplica por `scale` logo acima, então a transform resultante sobre a
/// view nativa é **1** — pintura e eventos voltam a coincidir.
///
/// O tamanho aparente do conteúdo é preservado pelo próprio motor da view: o
/// [builder] recebe o fator e o repassa ao zoom nativo (no webview,
/// `InAppWebViewSettings.pageZoom`). Assim o usuário continua vendo a página no
/// tamanho que o zoom do app manda, mas o clique cai onde ele mira.
///
/// **Só age no macOS**, por duas razões que andam juntas:
/// - é onde o desalinhamento existe: no iOS/Android as platform views recebem
///   os eventos pela via do Flutter (que já converte a escala);
/// - é onde a compensação existe: `pageZoom` é iOS 14+/macOS 11+ apenas. No
///   Android (WebView do sistema) e no Windows (WebView2) ele é ignorado, então
///   tirar o zoom aqui deixaria o conteúdo menor, sem nada devolvendo o tamanho.
///
/// Fora do macOS o widget é transparente: entrega o filho com zoom 1.0 e sem
/// mexer no layout, exatamente como antes de existir.
class UnzoomedNativeView extends StatelessWidget {
  const UnzoomedNativeView({super.key, required this.builder});

  /// Constrói a view nativa. Recebe o fator de zoom que o motor da própria view
  /// deve aplicar ao conteúdo (1.0 quando o app está sem zoom).
  final Widget Function(BuildContext context, double contentZoom) builder;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS) return builder(context, 1.0);
    final scale = context.select<SettingsController, double>(
      (c) => c.settings.interfaceSize / 14.0,
    );
    if ((scale - 1.0).abs() < 0.001) return builder(context, 1.0);

    // Reusa o [TerminalUnzoomBox]: a geometria é a mesma (layouta o filho numa
    // caixa `scale`x maior e o apresenta reduzido por `1/scale`) e ele é um
    // RenderObject, não um `LayoutBuilder`.
    //
    // A distinção importa: dentro do `builder:` de um LayoutBuilder a subárvore
    // é reconstruída durante o layout, e na reestruturação da árvore de panes
    // (split/close) o Element do filho é recriado. Para a `TerminalView` isso
    // causava "TerminalController already has an active view"; para um webview
    // significaria recriar a platform view — ou seja, a página RECARREGANDO a
    // cada mudança de layout. Como filho direto de um RenderObject, o Element é
    // estável e só a geometria é recalculada.
    return TerminalUnzoomBox(scale: scale, child: builder(context, scale));
  }
}
