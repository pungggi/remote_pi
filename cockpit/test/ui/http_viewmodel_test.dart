import 'dart:typed_data';

import 'package:cockpit/app/cockpit/domain/contracts/http_request_runner.dart';
import 'package:cockpit/app/cockpit/domain/entities/http_document.dart';
import 'package:cockpit/app/cockpit/domain/entities/http_response_result.dart';
import 'package:cockpit/app/cockpit/domain/exceptions/http_request_error.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/http_viewmodel.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubRunner implements HttpRequestRunner {
  @override
  Future<Result<HttpResponseResult, HttpRequestError>> send(
    HttpRequestSpec spec, {
    required String baseDir,
    Duration timeout = const Duration(seconds: 30),
    bool followRedirects = true,
  }) async => Failure(const HttpRequestError(HttpRequestErrorKind.noRequest));
}

HttpResponseResult _result(String body, {String type = 'application/json'}) =>
    HttpResponseResult(
      statusCode: 200,
      reasonPhrase: 'OK',
      headers: [(name: 'content-type', value: type)],
      bodyBytes: Uint8List.fromList(body.codeUnits),
      elapsed: const Duration(milliseconds: 12),
      requestLabel: 'GET /x',
    );

void main() {
  test('side-car por tab sobrevive a re-mount e gira em LRU', () {
    final vm = HttpViewModel(_StubRunner());
    final a = vm.tabStateFor('tab-a');
    a.split = 0.3;
    // Mesmo id → mesmo estado (é o que salva o resultado ao mover a tab).
    expect(identical(vm.tabStateFor('tab-a'), a), isTrue);
    expect(vm.tabStateFor('tab-a').split, 0.3);
    expect(identical(vm.tabStateFor('tab-b'), a), isFalse);

    // Cap: a tab mais antiga sai do mapa, a recém-tocada fica.
    for (var i = 0; i < 30; i++) {
      vm.tabStateFor('tab-$i');
    }
    final fresh = vm.tabStateFor('tab-a');
    expect(fresh.split, 0.5, reason: 'tab-a saiu do cap e voltou zerada');
  });

  group('HttpResponseResult', () {
    test('JSON válido vira corpo indentado', () {
      expect(_result('{"a":1}').prettyJson, '{\n  "a": 1\n}');
    });

    test('Content-Type mentindo cai no texto cru', () {
      expect(_result('not json').prettyJson, isNull);
      expect(_result('not json').bodyText, 'not json');
    });

    test('toJson manda json decodificado quando dá, senão body', () {
      expect(_result('{"a":1}').toJson()['json'], {'a': 1});
      final plain = _result('hello', type: 'text/plain').toJson();
      expect(plain['body'], 'hello');
      expect(plain.containsKey('json'), isFalse);
      expect(plain['status'], 200);
      expect(plain['elapsedMs'], 12);
    });

    test('headerValue é case-insensitive', () {
      expect(_result('{}').headerValue('Content-Type'), 'application/json');
      expect(_result('{}').isJson, isTrue);
    });
  });
}
