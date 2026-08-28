import 'package:cockpit/app/cockpit/ui/widgets/agent_markdown.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/custom_widgets/selectable_adapter.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// O `gpt_markdown` desreferencia `DefaultSelectionStyle.of(context)
/// .selectionColor!` ao montar (`_SelectableAdapter.createRenderObject`), e o
/// fallback do Flutter traz NULO. Como o Cockpit roda em `ShadcnApp`, e não em
/// `MaterialApp`, ninguém preenchia essa cor: montar o markdown derrubava a
/// árvore inteira.
///
/// O adapter só entra em cena quando existe registrar de seleção, então o
/// `SelectionArea` faz parte do cenário, não é enfeite.
void main() {
  testWidgets('markdown do agente monta dentro do ShadcnApp (sem Material)', (
    tester,
  ) async {
    final tokens = buildTokens(brightness: Brightness.dark);

    await tester.pumpWidget(
      ShadcnApp(
        theme: buildTheme(brightness: Brightness.dark),
        home: CockpitTheme(
          colors: tokens.colors,
          typo: tokens.typo,
          syntax: tokens.syntax,
          terminal: tokens.terminal,
          child: const SelectionArea(
            // A fórmula é o que importa: o `SelectableAdapter` (onde mora a
            // linha que crasha) só é usado pelos componentes de LaTeX do
            // pacote — e a sintaxe que ele reconhece é `\(...\)`, não `$...$`
            // (a variante com cifrão está comentada no upstream).
            child: AgentMarkdown(r'Energia: \(E = mc^2\) no meio do texto.'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // O teste só vale se ELE montar: o SelectableAdapter é o widget que
    // desreferencia a cor. Sem esta checagem, um teste verde não prova nada.
    expect(find.byType(SelectableAdapter), findsWidgets);
  });
}
