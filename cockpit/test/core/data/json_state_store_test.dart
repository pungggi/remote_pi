import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/core/data/setup/json_state_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('json_store_test');
  });

  tearDown(() async {
    JsonStateStore.resetCacheForTesting();
    await tmp.delete(recursive: true);
  });

  File fileOf(String name) => File(p.join(tmp.path, '$name.json'));

  test('roundtrip: put/flush persiste e reabre com os mesmos dados', () async {
    final store = await JsonStateStore.open(tmp.path, 'box');
    await store.put('a', 1);
    await store.put('b', {'x': 'y'});
    await store.put('c', ['1', 2]);
    await store.flush();

    // Reabre do disco (limpa o cache de instâncias antes).
    JsonStateStore.resetCacheForTesting();
    final reopened = await JsonStateStore.open(tmp.path, 'box');
    expect(reopened.get('a'), 1);
    expect(reopened.get('b'), {'x': 'y'});
    expect(reopened.get('c'), ['1', 2]);
    expect(reopened.keys.toSet(), {'a', 'b', 'c'});
  });

  test('open é idempotente: mesma instância pro mesmo arquivo', () async {
    final s1 = await JsonStateStore.open(tmp.path, 'box');
    final s2 = await JsonStateStore.open(tmp.path, 'box');
    expect(identical(s1, s2), isTrue);
  });

  test('envelope no disco tem version + data e sem .tmp residual', () async {
    final store = await JsonStateStore.open(tmp.path, 'box');
    await store.put('k', 'v');
    await store.flush();

    final decoded = jsonDecode(await fileOf('box').readAsString()) as Map;
    expect(decoded['version'], 1);
    expect(decoded['data'], {'k': 'v'});
    expect(File('${fileOf('box').path}.tmp').existsSync(), isFalse);
  });

  test('debounce coalesce: rajada de puts vira uma escrita', () async {
    final store = await JsonStateStore.open(tmp.path, 'box');
    final f1 = store.put('a', 1);
    final f2 = store.put('b', 2);
    final f3 = store.putAll({'c': 3, 'd': 4});
    // Antes do debounce vencer, nada no disco.
    expect(fileOf('box').existsSync(), isFalse);
    await Future.wait([f1, f2, f3]);
    final decoded = jsonDecode(await fileOf('box').readAsString()) as Map;
    expect(decoded['data'], {'a': 1, 'b': 2, 'c': 3, 'd': 4});
  });

  test('delete remove e persiste', () async {
    final store = await JsonStateStore.open(tmp.path, 'box');
    await store.put('a', 1);
    await store.delete('a');
    await store.flush();
    expect(store.get('a'), isNull);
    final decoded = jsonDecode(await fileOf('box').readAsString()) as Map;
    expect(decoded['data'], isEmpty);
  });

  test('arquivo corrompido → começa vazio sem lançar', () async {
    await fileOf('box').writeAsString('{not json!!');
    final store = await JsonStateStore.open(tmp.path, 'box');
    expect(store.keys, isEmpty);
    // E segue utilizável: escreve por cima do corrompido.
    await store.put('a', 1);
    await store.flush();
    final decoded = jsonDecode(await fileOf('box').readAsString()) as Map;
    expect(decoded['data'], {'a': 1});
  });

  test('envelope inesperado (JSON válido, sem data) → vazio', () async {
    await fileOf('box').writeAsString('[1,2,3]');
    final store = await JsonStateStore.open(tmp.path, 'box');
    expect(store.keys, isEmpty);
  });

  test('arquivo ausente → vazio', () async {
    final store = await JsonStateStore.open(tmp.path, 'box');
    expect(store.keys, isEmpty);
    expect(store.get('nope'), isNull);
  });

  test('writeAtomic sobrescreve conteúdo anterior via rename', () async {
    final file = fileOf('atomic');
    await JsonStateStore.writeAtomic(file, 'primeiro');
    await JsonStateStore.writeAtomic(file, 'segundo');
    expect(await file.readAsString(), 'segundo');
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  test('flush sem pendências é no-op seguro', () async {
    final store = await JsonStateStore.open(tmp.path, 'box');
    await store.flush();
    await store.flush();
    expect(fileOf('box').existsSync(), isFalse);
  });

  test('flushAll descarrega todas as instâncias abertas', () async {
    final a = await JsonStateStore.open(tmp.path, 'a');
    final b = await JsonStateStore.open(tmp.path, 'b');
    unawaited(a.put('k', 1));
    unawaited(b.put('k', 2));
    await JsonStateStore.flushAll();
    expect(fileOf('a').existsSync(), isTrue);
    expect(fileOf('b').existsSync(), isTrue);
  });
}
