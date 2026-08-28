import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/code_editing_controller.dart';
import 'package:cockpit/app/core/ui/widgets/code_highlight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Gera Dart acima do teto de 32KB que liga o caminho aproximado.
String bigDart() {
  final b = StringBuffer();
  for (var i = 0; b.length < 40 * 1024; i++) {
    b.writeln('class Sample$i {');
    b.writeln('  final String label$i = "valor $i";');
    b.writeln('  int compute$i() => $i * 2;');
    b.writeln('}');
  }
  return b.toString();
}

String render(TextSpan span) {
  final buf = StringBuffer();
  span.visitChildren((v) {
    buf.write((v as TextSpan).text);
    return true;
  });
  return buf.toString();
}

void main() {
  setUp(clearCodeHighlightCache);

  testWidgets('digitar em arquivo grande não re-tokeniza; exato vem no idle', (
    tester,
  ) async {
    final source = bigDart();
    final ctrl = CodeEditingController(text: source, language: 'dart');
    addTearDown(ctrl.dispose);

    late BuildContext ctx;
    await tester.pumpWidget(
      ShadcnApp(
        theme: buildTheme(brightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );

    TextSpan build() =>
        ctrl.buildTextSpan(context: ctx, style: null, withComposing: false);

    // 1º build: parse exato (nada pra reusar ainda).
    build();
    expect(codeHighlightParseCount, 1);

    // Rajada de digitação: 5 teclas, cada uma com texto novo.
    for (var k = 1; k <= 5; k++) {
      ctrl.text = source.replaceFirst(
        'class Sample0',
        'class Sample0${'x' * k}',
      );
      final span = build();
      // Cobertura tem que continuar exata mesmo no caminho aproximado.
      expect(render(span), ctrl.text, reason: 'cobertura quebrou na tecla $k');
    }
    // Nenhum parse novo durante a rajada.
    expect(codeHighlightParseCount, 1);

    // Passa o debounce → o controller notifica e o próximo build sai exato.
    await tester.pump(const Duration(milliseconds: 200));
    final span = build();
    expect(codeHighlightParseCount, 2);
    expect(render(span), ctrl.text);
  });

  testWidgets('arquivo pequeno sempre parseia exato (sem aproximar)', (
    tester,
  ) async {
    const source = 'class Foo {\n  final int bar = 1;\n}\n';
    final ctrl = CodeEditingController(text: source, language: 'dart');
    addTearDown(ctrl.dispose);

    late BuildContext ctx;
    await tester.pumpWidget(
      ShadcnApp(
        theme: buildTheme(brightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );

    ctrl.buildTextSpan(context: ctx, style: null, withComposing: false);
    expect(codeHighlightParseCount, 1);

    ctrl.text = 'class Foo {\n  final int barbaz = 1;\n}\n';
    ctrl.buildTextSpan(context: ctx, style: null, withComposing: false);
    // Abaixo do teto → parse exato na hora, sem aproximação.
    expect(codeHighlightParseCount, 2);
  });

  // A queixa: digitar mudava a cor de outras letras. Causa — os semantic tokens
  // do batch anterior ficavam com offsets defasados e pintavam nas letras
  // erradas até o batch novo chegar (400ms). Vale pra QUALQUER tamanho de
  // arquivo (o remendo léxico só entra acima de 32KB, então não cobria isso).
  group('semantic tokens acompanham a edição', () {
    /// Cor por caractere — é o que o usuário vê.
    List<Color?> colorPerChar(TextSpan span) {
      final out = <Color?>[];
      span.visitChildren((v) {
        final s = v as TextSpan;
        for (var i = 0; i < (s.text?.length ?? 0); i++) {
          out.add(s.style?.color);
        }
        return true;
      });
      return out;
    }

    testWidgets('inserir antes de um token desloca o token, não a cor', (
      tester,
    ) async {
      // `bar` em `final int bar = 1;` começa no offset 10.
      const source = 'final int bar = 1;\n';
      final ctrl = CodeEditingController(text: source, language: 'dart');
      addTearDown(ctrl.dispose);
      ctrl.semanticTokens = <SemanticRange>[SemanticRange(10, 13, 'variable')];

      late BuildContext ctx;
      await tester.pumpWidget(
        ShadcnApp(
          theme: buildTheme(brightness: Brightness.dark),
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      );

      final before = colorPerChar(
        ctrl.buildTextSpan(context: ctx, style: null, withComposing: false),
      );
      final tokenColor = before[10];
      expect(tokenColor, isNotNull, reason: 'token deveria ter cor');

      // Digita 2 chars ANTES do token: ele deve andar 2 posições.
      ctrl.text = 'final intXY bar = 1;\n';
      final after = colorPerChar(
        ctrl.buildTextSpan(context: ctx, style: null, withComposing: false),
      );

      // `bar` agora começa em 12 e continua com a cor do token semântico.
      expect(after[12], tokenColor);
      expect(after[13], tokenColor);
      expect(after[14], tokenColor);
      // E o que ficou onde o token estava antes NÃO herdou a cor dele.
      expect(after[10], isNot(tokenColor));
    });

    testWidgets('remover desloca de volta', (tester) async {
      const source = 'final intXY bar = 1;\n';
      final ctrl = CodeEditingController(text: source, language: 'dart');
      addTearDown(ctrl.dispose);
      ctrl.semanticTokens = <SemanticRange>[SemanticRange(12, 15, 'variable')];

      late BuildContext ctx;
      await tester.pumpWidget(
        ShadcnApp(
          theme: buildTheme(brightness: Brightness.dark),
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      );
      ctrl.buildTextSpan(context: ctx, style: null, withComposing: false);

      ctrl.text = 'final int bar = 1;\n'; // apaga "XY"
      expect(ctrl.semanticTokens.single.start, 10);
      expect(ctrl.semanticTokens.single.end, 13);
    });

    testWidgets('token que cruza a edição é descartado', (tester) async {
      const source = 'final int bar = 1;\n';
      final ctrl = CodeEditingController(text: source, language: 'dart');
      addTearDown(ctrl.dispose);
      // Token cobre `bar` [10,13); a edição cai DENTRO dele.
      ctrl.semanticTokens = <SemanticRange>[SemanticRange(10, 13, 'variable')];

      ctrl.text = 'final int bXYar = 1;\n';
      // Não sabemos o que `bXYar` virou → descarta e espera o batch novo.
      expect(ctrl.semanticTokens, isEmpty);
    });

    testWidgets('tokens depois de inserir linha acompanham', (tester) async {
      const source = 'final int a = 1;\nfinal int b = 2;\n';
      final ctrl = CodeEditingController(text: source, language: 'dart');
      addTearDown(ctrl.dispose);
      // Token no `b` da 2ª linha (offset 27).
      expect(source.substring(27, 28), 'b');
      ctrl.semanticTokens = <SemanticRange>[SemanticRange(27, 28, 'variable')];

      // Insere uma linha inteira no começo.
      ctrl.text = '// nota\n$source';
      expect(ctrl.semanticTokens.single.start, 27 + '// nota\n'.length);
    });

    testWidgets('hover de go-to-definition é limpo na edição', (tester) async {
      final ctrl = CodeEditingController(
        text: 'final int bar = 1;\n',
        language: 'dart',
      );
      addTearDown(ctrl.dispose);
      ctrl.definitionHoverRange = (start: 10, end: 13);
      expect(ctrl.definitionHoverRange, isNotNull);

      ctrl.text = 'final int barX = 1;\n';
      // Offsets mudaram → o sublinhado antigo não vale mais.
      expect(ctrl.definitionHoverRange, isNull);
    });
  });

  testWidgets('dispose com timer pendente não estoura', (tester) async {
    final source = bigDart();
    final ctrl = CodeEditingController(text: source, language: 'dart');

    late BuildContext ctx;
    await tester.pumpWidget(
      ShadcnApp(
        theme: buildTheme(brightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );

    ctrl.buildTextSpan(context: ctx, style: null, withComposing: false);
    ctrl.text = source.replaceFirst('class Sample0', 'class Sample0x');
    ctrl.buildTextSpan(context: ctx, style: null, withComposing: false);

    // Descarta ANTES do timer estourar — não pode notificar depois do dispose.
    ctrl.dispose();
    await tester.pump(const Duration(milliseconds: 300));
    // Se o timer tivesse notificado após dispose, o test falharia aqui.
  });
}
