import 'package:cockpit/app/cockpit/domain/entities/db_connection.dart';
import 'package:cockpit/app/cockpit/domain/entities/db_result.dart';

/// SQL de introspecção de schema por engine (tabelas quando [table] é null;
/// colunas de [table] caso contrário). Compartilhado pelo driver local
/// ([AnakiDbDriver]) e pelo caminho remoto (plano 58, Wave 4). SQL-only.
String dbSchemaSql(DbEngine engine, {String? table, String? schema}) {
  final t = table == null ? null : _safeIdent(table);
  switch (engine) {
    case DbEngine.sqlite:
      return t == null
          ? 'SELECT name AS "table", NULL AS "schema", type '
                'FROM sqlite_master '
                "WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' "
                'ORDER BY name'
          : 'SELECT name AS "column", type, '
                '(CASE "notnull" WHEN 0 THEN 1 ELSE 0 END) AS nullable, '
                'pk AS "primaryKey" FROM pragma_table_info(\'$t\')';
    case DbEngine.postgres:
      final s = _safeIdent(schema ?? 'public');
      return t == null
          ? 'SELECT table_name AS "table", table_schema AS "schema", '
                "CASE table_type WHEN 'VIEW' THEN 'view' ELSE 'table' END "
                'AS type FROM information_schema.tables '
                "WHERE table_schema NOT IN ('pg_catalog','information_schema')"
                ' ORDER BY table_schema, table_name'
          : 'SELECT c.column_name AS "column", c.data_type AS type, '
                "CASE WHEN c.is_nullable = 'YES' THEN 1 ELSE 0 END "
                'AS nullable, '
                'CASE WHEN pk.column_name IS NULL THEN 0 ELSE 1 END '
                'AS "primaryKey" '
                'FROM information_schema.columns c '
                'LEFT JOIN ('
                ' SELECT kcu.column_name '
                ' FROM information_schema.table_constraints tc '
                ' JOIN information_schema.key_column_usage kcu '
                '   ON kcu.constraint_name = tc.constraint_name '
                '  AND kcu.table_schema = tc.table_schema '
                " WHERE tc.constraint_type = 'PRIMARY KEY' "
                "  AND tc.table_schema = '$s' AND tc.table_name = '$t'"
                ') pk ON pk.column_name = c.column_name '
                "WHERE c.table_schema = '$s' AND c.table_name = '$t' "
                'ORDER BY c.ordinal_position';
    case DbEngine.mysql:
      return t == null
          ? 'SELECT table_name AS `table`, table_schema AS `schema`, '
                "CASE table_type WHEN 'VIEW' THEN 'view' ELSE 'table' END "
                'AS type FROM information_schema.tables '
                'WHERE table_schema = DATABASE() ORDER BY table_name'
          : 'SELECT column_name AS `column`, data_type AS type, '
                "CASE is_nullable WHEN 'YES' THEN 1 ELSE 0 END AS nullable, "
                "CASE column_key WHEN 'PRI' THEN 1 ELSE 0 END "
                'AS `primaryKey` FROM information_schema.columns '
                "WHERE table_schema = DATABASE() AND table_name = '$t' "
                'ORDER BY ordinal_position';
    case DbEngine.mssql:
      final s = _safeIdent(schema ?? 'dbo');
      return t == null
          ? 'SELECT TABLE_NAME AS [table], TABLE_SCHEMA AS [schema], '
                "CASE TABLE_TYPE WHEN 'VIEW' THEN 'view' ELSE 'table' END "
                'AS type FROM INFORMATION_SCHEMA.TABLES '
                'ORDER BY TABLE_SCHEMA, TABLE_NAME'
          : 'SELECT c.COLUMN_NAME AS [column], c.DATA_TYPE AS type, '
                "CASE c.IS_NULLABLE WHEN 'YES' THEN 1 ELSE 0 END "
                'AS nullable, '
                'CASE WHEN pk.COLUMN_NAME IS NULL THEN 0 ELSE 1 END '
                'AS [primaryKey] '
                'FROM INFORMATION_SCHEMA.COLUMNS c '
                'LEFT JOIN ('
                ' SELECT ku.COLUMN_NAME '
                ' FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc '
                ' JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE ku '
                '   ON ku.CONSTRAINT_NAME = tc.CONSTRAINT_NAME '
                " WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY' "
                "  AND tc.TABLE_SCHEMA = '$s' AND tc.TABLE_NAME = '$t'"
                ') pk ON pk.COLUMN_NAME = c.COLUMN_NAME '
                "WHERE c.TABLE_SCHEMA = '$s' AND c.TABLE_NAME = '$t' "
                'ORDER BY c.ORDINAL_POSITION';
    case DbEngine.redis:
    case DbEngine.mongo:
      throw const DbQueryException(
        'unsupported_engine',
        'Schema introspection is SQL-only.',
      );
  }
}

/// Identificador seguro pra interpolar (tabela/schema): só
/// palavra/dígito/underscore/ponto/cifrão.
String _safeIdent(String name) {
  if (!RegExp(r'^[A-Za-z0-9_.$]+$').hasMatch(name)) {
    throw DbQueryException('query_failed', 'Invalid table name: "$name"');
  }
  return name;
}
