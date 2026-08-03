import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/code_highlight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Reconstrói o texto a partir dos spans — é a invariante que não pode quebrar:
/// se o span não cobrir o texto exatamente, o campo corrompe (cursor, seleção e
/// hit-test saem de lugar).
String render(TextSpan? span) {
  final buf = StringBuffer();
  span?.visitChildren((v) {
    buf.write((v as TextSpan).text);
    return true;
  });
  return buf.toString();
}

/// Cor do primeiro span cujo texto contém [needle].
Color? colorOf(TextSpan? span, String needle) {
  Color? found;
  span?.visitChildren((v) {
    final s = v as TextSpan;
    if (found == null && (s.text?.contains(needle) ?? false)) {
      found = s.style?.color;
    }
    return true;
  });
  return found;
}

/// Roda `body` com um BuildContext sob o tema.
Future<void> withCtx(
  WidgetTester tester,
  void Function(BuildContext context) body,
) => tester.pumpWidget(
  ShadcnApp(
    theme: buildTheme(brightness: Brightness.dark),
    home: Builder(
      builder: (context) {
        body(context);
        return const SizedBox();
      },
    ),
  ),
);

void main() {
  setUp(clearCodeHighlightCache);

  const base =
      'class Foo {\n'
      '  final int bar = 1;\n'
      '  String greet() => "hello";\n'
      '}\n';

  /// Primeiro faz o parse exato (popula o LRU), depois aproxima [edited].
  Future<TextSpan?> approxAfterExact(
    WidgetTester tester,
    String previous,
    String edited, {
    List<SemanticRange> semanticTokens = const <SemanticRange>[],
  }) async {
    TextSpan? out;
    await withCtx(tester, (context) {
      buildCodeSpan(
        context,
        source: previous,
        language: 'dart',
        baseStyle: const TextStyle(),
      );
      out = buildApproximateCodeSpan(
        context,
        source: edited,
        previousSource: previous,
        language: 'dart',
        baseStyle: const TextStyle(),
        semanticTokens: semanticTokens,
      );
    });
    return out;
  }

  group('cobertura exata do texto', () {
    test('sanidade: os casos cobrem inserção, remoção e substituição', () {
      expect(base.contains('bar'), isTrue);
    });

    testWidgets('inserir no meio', (tester) async {
      final edited = base.replaceFirst('bar', 'barbaz');
      final span = await approxAfterExact(tester, base, edited);
      expect(span, isNotNull);
      expect(render(span), edited);
    });

    testWidgets('remover no meio', (tester) async {
      final edited = base.replaceFirst('  final int bar = 1;\n', '');
      final span = await approxAfterExact(tester, base, edited);
      expect(span, isNotNull);
      expect(render(span), edited);
    });

    testWidgets('inserir no começo', (tester) async {
      final edited = '// topo\n$base';
      final span = await approxAfterExact(tester, base, edited);
      expect(span, isNotNull);
      expect(render(span), edited);
    });

    testWidgets('inserir no fim', (tester) async {
      final edited = '$base// rodapé\n';
      final span = await approxAfterExact(tester, base, edited);
      expect(span, isNotNull);
      expect(render(span), edited);
    });

    testWidgets('digitar caractere por caractere mantém cobertura', (
      tester,
    ) async {
      // Simula a rajada: cada tecla aproxima a partir do MESMO texto exato.
      var typed = '';
      for (final ch in 'novaLinha'.split('')) {
        typed += ch;
        final edited = base.replaceFirst('bar', 'bar$typed');
        final span = await approxAfterExact(tester, base, edited);
        expect(span, isNotNull, reason: 'falhou em "$typed"');
        expect(render(span), edited, reason: 'cobertura quebrou em "$typed"');
      }
    });

    testWidgets('texto que virou vazio', (tester) async {
      final span = await approxAfterExact(tester, base, '');
      expect(span, isNotNull);
      expect(render(span), '');
    });

    testWidgets('cobertura se mantém com overlays por cima', (tester) async {
      final edited = base.replaceFirst('bar', 'barbaz');
      final span = await approxAfterExact(
        tester,
        base,
        edited,
        semanticTokens: <SemanticRange>[
          SemanticRange(6, 9, 'class'),
          SemanticRange(20, 26, 'variable'),
        ],
      );
      expect(span, isNotNull);
      expect(render(span), edited);
    });
  });

  group('não aproxima quando não deve', () {
    testWidgets('sem parse anterior no cache → null (chamador faz o exato)', (
      tester,
    ) async {
      TextSpan? span;
      await withCtx(tester, (context) {
        // Nada foi parseado antes: `previousSource` não está no LRU.
        span = buildApproximateCodeSpan(
          context,
          source: 'class Bar {}\n',
          previousSource: base,
          language: 'dart',
          baseStyle: const TextStyle(),
        );
      });
      expect(span, isNull);
    });

    testWidgets('edição maior que o teto → null', (tester) async {
      // Cola 4KB de uma vez (teto é 2KB).
      final edited = base.replaceFirst('bar', 'x' * 4096);
      final span = await approxAfterExact(tester, base, edited);
      expect(span, isNull);
    });
  });

  testWidgets('aproximar NÃO roda o tokenizer', (tester) async {
    final edited = base.replaceFirst('bar', 'barbaz');
    await approxAfterExact(tester, base, edited);
    // 1 parse (o exato inicial) e nenhum a mais pro remendo.
    expect(codeHighlightParseCount, 1);
  });

  // Anti-flicker: o meio remendado herda o estilo do token editado. Sem isso
  // cada tecla apagava a cor e ela voltava 120ms depois — pisca-pisca visível.
  group('região editada herda a cor do token', () {
    testWidgets('digitar dentro de string mantém a cor de string', (
      tester,
    ) async {
      // Cor de referência: como "hello" é pintado no parse exato.
      Color? stringColor;
      await withCtx(tester, (context) {
        stringColor = colorOf(
          buildCodeSpan(
            context,
            source: base,
            language: 'dart',
            baseStyle: const TextStyle(),
          ),
          'hello',
        );
      });
      expect(stringColor, isNotNull, reason: 'string deveria ter cor');

      // Digita dentro da string → os chars novos herdam a cor de string.
      final edited = base.replaceFirst('hello', 'helloXY');
      final span = await approxAfterExact(tester, base, edited);
      expect(colorOf(span, 'XY'), stringColor);
    });

    testWidgets('digitar dentro de identificador mantém a cor dele', (
      tester,
    ) async {
      Color? classColor;
      await withCtx(tester, (context) {
        classColor = colorOf(
          buildCodeSpan(
            context,
            source: base,
            language: 'dart',
            baseStyle: const TextStyle(),
          ),
          'Foo',
        );
      });

      final edited = base.replaceFirst('Foo', 'FooBar');
      final span = await approxAfterExact(tester, base, edited);
      expect(colorOf(span, 'Bar'), classColor);
    });

    testWidgets('região editada nunca sai sem estilo quando havia estilo', (
      tester,
    ) async {
      // Regressão do comportamento antigo: o meio vinha com style null.
      final edited = base.replaceFirst('hello', 'helloZZ');
      final span = await approxAfterExact(tester, base, edited);
      expect(colorOf(span, 'ZZ'), isNotNull);
    });
  });

  // A queixa real: digitar mudava a cor de OUTRAS letras. A versão antiga
  // descartava as folhas que cruzavam a fronteira da edição e fundia tudo num
  // estilo só, então o texto vizinho perdia a cor própria até o parse exato.
  group('nenhuma letra fora da edição troca de cor', () {
    /// Mapa offset→cor, caractere por caractere.
    List<Color?> colorPerChar(TextSpan? span) {
      final out = <Color?>[];
      span?.visitChildren((v) {
        final s = v as TextSpan;
        final color = s.style?.color;
        for (var i = 0; i < (s.text?.length ?? 0); i++) {
          out.add(color);
        }
        return true;
      });
      return out;
    }

    /// Compara a cor de cada caractere fora da região editada entre o parse
    /// EXATO do texto novo e a APROXIMAÇÃO. Devem bater — se não batem, alguma
    /// letra que o usuário não tocou mudou de cor.
    Future<void> assertOutsideUnchanged(
      WidgetTester tester, {
      required String from,
      required String to,
    }) async {
      List<Color?>? approx;
      List<Color?>? exact;
      await withCtx(tester, (context) {
        buildCodeSpan(
          context,
          source: from,
          language: 'dart',
          baseStyle: const TextStyle(),
        );
        approx = colorPerChar(
          buildApproximateCodeSpan(
            context,
            source: to,
            previousSource: from,
            language: 'dart',
            baseStyle: const TextStyle(),
          ),
        );
        exact = colorPerChar(
          buildCodeSpan(
            context,
            source: to,
            language: 'dart',
            baseStyle: const TextStyle(),
          ),
        );
      });

      expect(approx, isNotNull);
      expect(approx!.length, to.length, reason: 'cobertura por caractere');
      expect(exact!.length, to.length);

      // Região editada: entre o prefixo e o sufixo comuns.
      var p = 0;
      final maxP = from.length < to.length ? from.length : to.length;
      while (p < maxP && from.codeUnitAt(p) == to.codeUnitAt(p)) {
        p++;
      }
      var s = 0;
      while (s < maxP - p &&
          from.codeUnitAt(from.length - 1 - s) ==
              to.codeUnitAt(to.length - 1 - s)) {
        s++;
      }
      final editEnd = to.length - s;

      for (var i = 0; i < to.length; i++) {
        if (i >= p && i < editEnd) continue; // dentro da edição: pode diferir
        expect(
          approx![i],
          exact![i],
          reason:
              'char $i ("${to[i]}") fora da edição mudou de cor '
              '(aprox=${approx![i]} exato=${exact![i]})',
        );
      }
    }

    testWidgets('digitar no meio de um identificador', (tester) async {
      await assertOutsideUnchanged(
        tester,
        from: base,
        to: base.replaceFirst('bar', 'barX'),
      );
    });

    testWidgets('digitar dentro de string', (tester) async {
      await assertOutsideUnchanged(
        tester,
        from: base,
        to: base.replaceFirst('hello', 'helloX'),
      );
    });

    testWidgets('digitar dentro de comentário', (tester) async {
      const withComment = '// nota\nclass Foo {}\n';
      await assertOutsideUnchanged(
        tester,
        from: withComment,
        to: withComment.replaceFirst('nota', 'notaX'),
      );
    });

    testWidgets('apagar caracteres', (tester) async {
      await assertOutsideUnchanged(
        tester,
        from: base,
        to: base.replaceFirst('greet', 'gret'),
      );
    });

    testWidgets('rajada: 6 teclas seguidas a partir do mesmo parse', (
      tester,
    ) async {
      for (var k = 1; k <= 6; k++) {
        await assertOutsideUnchanged(
          tester,
          from: base,
          to: base.replaceFirst('bar', 'bar${'y' * k}'),
        );
      }
    });

    testWidgets(
      'LIMITAÇÃO conhecida: edição que muda a tokenização vizinha só acerta '
      'no parse exato',
      (tester) async {
        // Inserir `X` antes de `int` faz `Xint` — deixa de ser a keyword. Nenhuma
        // aproximação sabe disso sem re-tokenizar; o parse exato (120ms) corrige.
        // Documentado como teste pra ficar explícito que é limite do desenho, não
        // regressão: se um dia virar exato, este teste avisa.
        const src = 'final int bar = 1;\n';
        final edited = src.replaceFirst('int', 'Xint');

        Color? approxColor;
        Color? exactColor;
        await withCtx(tester, (context) {
          buildCodeSpan(
            context,
            source: src,
            language: 'dart',
            baseStyle: const TextStyle(),
          );
          approxColor = colorOf(
            buildApproximateCodeSpan(
              context,
              source: edited,
              previousSource: src,
              language: 'dart',
              baseStyle: const TextStyle(),
            ),
            'int',
          );
          exactColor = colorOf(
            buildCodeSpan(
              context,
              source: edited,
              language: 'dart',
              baseStyle: const TextStyle(),
            ),
            'Xint',
          );
        });

        // A aproximação mantém a cor antiga de keyword; o exato já não colore.
        expect(approxColor, isNotNull);
        expect(exactColor, isNull);
      },
    );
  });
}
