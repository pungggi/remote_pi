import 'package:cockpit/app/cockpit/data/db/nosql_command_runner.dart';
import 'package:cockpit/app/cockpit/domain/entities/db_connection.dart';
import 'package:cockpit/app/cockpit/domain/entities/db_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guarda a dependência que faz o Mongo atrás de bastion existir (plano 54).
///
/// O caminho Mongo+SSH manda o driver por um proxy SOCKS5 (`proxyHost`/
/// `proxyPort`), e essas opções só existem no crate `mongodb` quando ele é
/// compilado com a feature `socks5-proxy` — habilitada no `anaki_mongodb`
/// 0.1.5. Se alguém voltar a dependência, o driver passa a **recusar a opção**
/// e Atlas/replica set param de funcionar por túnel.
///
/// O teste conecta contra um proxy inexistente de propósito: o que importa não
/// é conectar, é **qual** erro volta. "connecting to a proxy host" prova que a
/// opção foi consumida; "socks5-proxy feature is not enabled" denuncia a
/// regressão.
void main() {
  test(
    'a dylib do anaki_mongodb tem suporte a SOCKS5',
    () async {
      final conn = DbConnection.fromJson({
        'name': 'proxy-check',
        // Porta 1 do loopback: garantidamente fechada.
        'url':
            'mongodb://u:p@db.invalid:27017/db'
            '?proxyHost=127.0.0.1&proxyPort=1&serverSelectionTimeoutMS=2000',
      });

      await expectLater(
        const NoSqlRunnerImpl().mongo(conn, const {'ping': 1}),
        throwsA(
          isA<DbQueryException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('proxy host'),
              isNot(contains('socks5-proxy feature is not enabled')),
            ),
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
