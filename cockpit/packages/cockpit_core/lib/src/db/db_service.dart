/// Descritor de conexão de DB no fio (plano 58, Wave 4). Plano — o cliente
/// resolve a conexão (URL/segredo) e manda ao servidor, que executa a query
/// no host. Campos derivados do `DbConnection` do app.
class RemoteDbConnDescriptor {
  const RemoteDbConnDescriptor({
    required this.engine,
    this.url = '',
    this.host = '',
    this.port,
    this.user = '',
    this.database = '',
    this.sqlitePath = '',
    this.password,
    this.useTls = false,
  });

  /// `sqlite` | `postgres` | `mysql` | `mssql` | `redis` | `mongo`.
  final String engine;
  final String url;
  final String host;
  final int? port;
  final String user;
  final String database;
  final String sqlitePath;
  final String? password;

  /// TLS pro Redis (`rediss://`); ignorado pelos demais engines (Postgres/…
  /// derivam de query params na URL; Mongo, do scheme).
  final bool useTls;

  Map<String, Object?> toJson() => {
    'engine': engine,
    if (url.isNotEmpty) 'url': url,
    if (host.isNotEmpty) 'host': host,
    if (port != null) 'port': port,
    if (user.isNotEmpty) 'user': user,
    if (database.isNotEmpty) 'database': database,
    if (sqlitePath.isNotEmpty) 'sqlitePath': sqlitePath,
    if (password != null) 'password': password,
    if (useTls) 'useTls': useTls,
  };

  factory RemoteDbConnDescriptor.fromJson(Map<String, Object?> j) =>
      RemoteDbConnDescriptor(
        engine: j['engine'] as String,
        url: j['url'] as String? ?? '',
        host: j['host'] as String? ?? '',
        port: (j['port'] as num?)?.toInt(),
        user: j['user'] as String? ?? '',
        database: j['database'] as String? ?? '',
        sqlitePath: j['sqlitePath'] as String? ?? '',
        password: j['password'] as String?,
        useTls: j['useTls'] as bool? ?? false,
      );
}

enum DbErrorKind { connectionFailed, queryFailed, timeout, unsupportedEngine }

class DbServiceException implements Exception {
  const DbServiceException(this.kind, [this.detail]);
  final DbErrorKind kind;
  final String? detail;

  @override
  String toString() => 'DbServiceException(${kind.name}: $detail)';
}

/// Executa queries SQL contra um DB, do lado do host (plano 58, Wave 4). O
/// resultado é o mapa já-JSON do `DbResult` do app (columns/rows/…), montado
/// no servidor e reidratado no cliente.
abstract interface class DbService {
  /// Roda [sql]. [dml] = execute (INSERT/UPDATE/…) em vez de query.
  Future<Map<String, Object?>> query(
    RemoteDbConnDescriptor conn,
    String sql, {
    int limit = 200,
    bool dml = false,
  });

  /// Redis: envia [parts] (`['GET','foo']`) e devolve o reply JSON-serializável.
  Future<Object?> redis(RemoteDbConnDescriptor conn, List<String> parts);

  /// Redis em lote: [commands] em sequência numa única conexão, replies na
  /// mesma ordem (tabela do plano 52).
  Future<List<Object?>> redisMany(
    RemoteDbConnDescriptor conn,
    List<List<String>> commands,
  );

  /// Mongo: roda [command] (`runCommand`) → documento de resposta. [database]
  /// força o alvo (seletor do painel); ausente = o da URL/fallback.
  Future<Object?> mongo(
    RemoteDbConnDescriptor conn,
    Map<String, Object?> command, {
    String? database,
  });
}
