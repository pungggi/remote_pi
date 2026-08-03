import 'package:cockpit/app/core/domain/entities/lsp_diagnostic.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/code_editing_controller.dart';
import 'package:cockpit/app/core/ui/widgets/code_highlight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Roda [body] com um `BuildContext` sob o tema do app (o controller lê
/// `context.colors` pra montar o span).
Future<void> _withContext(
  WidgetTester tester,
  void Function(BuildContext context) body,
) async {
  await tester.pumpWidget(
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
}

void main() {
  const source = 'class Foo {\n  final int bar = 1;\n}\n';

  TextSpan build(CodeEditingController ctrl, BuildContext context) =>
      ctrl.buildTextSpan(context: context, style: null, withComposing: false);

  testWidgets('rebuild sem mudança devolve o MESMO span (memo)', (
    tester,
  ) async {
    final ctrl = CodeEditingController(text: source, language: 'dart');
    addTearDown(ctrl.dispose);

    late TextSpan a;
    late TextSpan b;
    await _withContext(tester, (context) {
      a = build(ctrl, context);
      // Segundo rebuild do EditableText sem nada ter mudado — é o que acontece
      // quando o editor faz setState por hover de linha, foco, etc.
      b = build(ctrl, context);
    });

    expect(identical(a, b), isTrue);
  });

  testWidgets('mudar diagnostics invalida o memo', (tester) async {
    final ctrl = CodeEditingController(text: source, language: 'dart');
    addTearDown(ctrl.dispose);

    late TextSpan a;
    late TextSpan b;
    await _withContext(tester, (context) {
      a = build(ctrl, context);
      ctrl.diagnostics = <LspDiagnostic>[
        const LspDiagnostic(
          range: LspRange(LspPosition(0, 6), LspPosition(0, 9)),
          severity: LspSeverity.error,
          message: 'boom',
        ),
      ];
      b = build(ctrl, context);
    });

    expect(identical(a, b), isFalse);
  });

  testWidgets('mudar semantic tokens invalida o memo', (tester) async {
    final ctrl = CodeEditingController(text: source, language: 'dart');
    addTearDown(ctrl.dispose);

    late TextSpan a;
    late TextSpan b;
    await _withContext(tester, (context) {
      a = build(ctrl, context);
      ctrl.semanticTokens = <SemanticRange>[SemanticRange(6, 9, 'class')];
      b = build(ctrl, context);
    });

    expect(identical(a, b), isFalse);
  });

  testWidgets('mudar o range sublinhado (hover Cmd) invalida o memo', (
    tester,
  ) async {
    final ctrl = CodeEditingController(text: source, language: 'dart');
    addTearDown(ctrl.dispose);

    late TextSpan a;
    late TextSpan b;
    late TextSpan c;
    await _withContext(tester, (context) {
      a = build(ctrl, context);
      ctrl.definitionHoverRange = (start: 6, end: 9);
      b = build(ctrl, context);
      // Mesmo range de novo → memo volta a valer.
      c = build(ctrl, context);
    });

    expect(identical(a, b), isFalse);
    expect(identical(b, c), isTrue);
  });

  testWidgets('editar o texto invalida o memo e repinta o conteúdo novo', (
    tester,
  ) async {
    final ctrl = CodeEditingController(text: source, language: 'dart');
    addTearDown(ctrl.dispose);

    String render(TextSpan span) {
      final buf = StringBuffer();
      span.visitChildren((v) {
        buf.write((v as TextSpan).text);
        return true;
      });
      return buf.toString();
    }

    late TextSpan a;
    late TextSpan b;
    await _withContext(tester, (context) {
      a = build(ctrl, context);
      ctrl.text = 'class Baz {}\n';
      b = build(ctrl, context);
    });

    expect(identical(a, b), isFalse);
    expect(render(a), source);
    expect(render(b), 'class Baz {}\n');
  });
}
