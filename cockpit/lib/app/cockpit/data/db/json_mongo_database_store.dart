import 'package:cockpit/app/cockpit/domain/contracts/mongo_database_store.dart';
import 'package:cockpit/app/core/data/setup/json_state_store.dart';

/// [MongoDatabaseStore] numa chave própria do store de settings — mesmo padrão
/// do `JsonSshHostKeyStore`: um mapa simples.
class JsonMongoDatabaseStore implements MongoDatabaseStore {
  JsonMongoDatabaseStore(this._store);

  final JsonStateStore _store;

  static const String _key = 'mongo_selected_databases';

  /// `workspaceId::connName` — o `::` não aparece em UUID de workspace, e nome
  /// de conexão com `:` continua sem colidir (o split é pelo primeiro).
  static String entryKey(String workspaceId, String connName) =>
      '$workspaceId::$connName';

  Map<String, String> _all() {
    final raw = _store.get(_key);
    if (raw is! Map) return {};
    return {
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }

  @override
  String? selected(String workspaceId, String connName) =>
      _all()[entryKey(workspaceId, connName)];

  @override
  Future<void> select(String workspaceId, String connName, String database) =>
      _store.put(_key, _all()..[entryKey(workspaceId, connName)] = database);
}
