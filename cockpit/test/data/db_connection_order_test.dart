import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/data/db/db_connection_store_impl.dart';
import 'package:cockpit/app/cockpit/domain/entities/db_connection.dart';
import 'package:flutter_test/flutter_test.dart';

/// Salvar uma conexão fazia ela pular de lugar: a gravação anexava a editada no
/// fim do `databases.json` e a leitura respeitava a ordem do arquivo. A lista
/// passa a ser sempre alfabética, na tela E no arquivo (que é versionado).
void main() {
  late Directory dir;
  const store = DbConnectionStoreImpl();

  setUp(() => dir = Directory.systemTemp.createTempSync('cockpit-db-order'));
  tearDown(() => dir.deleteSync(recursive: true));

  DbConnection conn(String name) =>
      DbConnection(name: name, engine: DbEngine.postgres, url: 'postgres://x');

  test('carrega em ordem alfabética, não na ordem do arquivo', () async {
    await store.save(dir.path, [conn('zebra'), conn('alfa'), conn('meio')]);

    final loaded = await store.load(dir.path);

    expect(loaded.map((c) => c.name), ['alfa', 'meio', 'zebra']);
  });

  test('editar uma conexão não move as outras de lugar', () async {
    await store.save(dir.path, [conn('alfa'), conn('meio'), conn('zebra')]);
    final antes = (await store.load(dir.path)).map((c) => c.name).toList();

    // O que o upsert faz: reescreve tudo com a editada no fim da lista.
    final editada = DbConnection(
      name: 'meio',
      engine: DbEngine.mysql,
      url: 'mysql://y',
    );
    await store.save(dir.path, [conn('alfa'), conn('zebra'), editada]);

    final depois = await store.load(dir.path);
    expect(depois.map((c) => c.name), antes);
    expect(depois.firstWhere((c) => c.name == 'meio').engine, DbEngine.mysql);
  });

  test('o arquivo versionado também sai ordenado', () async {
    await store.save(dir.path, [conn('zebra'), conn('alfa')]);

    final json = jsonDecode(
      File('${dir.path}/.cockpit/databases.json').readAsStringSync(),
    );
    final nomes = [for (final e in json['databases'] as List) e['name']];
    // Sem isto, cada salvamento produzia um diff de reordenação no git.
    expect(nomes, ['alfa', 'zebra']);
  });

  test('nomes que só diferem na caixa têm ordem determinística', () {
    final lista = [conn('Beta'), conn('alfa'), conn('beta')]
      ..sort(DbConnection.compareByName);

    expect(lista.map((c) => c.name), ['alfa', 'Beta', 'beta']);
  });
}
