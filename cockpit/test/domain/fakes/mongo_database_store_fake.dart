import 'package:cockpit/app/cockpit/domain/contracts/mongo_database_store.dart';

/// [MongoDatabaseStore] em memória — a escolha de database do seletor Mongo
/// sem tocar Hive.
class FakeMongoDatabaseStore implements MongoDatabaseStore {
  FakeMongoDatabaseStore([Map<String, String>? seed]) : _byKey = {...?seed};

  final Map<String, String> _byKey;

  @override
  String? selected(String workspaceId, String connName) =>
      _byKey['$workspaceId::$connName'];

  @override
  Future<void> select(
    String workspaceId,
    String connName,
    String database,
  ) async => _byKey['$workspaceId::$connName'] = database;
}
