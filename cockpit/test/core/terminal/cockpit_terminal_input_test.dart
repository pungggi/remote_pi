import 'package:cockpit/app/core/terminal/cockpit_terminal.dart';
import 'package:cockpit/app/core/terminal/xterm/xterm.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // `flutter_test` se reporta como Android, e no mobile o campo de texto do
  // terminal só abre a conexão de IME depois de um tap explícito (a
  // restauração de foco não pode reabrir o teclado sozinha). Estes testes
  // cobrem o caminho DESKTOP, onde o foco basta — então fixam a plataforma.
  // O override tem de voltar a `null` ANTES do fim do corpo do teste (o
  // `flutter_test` verifica as variáveis de debug no fim de cada teste), então
  // vale só durante o pump inicial — é aí que a conexão de IME é aberta.
  Future<void> pumpDesktop(WidgetTester tester, Widget app) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(app);
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('commits an IME character only once', (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    await pumpDesktop(
      tester,
      MaterialApp(
        home: Scaffold(body: CockpitTerminal(terminal, autofocus: true)),
      ),
    );

    final textInput = tester.binding.testTextInput;
    for (final character in ['~', '´', 'á', 'í']) {
      final committed = TextEditingValue(
        text: character,
        selection: TextSelection.collapsed(offset: character.length),
      );
      textInput.updateEditingValue(committed);
      textInput.updateEditingValue(committed);
      textInput.updateEditingValue(committed);
      textInput.updateEditingValue(TextEditingValue.empty);
    }
    await tester.pump();

    expect(output, ['~', '´', 'á', 'í']);
  });

  testWidgets('types a doubled letter without swallowing the repeat', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    await pumpDesktop(
      tester,
      MaterialApp(
        home: Scaffold(body: CockpitTerminal(terminal, autofocus: true)),
      ),
    );

    // Typing "esse": the platform never echoes the hidden-buffer reset back, so
    // each keystroke arrives as a lone commit carrying the same delta as the
    // one before it. Both `s` must reach the PTY — the IME de-duplication is
    // only meant to collapse a *re-sent* commit, which has no key event.
    final textInput = tester.binding.testTextInput;
    const keys = {'e': LogicalKeyboardKey.keyE, 's': LogicalKeyboardKey.keyS};
    for (final character in ['e', 's', 's', 'e']) {
      await tester.sendKeyEvent(keys[character]!);
      textInput.updateEditingValue(
        TextEditingValue(
          text: character,
          selection: TextSelection.collapsed(offset: character.length),
        ),
      );
    }
    await tester.pump();

    expect(output.join(), 'esse');
  });
}
