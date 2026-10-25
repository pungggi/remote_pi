import 'package:cockpit/app/core/ui/settings_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Atalhos de zoom da interface (⌘= / ⌘- / ⌘0; Ctrl fora do macOS): mexem no
/// `interfaceSize` do [SettingsController]. Compartilhados pela janela
/// principal ([AppRoot]) e pela janela de documento, que precisam do mesmo
/// gesto e da mesma escala.
Map<ShortcutActivator, VoidCallback> zoomBindings(
  SettingsController controller,
) {
  void by(double delta) {
    final next = (controller.settings.interfaceSize + delta).clamp(11.0, 22.0);
    controller.setInterfaceSize(next);
  }

  void reset() => controller.setInterfaceSize(14);

  return <ShortcutActivator, VoidCallback>{
    for (final mod in const [true, false]) ...{
      SingleActivator(LogicalKeyboardKey.equal, meta: mod, control: !mod): () =>
          by(1),
      SingleActivator(
        LogicalKeyboardKey.numpadAdd,
        meta: mod,
        control: !mod,
      ): () =>
          by(1),
      SingleActivator(LogicalKeyboardKey.minus, meta: mod, control: !mod): () =>
          by(-1),
      SingleActivator(
        LogicalKeyboardKey.numpadSubtract,
        meta: mod,
        control: !mod,
      ): () =>
          by(-1),
      SingleActivator(LogicalKeyboardKey.digit0, meta: mod, control: !mod):
          reset,
    },
  };
}

/// Zoom do **app inteiro**: lê o app num espaço lógico reduzido (`size/scale`) e
/// escala de volta com `FittedBox`, então tudo (texto, ícones, panes, app bar)
/// cresce junto — não só o texto. Vetores (texto/ícones) são re-rasterizados pelo
/// Skia (nítidos); bitmaps (imagens) interpolam. `scale == 1` é no-op.
class AppZoom extends StatelessWidget {
  const AppZoom({super.key, required this.scale, required this.child});
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if ((scale - 1.0).abs() < 0.001) return child;
    final mq = MediaQuery.of(context);
    final scaled = mq.size / scale;
    return MediaQuery(
      // Layout pensa numa tela menor (`size/scale`) → os elementos ocupam mais
      // dela; o `FittedBox` amplia pro tamanho real da janela. Uso FittedBox (e
      // não `Transform.scale` cru) porque ele **reporta o tamanho da janela** — o
      // Transform reportaria o tamanho lógico reduzido e um ancestral cortaria a
      // direita/baixo (Files e composer somindo). Gestos/hit-test são convertidos
      // pro espaço lógico automaticamente.
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
  }
}
