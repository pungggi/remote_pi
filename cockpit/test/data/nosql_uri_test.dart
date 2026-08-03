import 'package:cockpit/app/cockpit/data/db/nosql_command_runner.dart';
import 'package:cockpit/app/cockpit/domain/entities/db_connection.dart';
import 'package:flutter_test/flutter_test.dart';

/// O runner Mongo conecta pela **URI**, não por campos soltos — só assim
/// `mongodb+srv://` (Atlas), TLS e `authSource` sobrevivem. Antes disso, Atlas
/// nunca conectava e `?authSource=admin` autenticava contra o banco errado.
void main() {
  DbConnection mongo(String url) =>
      DbConnection.fromJson({'name': 'm', 'url': url});

  group('URI do Mongo', () {
    test('URL sem senha separada passa intacta (SRV preservado)', () {
      const url =
          'mongodb+srv://user:pass@cluster1.zqq0pbr.mongodb.net/'
          '?retryWrites=true&w=majority';
      expect(NoSqlRunnerImpl.mongoUriFor(mongo(url), null), url);
      // Senha do cofre não sobrescreve a que já está na URL.
      expect(NoSqlRunnerImpl.mongoUriFor(mongo(url), 'outra'), url);
    });

    test('senha do cofre é injetada no userinfo', () {
      final uri = NoSqlRunnerImpl.mongoUriFor(
        mongo('mongodb://appuser@db.internal:27017/appdb'),
        's3cr3t',
      );
      expect(uri, 'mongodb://appuser:s3cr3t@db.internal:27017/appdb');
    });

    test('senha com caracteres especiais é percent-encoded', () {
      final uri = NoSqlRunnerImpl.mongoUriFor(
        mongo('mongodb://appuser@db.internal:27017/appdb'),
        'p@ss:w/rd?#',
      );
      // Sem encode, o `@`/`:` quebrariam o parse da authority.
      expect(uri, contains('appuser:p%40ss%3Aw%2Frd%3F%23@'));
      expect(Uri.parse(uri).host, 'db.internal');
    });

    test('query params sobrevivem à injeção de senha', () {
      final uri = NoSqlRunnerImpl.mongoUriFor(
        mongo('mongodb://u@h:27017/db?authSource=admin&tls=true'),
        'x',
      );
      final params = Uri.parse(uri).queryParameters;
      expect(params['authSource'], 'admin');
      expect(params['tls'], 'true');
    });
  });

  group('banco alvo do Mongo', () {
    test('path da URL quando presente', () {
      expect(
        NoSqlRunnerImpl.mongoDatabaseFor(
          mongo('mongodb://u@h:27017/anaki_dev?authSource=admin'),
        ),
        'anaki_dev',
      );
    });

    test('URL de Atlas sem path cai no authSource', () {
      expect(
        NoSqlRunnerImpl.mongoDatabaseFor(
          mongo('mongodb+srv://u:p@c.mongodb.net/?authSource=admin'),
        ),
        'admin',
      );
    });

    test('sem path e sem authSource cai em admin', () {
      expect(
        NoSqlRunnerImpl.mongoDatabaseFor(
          mongo('mongodb+srv://u:p@c.mongodb.net/?retryWrites=true'),
        ),
        'admin',
      );
    });
  });

  group('TLS do Redis', () {
    test('rediss:// liga TLS; redis:// não', () {
      expect(
        DbConnection.fromJson({
          'name': 'r',
          'url': 'rediss://cache.acme.dev:6379/0',
        }).useTls,
        isTrue,
      );
      expect(
        DbConnection.fromJson({
          'name': 'r',
          'url': 'redis://cache.acme.dev:6379/0',
        }).useTls,
        isFalse,
      );
    });
  });
}
