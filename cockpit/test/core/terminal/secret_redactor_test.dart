import 'package:cockpit/app/core/terminal/secret_redactor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('substitui o valor inteiro num único chunk', () {
    final r = SecretRedactor(['sk-abc12345']);
    expect(r.feed('token=sk-abc12345 ok\n'), 'token=*** ok\n');
    expect(r.flush(), '');
  });

  test('segredo partido entre dois chunks é redigido', () {
    final r = SecretRedactor(['sk-abc12345']);
    final a = r.feed('token=sk-abc');
    final b = r.feed('12345 ok\n');
    expect(a + b, 'token=*** ok\n');
    expect(a, 'token=', reason: 'só a cauda que pode ser prefixo fica presa');
  });

  test('cauda que não é prefixo de segredo sai na hora', () {
    final r = SecretRedactor(['sk-abc12345']);
    expect(r.feed('hello world'), 'hello world');
    expect(r.flush(), '');
  });

  test('flush libera o que ficou preso quando o stream termina', () {
    final r = SecretRedactor(['sk-abc12345']);
    expect(r.feed('prompt sk-ab'), 'prompt ');
    expect(r.flush(), 'sk-ab');
  });

  test('vários segredos, o maior primeiro; curtos ficam de fora', () {
    final r = SecretRedactor(['abcdefgh', 'abcdefghij', 'dev', '1']);
    expect(
      r.feed('x abcdefghij y abcdefgh z dev 1\n'),
      'x *** y *** z dev 1\n',
    );
  });

  test('ocorrência repetida e colada', () {
    final r = SecretRedactor(['secret-value-1']);
    expect(r.feed('secret-value-1secret-value-1'), '******');
  });

  test('sem segredos é passthrough', () {
    final r = SecretRedactor(const []);
    expect(r.isEmpty, isTrue);
    expect(r.feed('sk-abc'), 'sk-abc');
  });

  test('não segura mais que o maior segredo menos um', () {
    final r = SecretRedactor(['abcdefgh']);
    // 'abcdefg' (7) é prefixo próprio: fica preso; o 8º caractere fecha.
    expect(r.feed('..abcdefg'), '..');
    expect(r.feed('h!'), '***!');
  });

  test('update troca os segredos com a aba viva (workspace remoto)', () {
    final r = SecretRedactor(const []);
    expect(r.feed('token=sk-abc12345\n'), 'token=sk-abc12345\n');
    r.update(['sk-abc12345']);
    expect(r.isEmpty, isFalse);
    expect(r.feed('token=sk-abc12345\n'), 'token=***\n');
  });
}
