import 'package:cockpit/app/core/utils/platform_kind.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';

/// Abre um menu de contexto pelo gesto certo de cada plataforma: **botão
/// direito** no desktop e, **só no mobile**, também **toque longo**.
///
/// O long-press fica fora do desktop de propósito: lá ele se confunde com o
/// começo de um arrasto (reordenar workspace, mover aba), e o mouse já tem o
/// botão secundário. No mobile não há botão secundário, e o arrasto tem
/// afordância própria (a alça de reordenar), então o toque longo está livre.
///
/// Envolve o filho sem interferir no tap primário — quem estiver dentro
/// (`HoverTap` e afins) segue recebendo o toque normal.
///
/// **Cuidado**: onde o filho já usa `LongPressDraggable` no mobile (linha da
/// árvore de arquivos, aba do pane), o toque longo *já é* o arrasto — os dois
/// disputariam a arena de gestos. Nesses lugares passe
/// [longPressOnMobile] `false`; o botão direito continua valendo no desktop.
class ContextMenuGesture extends StatelessWidget {
  const ContextMenuGesture({
    super.key,
    required this.onMenu,
    required this.child,
    this.enabled = true,
    this.longPressOnMobile = true,
    this.behavior,
  });

  /// Abre o menu na posição **global** do gesto.
  final void Function(Offset globalPosition) onMenu;

  final Widget child;

  /// `false` desliga os dois gestos (ex.: linha em modo rename).
  final bool enabled;

  /// `false` quando o toque longo já pertence a um `LongPressDraggable` do
  /// próprio filho — ver o aviso na doc da classe.
  final bool longPressOnMobile;

  final HitTestBehavior? behavior;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return GestureDetector(
      behavior: behavior,
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      onLongPressStart: isMobilePlatform && longPressOnMobile
          ? (d) {
              // O menu abre com o dedo ainda na tela; o toque confirma que o
              // gesto pegou, como em qualquer long-press do sistema.
              HapticFeedback.mediumImpact();
              onMenu(d.globalPosition);
            }
          : null,
      child: child,
    );
  }
}
