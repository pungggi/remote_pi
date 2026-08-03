import 'package:cockpit/app/cockpit/data/repositories/json_project_repository.dart';
import 'package:cockpit/app/cockpit/domain/entities/realm.dart';
import 'package:cockpit/app/cockpit/domain/value_objects/uid.dart';
import 'package:cockpit/app/core/data/setup/json_state_store.dart';

/// Migração one-shot do schema pré-realm (id == path) pro schema atual
/// (id = UUID + campo `realm`). Roda no bootstrap do módulo, antes de qualquer
/// leitura; é **idempotente** — registro já migrado (id ≠ path) é ignorado.
///
/// O que migra, mantendo tudo que o usuário tinha:
/// - store `projects`: re-key path → UUID, grava `realm: default` no registro;
/// - store `layouts`: re-key da mesma chave (o layout segue o workspace);
/// - `__last_selected__` legado (global) → `__last_selected__::default`.
class ProjectSchemaMigrator {
  const ProjectSchemaMigrator();

  Future<void> run(
    JsonStateStore projectStore,
    JsonStateStore layoutStore,
  ) async {
    for (final key in projectStore.keys.toList()) {
      final value = projectStore.get(key);
      if (value is! Map) continue;
      final id = value['id'];
      final path = value['path'];
      if (id is! String || path is! String) continue;
      if (id != path) continue; // já migrado (UUID)

      final uid = newUid();
      final migrated = Map<String, dynamic>.of(value.cast<String, dynamic>())
        ..['id'] = uid
        ..['realm'] = value['realm'] as String? ?? Realm.defaultId;
      await projectStore.put(uid, migrated);
      if (key != uid) await projectStore.delete(key);

      // Layout acompanha o workspace (mesma chave antiga = path).
      final layout = layoutStore.get(id);
      if (layout != null) {
        await layoutStore.put(uid, layout);
        await layoutStore.delete(id);
      }

      // Ponteiro legado de seleção apontava pra este workspace? Re-aponta.
      final legacy = projectStore.get(JsonProjectRepository.lastSelectedPrefix);
      if (legacy == id) {
        await projectStore.put(JsonProjectRepository.lastSelectedPrefix, uid);
      }
    }

    // Ponteiro legado (global, sem sufixo de realm) → per-realm do Default.
    // Fora do loop: cobre também o caso do valor ser `__cockpit__` (nenhum
    // registro re-keyed o teria tocado).
    final legacy = projectStore.get(JsonProjectRepository.lastSelectedPrefix);
    if (legacy is String) {
      await projectStore.put(
        '${JsonProjectRepository.lastSelectedPrefix}::${Realm.defaultId}',
        legacy,
      );
      await projectStore.delete(JsonProjectRepository.lastSelectedPrefix);
    }
  }
}
