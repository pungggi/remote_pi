import 'package:cockpit/app/cockpit/domain/contracts/realm_repository.dart';
import 'package:cockpit/app/cockpit/domain/entities/realm.dart';
import 'package:cockpit/app/core/data/setup/json_state_store.dart';

/// Persiste realms num [JsonStateStore], um `Map` por id (mesmo estilo
/// schemaless do `JsonProjectRepository`). O realm Default é garantido em
/// [all]: se o store está vazio (instalação nova ou pré-realm), ele é criado
/// na hora.
class JsonRealmRepository implements RealmRepository {
  JsonRealmRepository(this._store);

  final JsonStateStore _store;

  static const String storeName = 'realms';

  /// Chave reservada (não-Map) pro id do realm ativo; `all()` a ignora.
  static const String _activeKey = '__active__';

  @override
  Future<List<Realm>> all() async {
    final realms = _store.values
        .whereType<Map<dynamic, dynamic>>()
        .map(_fromMap)
        .whereType<Realm>()
        .toList();
    if (!realms.any((r) => r.isDefault)) {
      final def = Realm(
        id: Realm.defaultId,
        name: 'Default',
        createdAt: DateTime.now(),
      );
      await save(def);
      realms.insert(0, def);
    }
    realms.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder != 0 ? byOrder : a.createdAt.compareTo(b.createdAt);
    });
    return realms;
  }

  @override
  Future<void> save(Realm realm) => _store.put(realm.id, _toMap(realm));

  @override
  Future<void> remove(String id) async {
    if (id == Realm.defaultId) return; // Default é indelével
    await _store.delete(id);
  }

  @override
  Future<String> loadActive() async {
    final v = _store.get(_activeKey);
    return v is String ? v : Realm.defaultId;
  }

  @override
  Future<void> saveActive(String id) => _store.put(_activeKey, id);

  Map<String, dynamic> _toMap(Realm r) => <String, dynamic>{
    'id': r.id,
    'name': r.name,
    'createdAt': r.createdAt.millisecondsSinceEpoch,
    'order': r.order,
  };

  Realm? _fromMap(Map<dynamic, dynamic> map) {
    final id = map['id'];
    if (id is! String) return null;
    return Realm(
      id: id,
      name: map['name'] as String? ?? 'Realm',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['createdAt'] as num?)?.toInt() ?? 0,
      ),
      order: (map['order'] as num?)?.toInt() ?? 0,
    );
  }
}
