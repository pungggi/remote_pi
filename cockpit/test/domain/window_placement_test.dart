import 'dart:ui';

import 'package:cockpit/app/core/domain/services/window_placement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const minSize = Size(720, 480);

  // Área útil de um 1920x1080 primário (barra de tarefas de 40px embaixo).
  const primary = Rect.fromLTWH(0, 0, 1920, 1040);
  // Monitor externo maior, à direita.
  const external = Rect.fromLTWH(1920, 0, 2560, 1400);

  Rect fit(Rect saved, List<Rect> areas) =>
      fitWindowBounds(saved: saved, workAreas: areas, minSize: minSize);

  test('bounds já dentro de uma tela ficam intactos', () {
    const saved = Rect.fromLTWH(100, 80, 1280, 720);
    expect(fit(saved, [primary, external]), saved);
  });

  test('sem monitores conhecidos devolve os bounds salvos', () {
    const saved = Rect.fromLTWH(9999, 9999, 1280, 720);
    expect(fit(saved, const []), saved);
  });

  test('janela no monitor externo desligado volta ao centro do primário', () {
    // Estava inteira no externo; o arranjo de agora só tem o primário.
    const saved = Rect.fromLTWH(2200, 200, 1280, 720);
    final r = fit(saved, [primary]);

    expect(primary.contains(r.topLeft), isTrue);
    expect(primary.contains(r.bottomRight - const Offset(1, 1)), isTrue);
    expect(r.width, 1280);
    expect(r.height, 720);
    // Centralizada: mesmas sobras dos dois lados.
    expect(r.left, (primary.width - 1280) / 2);
    expect(r.top, (primary.height - 720) / 2);
  });

  test('vindo de tela maior, encolhe até caber na menor', () {
    // 2400x1300 cabia no externo; no primário (1920x1040) não cabe.
    const saved = Rect.fromLTWH(1950, 30, 2400, 1300);
    final r = fit(saved, [primary]);

    expect(r.width, primary.width);
    expect(r.height, primary.height);
    expect(r.left, primary.left);
    expect(r.top, primary.top);
  });

  test('janela meio pra fora é trazida pra dentro sem mudar de tamanho', () {
    // Só a borda esquerda aparece: sobra pra direita do primário.
    const saved = Rect.fromLTWH(1800, 900, 1280, 720);
    final r = fit(saved, [primary]);

    expect(r.width, 1280);
    expect(r.height, 720);
    expect(r.right, primary.right);
    expect(r.bottom, primary.bottom);
  });

  test('posição negativa (acima/à esquerda) é puxada pra origem útil', () {
    const saved = Rect.fromLTWH(-400, -300, 1280, 720);
    final r = fit(saved, [primary]);

    expect(r.left, primary.left);
    expect(r.top, primary.top);
  });

  test('escolhe a tela com maior sobreposição, não a primária', () {
    // Cruza a fronteira, com a maior parte no externo.
    const saved = Rect.fromLTWH(1800, 100, 1280, 720);
    final r = fit(saved, [primary, external]);

    // Cabe inteira no externo → só desloca o mínimo pra entrar nele.
    expect(r.left, external.left);
    expect(r.top, 100);
    expect(r.width, 1280);
  });

  test('tela menor que o mínimo do app vence o mínimo', () {
    const tiny = Rect.fromLTWH(0, 0, 640, 400);
    const saved = Rect.fromLTWH(0, 0, 1280, 720);
    final r = fit(saved, [tiny]);

    expect(r.width, 640);
    expect(r.height, 400);
  });

  test('nunca devolve tamanho abaixo do mínimo quando a tela comporta', () {
    const saved = Rect.fromLTWH(10, 10, 100, 100);
    final r = fit(saved, [primary]);

    expect(r.width, minSize.width);
    expect(r.height, minSize.height);
  });

  test('monitor à esquerda (coordenadas negativas) é respeitado', () {
    const left = Rect.fromLTWH(-1920, 0, 1920, 1040);
    const saved = Rect.fromLTWH(-1800, 100, 1280, 720);
    expect(fit(saved, [primary, left]), saved);
  });
}
