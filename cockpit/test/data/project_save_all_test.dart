import 'dart:io';

import 'package:cockpit/app/cockpit/data/repositories/json_project_repository.dart';
import 'package:cockpit/app/cockpit/domain/entities/project.dart';
import 'package:cockpit/app/core/data/setup/json_state_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reordenar o rail salvava um workspace por vez, e cada `save` só resolve
/// depois da própria janela de debounce do store (150ms, reiniciada a cada
/// gravação). Com uma dúzia de workspaces isso somava ~2s antes de a lista
/// assentar. `saveAll` fecha tudo numa escrita só.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('cockpit-projects'));
  tearDown(() => dir.deleteSync(recursive: true));

  Project project(String id, int order) => Project(
    id: id,
    name: id,
    path: '/tmp/$id',
    colorValue: 0xFF000000,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    order: order,
  );

  test('saveAll persiste todos numa escrita só', () async {
    final store = await JsonStateStore.open(dir.path, 'projects');
    final repo = JsonProjectRepository(store);
    final projetos = [for (var i = 0; i < 12; i++) project('ws$i', 11 - i)];

    final relogio = Stopwatch()..start();
    await repo.saveAll(projetos);
    relogio.stop();

    // Uma janela de debounce, não doze: o teto é folgado de propósito (CI
    // lento), e ainda assim ficaria muito abaixo dos ~1.8s do caminho antigo.
    expect(relogio.elapsed, lessThan(const Duration(milliseconds: 900)));

    final lidos = await repo.all();
    expect(lidos.length, 12);
    expect(
      lidos.firstWhere((p) => p.id == 'ws0').order,
      11,
      reason: 'a ordem de cada projeto tem que sobreviver ao lote',
    );
  });
}
