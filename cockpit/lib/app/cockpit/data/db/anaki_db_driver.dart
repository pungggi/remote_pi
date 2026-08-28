import 'dart:async';
import 'dart:isolate';

import 'package:anaki_mssql/anaki_mssql.dart';
import 'package:anaki_mysql/anaki_mysql.dart';
import 'package:anaki_orm/anaki_orm.dart';
import 'package:anaki_postgres/anaki_postgres.dart';
import 'package:anaki_sqlite/anaki_sqlite.dart';
import 'package:cockpit/app/cockpit/domain/contracts/db_driver.dart';
import 'package:cockpit/app/cockpit/domain/db_schema_sql.dart';
import 'package:cockpit/app/cockpit/domain/entities/db_connection.dart';
import 'package:cockpit/app/cockpit/domain/entities/db_result.dart';

/// Driver único sobre o **anakiORM** (conectores Rust via FFI) — SQLite,
/// Postgres e MySQL atrás do mesmo contrato [DbDriver].
///
/// A FFI do anaki é **bloqueante** (`block_on` no Rust + call direto no Dart),
/// então cada chamada roda inteira num `Isolate.run` (construir driver → open
/// → query → close). O slot de conexão é global por dylib — seguro porque o
/// `DbQueryService` serializa todas as execuções. Panics do Rust viram erro
/// normal (`ffi_guard`/catch_unwind — anakiORM#2, resolvido).
///
/// Caveats herdados (v1):
/// - `rawQuery` materializa todas as linhas antes do corte de `limit`;
/// - as colunas voltam em **ordem alfabética** (serde_json sem
///   `preserve_order`) — issue aberta upstream;
/// - timeout abandona o Isolate (não cancela o statement).
class AnakiDbDriver implements DbDriver {
  const AnakiDbDriver();

  static const _defaultTimeout = Duration(seconds: 30);

  @override
  Future<DbResult> query(
    DbConnection conn,
    String sql, {
    required int limit,
    Duration timeout = _defaultTimeout,
    String? password,
  }) => _run(conn, password, timeout, (driver, watch) async {
    final rows = await driver.rawQuery(sql, null);
    return _toResult(rows, limit: limit, watch: watch);
  });

  @override
  Future<DbResult> execute(
    DbConnection conn,
    String sql, {
    Duration timeout = _defaultTimeout,
    String? password,
  }) => _run(conn, password, timeout, (driver, watch) async {
    final affected = await driver.rawExecute(sql, null);
    return DbResult(
      columns: const [],
      rows: const [],
      elapsed: watch.elapsed,
      affectedRows: affected,
    );
  });

  @override
  Future<DbResult> schema(
    DbConnection conn, {
    String? table,
    String? schema,
    Duration timeout = _defaultTimeout,
    String? password,
  }) {
    final sql = dbSchemaSql(conn.engine, table: table, schema: schema);
    return _run(conn, password, timeout, (driver, watch) async {
      final rows = await driver.rawQuery(sql, null);
      return _toResult(rows, limit: 10000, watch: watch);
    });
  }

  /// Roda [body] num Isolate (a FFI bloqueia a thread): constrói o driver do
  /// engine lá dentro (bindings/FFI não são sendable), abre, executa, fecha.
  Future<DbResult> _run(
    DbConnection conn,
    String? password,
    Duration timeout,
    Future<DbResult> Function(AnakiDriver driver, Stopwatch watch) body,
  ) async {
    // Captura só valores sendable (o DbConnection é imutável e simples).
    try {
      return await Isolate.run(() async {
        final watch = Stopwatch()..start();
        final driver = _buildDriver(conn, password);
        try {
          await driver.rawOpen();
        } on AnakiException catch (e) {
          throw DbQueryException('connection_failed', _message(e));
        }
        try {
          return await body(driver, watch);
        } on ConnectionException catch (e) {
          throw DbQueryException('connection_failed', _message(e));
        } on AnakiException catch (e) {
          throw DbQueryException('query_failed', _message(e));
        } finally {
          try {
            await driver.rawClose();
          } on AnakiException {
            // Fechar falhou depois do resultado — nada útil a fazer.
          }
        }
      }).timeout(timeout);
    } on DbQueryException {
      rethrow;
    } on TimeoutException {
      throw DbQueryException('timeout', 'Query exceeded ${timeout.inSeconds}s');
    }
  }

  static AnakiDriver _buildDriver(DbConnection conn, String? password) {
    switch (conn.engine) {
      case DbEngine.sqlite:
        return SqliteDriver(conn.sqlitePath);
      case DbEngine.postgres:
        return PostgresDriver(
          host: conn.host,
          port: conn.port,
          username: conn.user,
          password: password ?? '',
          database: conn.database,
          // `?sslmode=` da URL; sem o param o Rust usa o default do sqlx.
          sslMode: Uri.parse(conn.url).queryParameters['sslmode'],
        );
      case DbEngine.mysql:
        return MysqlDriver(
          host: conn.host,
          port: conn.port,
          username: conn.user,
          password: password ?? '',
          database: conn.database,
          // `?ssl-mode=` da URL (REQUIRED etc); o driver espera minúsculo
          // (disabled/preferred/required/verify_ca/verify_identity).
          sslMode: Uri.parse(
            conn.url,
          ).queryParameters['ssl-mode']?.toLowerCase(),
        );
      case DbEngine.mssql:
        final params = Uri.parse(conn.url).queryParameters;
        return MssqlDriver(
          host: conn.host,
          port: conn.port,
          username: conn.user,
          password: password ?? '',
          database: conn.database,
          // `?trustcert=true` pra dev com cert self-signed.
          trustCert: params['trustcert'] == 'true',
          // `?encrypt=` do switch Use SSL/TLS; ausente = default do tiberius.
          encrypt: switch (params['encrypt']) {
            'true' => true,
            'false' => false,
            _ => null,
          },
        );
      case DbEngine.redis:
      case DbEngine.mongo:
        // Não-SQL: nunca chega aqui (registry devolve null; o CLI usa o
        // NoSqlCommandService). Fecha o switch exaustivo.
        throw DbQueryException(
          'unsupported_engine',
          '${conn.engine.label} is not a SQL engine.',
        );
    }
  }

  /// Converte as linhas-mapa do anaki no [DbResult] posicional do contrato.
  /// Ordem das colunas = ordem das chaves do JSON (alfabética por ora).
  static DbResult _toResult(
    List<Map<String, dynamic>> rows, {
    required int limit,
    required Stopwatch watch,
  }) {
    if (rows.isEmpty) {
      return DbResult(
        columns: const [],
        rows: const [],
        elapsed: watch.elapsed,
      );
    }
    final columns = rows.first.keys.toList();
    final truncated = rows.length > limit;
    final data = <List<Object?>>[
      for (final row in truncated ? rows.take(limit) : rows)
        [for (final c in columns) row[c]],
    ];
    return DbResult(
      columns: [
        for (var i = 0; i < columns.length; i++)
          DbColumn(columns[i], _inferType(data, i)),
      ],
      rows: data,
      truncated: truncated,
      elapsed: watch.elapsed,
    );
  }

  static String _message(AnakiException e) =>
      e.details == null ? e.message : '${e.message}\n${e.details}';

  static String _inferType(List<List<Object?>> rows, int col) {
    for (final row in rows) {
      final v = row[col];
      if (v == null) continue;
      return switch (v) {
        int() => 'INTEGER',
        double() => 'REAL',
        bool() => 'BOOL',
        String() => 'TEXT',
        _ => '',
      };
    }
    return '';
  }
}
