import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/code_highlight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Monta `buildCodeSpan` [times] vezes na mesma árvore e devolve o último span.
/// Cada rebuild simula um repaint do campo (o que acontece a cada tecla, cada
/// batch de diagnostics e cada hover do go-to-definition).
Future<TextSpan?> _buildTimes(
  WidgetTester tester, {
  required String source,
  required String? language,
  required int times,
  List<SemanticRange> Function(int i)? semanticTokens,
  ({int start, int end})? Function(int i)? underlineRange,
}) async {
  TextSpan? span;
  var i = 0;
  await tester.pumpWidget(
    ShadcnApp(
      theme: buildTheme(brightness: Brightness.dark),
      home: StatefulBuilder(
        builder: (context, setState) {
          span = buildCodeSpan(
            context,
            source: source,
            language: language,
            baseStyle: const TextStyle(),
            semanticTokens: semanticTokens?.call(i) ?? const <SemanticRange>[],
            underlineRange: underlineRange?.call(i),
            underlineColor: const Color(0xFF00FF00),
          );
          if (i + 1 < times) {
            i++;
            // Reagenda um rebuild — repaint sem o texto ter mudado.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => setState(() {}),
            );
          }
          return const SizedBox();
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return span;
}

void main() {
  setUp(clearCodeHighlightCache);

  testWidgets('repaint sem mudar o texto NÃO re-parseia (cache hit)', (
    tester,
  ) async {
    const source = 'class Foo {\n  final int bar = 1;\n}\n';

    await _buildTimes(tester, source: source, language: 'dart', times: 5);

    // 5 repaints, 1 parse só.
    expect(codeHighlightParseCount, 1);
  });

  testWidgets('hover do go-to-definition não re-parseia a cada identifier', (
    tester,
  ) async {
    const source = 'class Foo {\n  final int bar = 1;\n}\n';

    // Cada rebuild muda o range sublinhado — é o que o mouse faz ao passar de
    // um identifier pro outro com Cmd/Ctrl segurado. O texto não muda, então o
    // parse léxico deve ser reaproveitado.
    await _buildTimes(
      tester,
      source: source,
      language: 'dart',
      times: 4,
      underlineRange: (i) => (start: i * 3, end: i * 3 + 3),
    );

    expect(codeHighlightParseCount, 1);
  });

  testWidgets('chegada de semantic tokens não re-parseia', (tester) async {
    const source = 'class Foo {\n  final int bar = 1;\n}\n';

    await _buildTimes(
      tester,
      source: source,
      language: 'dart',
      times: 3,
      // Simula o batch do LSP chegando depois do 1º frame.
      semanticTokens: (i) => i == 0
          ? const <SemanticRange>[]
          : <SemanticRange>[SemanticRange(6, 9, 'class')],
    );

    expect(codeHighlightParseCount, 1);
  });

  testWidgets(
    'texto diferente re-parseia (cache não devolve resultado velho)',
    (tester) async {
      await _buildTimes(
        tester,
        source: 'class Foo {}\n',
        language: 'dart',
        times: 1,
      );
      expect(codeHighlightParseCount, 1);

      await _buildTimes(
        tester,
        source: 'class Bar {}\n',
        language: 'dart',
        times: 1,
      );
      expect(codeHighlightParseCount, 2);
    },
  );

  testWidgets('cache preserva o conteúdo pintado (hit == miss)', (
    tester,
  ) async {
    const source = 'class Foo {\n  final int bar = 1;\n}\n';

    String render(TextSpan? span) {
      final buf = StringBuffer();
      span?.visitChildren((v) {
        buf.write((v as TextSpan).text);
        return true;
      });
      return buf.toString();
    }

    final first = await _buildTimes(
      tester,
      source: source,
      language: 'dart',
      times: 1,
    );
    final firstText = render(first);
    expect(codeHighlightParseCount, 1);

    // Segunda montagem: mesma String → cache hit, mesmo resultado.
    final second = await _buildTimes(
      tester,
      source: source,
      language: 'dart',
      times: 1,
    );
    expect(codeHighlightParseCount, 1); // não re-parseou
    expect(render(second), firstText); // e pintou igual
    expect(firstText, source); // sem perder nem duplicar texto
  });

  testWidgets('LRU expulsa a entrada mais antiga, mantém a mais recente', (
    tester,
  ) async {
    // Guarda as MESMAS instâncias de String — o cache chaveia por identidade
    // (`identical`), então re-passar um literal equivalente porém de outra
    // instância seria miss (correto por design: miss nunca erra, só re-parseia).
    final sources = <String>[for (var i = 0; i < 7; i++) 'class C$i {}\n'];

    // Cache tem 6 slots; 7 fontes distintas → a 1ª (sources[0]) é expulsa.
    for (final s in sources) {
      await _buildTimes(tester, source: s, language: 'dart', times: 1);
    }
    expect(codeHighlightParseCount, 7);

    // A mais recente segue no cache → hit, sem parse novo.
    await _buildTimes(tester, source: sources.last, language: 'dart', times: 1);
    expect(codeHighlightParseCount, 7);

    // A mais antiga foi expulsa → miss, re-parseia.
    await _buildTimes(
      tester,
      source: sources.first,
      language: 'dart',
      times: 1,
    );
    expect(codeHighlightParseCount, 8);
  });

  testWidgets('cache chaveia por identidade: String equivalente mas nova dá miss', (
    tester,
  ) async {
    // Documenta o trade-off explícito do design: comparar 200KB de texto por
    // repaint custaria caro, então a chave é `identical`. Na prática o texto vem
    // sempre da mesma instância (o buffer do controller) enquanto não é editado,
    // e um miss só re-parseia — nunca devolve resultado errado.
    const a = 'class Foo {}\n';
    // Instância NOVA de verdade: literais iguais são canonicalizados,
    // `substring(0)` devolve `this` e `StringBuffer` com um único write
    // devolve o próprio chunk — só reconstruindo os code units escapa disso.
    final b = String.fromCharCodes(a.codeUnits);

    await _buildTimes(tester, source: a, language: 'dart', times: 1);
    expect(codeHighlightParseCount, 1);

    await _buildTimes(tester, source: b, language: 'dart', times: 1);
    expect(identical(a, b), isFalse);
    expect(codeHighlightParseCount, 2); // miss por identidade
  });
}
