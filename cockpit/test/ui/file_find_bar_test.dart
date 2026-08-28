import 'package:cockpit/app/cockpit/ui/widgets/file_find_bar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeFileMatches', () {
    const text = 'foo Foo FOO\nbar foobar foo';

    test('query vazia → sem matches', () {
      expect(computeFileMatches(text, '').matches, isEmpty);
    });

    test('literal case-insensitive por padrão', () {
      final r = computeFileMatches(text, 'foo');
      // foo, Foo, FOO, foobar(foo), foo = 5 ocorrências
      expect(r.matches.length, 5);
      expect(r.invalidRegex, isFalse);
      // Primeiro match cobre "foo" inicial [0,3).
      expect(r.matches.first.start, 0);
      expect(r.matches.first.end, 3);
    });

    test('case-sensitive respeita caixa', () {
      final r = computeFileMatches(text, 'foo', caseSensitive: true);
      // "foo" (0), "foo" dentro de foobar, "foo" final = 3
      expect(r.matches.length, 3);
    });

    test('whole word não casa substring', () {
      final r = computeFileMatches(text, 'foo', wholeWord: true);
      // exclui o "foo" de "foobar" → foo, Foo, FOO, foo = 4
      expect(r.matches.length, 4);
    });

    test('regex válida casa grupos', () {
      final r = computeFileMatches(
        text,
        r'F\w+',
        regex: true,
        caseSensitive: true,
      );
      // "Foo" e "FOO"
      expect(r.matches.length, 2);
    });

    test('regex inválida sinaliza sem lançar', () {
      final r = computeFileMatches(text, '(', regex: true);
      expect(r.invalidRegex, isTrue);
      expect(r.matches, isEmpty);
    });

    test('ignora matches de largura zero', () {
      final r = computeFileMatches('aaa', 'a*', regex: true);
      expect(r.matches, isNotEmpty);
      expect(r.matches.every((m) => m.end > m.start), isTrue);
    });
  });
}
