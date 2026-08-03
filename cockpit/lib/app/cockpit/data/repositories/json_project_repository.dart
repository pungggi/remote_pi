import 'package:cockpit/app/cockpit/domain/contracts/project_repository.dart';
import 'package:cockpit/app/cockpit/domain/entities/project.dart';
import 'package:cockpit/app/cockpit/domain/entities/realm.dart';
import 'package:cockpit/app/core/data/setup/json_state_store.dart';
import 'package:cockpit/app/core/utils/path_utils.dart';

/// Persiste projetos num [JsonStateStore], um `Map` por id — mesma semântica
/// schemaless do antigo `HiveProjectRepository`.
class JsonProjectRepository implements ProjectRepository {
  JsonProjectRepository(this._store);

  /// Store aberto no bootstrap do módulo. Guarda `Map` por `project.id`.
  final JsonStateStore _store;

  static const String storeName = 'projects';

  /// Prefixo das chaves reservadas (não-Map) do último workspace selecionado,
  /// **uma por realm** (`__last_selected__::<realmId>`). Não colide com ids de
  /// projeto (UUIDs) e o `all()` as ignora (`whereType<Map>`). A chave legada
  /// sem sufixo é migrada pro realm Default pelo `ProjectSchemaMigrator`.
  static const String lastSelectedPrefix = '__last_selected__';

  static String _lastSelectedKey(String realmId) =>
      '$lastSelectedPrefix::$realmId';

  @override
  Future<List<Project>> all() async {
    final projects = _store.values
        .whereType<Map<dynamic, dynamic>>()
        .map(_fromMap)
        .whereType<Project>()
        .toList();
    // Ordem manual do usuário (drag-drop); `createdAt` como desempate e como
    // fallback para dados antigos (todos com order=0 → caem no createdAt).
    projects.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder != 0 ? byOrder : a.createdAt.compareTo(b.createdAt);
    });
    return projects;
  }

  @override
  Future<void> save(Project project) => _store.put(project.id, _toMap(project));

  @override
  Future<void> remove(String id) => _store.delete(id);

  @override
  Future<String?> loadLastSelected(String realmId) async {
    final v = _store.get(_lastSelectedKey(realmId));
    return v is String ? v : null;
  }

  @override
  Future<void> saveLastSelected(String realmId, String? id) async {
    if (id == null) {
      await _store.delete(_lastSelectedKey(realmId));
    } else {
      await _store.put(_lastSelectedKey(realmId), id);
    }
  }

  Map<String, dynamic> _toMap(Project p) => <String, dynamic>{
    'id': p.id,
    'name': p.name,
    'path': p.path,
    'color': p.colorValue,
    'createdAt': p.createdAt.millisecondsSinceEpoch,
    'order': p.order,
    'image': p.imagePath,
    'realm': p.realmId,
    'pinned': p.pinned,
  };

  Project? _fromMap(Map<dynamic, dynamic> map) {
    final id = map['id'];
    final raw = map['path'];
    if (id is! String || raw is! String) return null;
    // Migração de dados antigos do Windows: instalações anteriores gravaram a
    // raiz com `\` (vinha crua do diálogo nativo). Normalizar na leitura basta —
    // é idempotente, e o próximo `save` já persiste a forma canônica. Sem isso,
    // a raiz salva não casaria com os filhos da árvore (já normalizados) e
    // `rootContaining` devolveria null para o workspace inteiro.
    final path = normalizePath(raw);
    return Project(
      id: id,
      name: map['name'] as String? ?? path,
      path: path,
      colorValue: (map['color'] as num?)?.toInt() ?? 0xFF00FF41,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['createdAt'] as num?)?.toInt() ?? 0,
      ),
      // Ausente em dados de versões anteriores → 0 (ordena por createdAt).
      order: (map['order'] as num?)?.toInt() ?? 0,
      imagePath: map['image'] as String?,
      // Ausente em dados pré-realm → Default (o migrador normalmente já gravou).
      realmId: map['realm'] as String? ?? Realm.defaultId,
      // Ausente em dados pré-pin → false.
      pinned: map['pinned'] as bool? ?? false,
    );
  }
}
