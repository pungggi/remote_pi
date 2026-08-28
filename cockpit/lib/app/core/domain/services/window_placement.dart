import 'dart:ui';

/// Encaixa os bounds salvos de uma janela na topologia de monitores ATUAL.
///
/// Os bounds vêm do último encerramento, quando o arranjo de telas podia ser
/// outro: desacoplar um notebook de um monitor externo, trocar a resolução ou
/// mudar a escala deixa a posição salva apontando pra um espaço que não existe
/// mais. Sem esse encaixe a janela reabre fora da vista — o caso clássico é
/// vir de um monitor grande pra um menor e a janela nascer "longe", inteira ou
/// quase inteira fora da tela, sem barra de título alcançável pra trazê-la de
/// volta.
///
/// A regra é a de sempre em gerenciador de janelas: escolher a tela que MAIS
/// contém a janela salva, e trazê-la pra dentro da área útil dessa tela
/// (encolhendo antes de mover, porque uma janela maior que a tela nunca cabe só
/// com deslocamento). Sem nenhuma sobreposição — a tela onde ela estava sumiu —
/// ela vai pro centro da tela primária.
///
/// [workAreas] são as áreas ÚTEIS (já sem barra de tarefas/dock), a primeira
/// sendo a primária. Lista vazia = nada a fazer (não dá pra decidir), devolve
/// [saved] intacto. Função pura pra ser testável sem plugin de janela.
Rect fitWindowBounds({
  required Rect saved,
  required List<Rect> workAreas,
  required Size minSize,
}) {
  if (workAreas.isEmpty) return saved;

  final match = _bestMatch(saved, workAreas);
  final target = match ?? workAreas.first;
  final recenter = match == null;

  // Encolher primeiro: a janela precisa caber na tela antes de valer a pena
  // procurar posição. `minSize` é o piso do app, mas uma tela menor que ele
  // vence — melhor uma janela do tamanho da tela do que uma que transborda.
  final width = saved.width.clamp(
    minSize.width > target.width ? target.width : minSize.width,
    target.width,
  );
  final height = saved.height.clamp(
    minSize.height > target.height ? target.height : minSize.height,
    target.height,
  );

  if (recenter) {
    return Rect.fromLTWH(
      target.left + (target.width - width) / 2,
      target.top + (target.height - height) / 2,
      width,
      height,
    );
  }

  // `right/bottom - tamanho` nunca fica antes de `left/top` porque o tamanho já
  // foi limitado à área útil acima.
  final left = saved.left.clamp(target.left, target.right - width);
  final top = saved.top.clamp(target.top, target.bottom - height);
  return Rect.fromLTWH(left, top, width, height);
}

/// Área útil com maior sobreposição com [saved]; `null` se a janela não toca
/// nenhuma (a tela onde ela estava não existe mais).
Rect? _bestMatch(Rect saved, List<Rect> workAreas) {
  Rect? best;
  var bestArea = 0.0;
  for (final area in workAreas) {
    final overlap = area.intersect(saved);
    if (overlap.isEmpty) continue;
    final size = overlap.width * overlap.height;
    if (size > bestArea) {
      bestArea = size;
      best = area;
    }
  }
  return best;
}
