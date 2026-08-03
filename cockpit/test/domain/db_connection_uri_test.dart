import 'package:cockpit/app/cockpit/domain/entities/db_connection.dart';
import 'package:flutter_test/flutter_test.dart';

/// O dialog de conexão de rede é **só connection string** — não há mais
/// formulário decomposto (host/port/db/user). A razão é que a `DbConnection`
/// guarda URL como forma canônica: qualquer formulário seria a camada com
/// perda, incapaz de expressar `mongodb+srv://`, múltiplos hosts ou params
/// proprietários de driver.
///
/// Estes testes fixam o que a entidade precisa garantir para esse desenho
/// funcionar: a URL colada sobrevive intacta e o engine sai do scheme.
DbConnection conn(String url, {bool savePassword = false}) =>
    DbConnection.fromJson({
      'name': 'c',
      'url': url,
      'savePassword': savePassword,
    });

void main() {
  group('a URL colada sobrevive intacta', () {
    test('Atlas SRV com params do cluster', () {
      const url =
          'mongodb+srv://user:pass@cluster1.zqq0pbr.mongodb.net/'
          '?retryWrites=true&w=majority&appName=Cluster1';
      expect(conn(url).url, url);
      expect(conn(url).isSrv, isTrue);
    });

    test('params proprietários de driver', () {
      const url =
          'mongodb://u:p@h:27017/db'
          '?authSource=admin&directConnection=true&tls=true';
      expect(conn(url).url, url);
    });

    test('postgres com opções que nenhum formulário expunha', () {
      const url =
          'postgres://u@h:5432/db?sslmode=verify-full&application_name=cockpit';
      expect(conn(url).url, url);
      expect(conn(url).useTls, isTrue);
    });

    test('URL sem porta explícita não ganha porta na volta', () {
      const url = 'postgres://u@db.acme.dev/app';
      expect(conn(url).url, url);
      // `port` ainda responde o default do engine para quem precisa exibir.
      expect(conn(url).port, 5432);
    });
  });

  group('engine vem do scheme colado, não do popup do "+"', () {
    test('schemes conhecidos', () {
      expect(conn('mysql://u@h:3306/db').engine, DbEngine.mysql);
      expect(conn('mongodb+srv://u:p@c.net/').engine, DbEngine.mongo);
      expect(conn('rediss://h:6379/0').engine, DbEngine.redis);
      expect(conn('mssql://u@h:1433/db').engine, DbEngine.mssql);
    });

    test('scheme desconhecido é recusado (não vira conexão quebrada)', () {
      expect(
        () => conn('oracle://u@h:1521/db'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('senha', () {
    test('embutida na URL é recuperável para o driver', () {
      expect(conn('postgres://u:s3cr3t@h:5432/db').urlPassword, 's3cr3t');
    });

    test('URL sem senha devolve null (o valor vem do cofre)', () {
      expect(
        conn('postgres://u@h:5432/db', savePassword: true).urlPassword,
        isNull,
      );
    });

    test('user nunca carrega o trecho de senha junto', () {
      expect(conn('postgres://u:s3cr3t@h:5432/db').user, 'u');
    });
  });
}
