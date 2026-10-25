import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/markdown_editing_controller.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' show ShadcnApp, Brightness;

void main() {
  testWidgets('span text round-trips the source exactly, bold gets w700', (
    tester,
  ) async {
    const src =
        '# Title\n\nSome **bold** and _it_ `code` ~~gone~~\n'
        '- [x] done\n- [ ] todo\n1. one\n> quote\n```\nx = 1\n```\n[a](http://b)';
    final c = MarkdownEditingController(text: src);
    late TextSpan span;
    await tester.pumpWidget(
      ShadcnApp(
        theme: buildTheme(brightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            span = c.buildTextSpan(context: context, withComposing: false);
            return const SizedBox();
          },
        ),
      ),
    );
    // WidgetSpan vira U+FFFC no plain text; fora disso o texto é idêntico.
    expect(span.toPlainText().length, src.length);
    var boldSeen = false;
    span.visitChildren((s) {
      if (s is TextSpan && s.text == 'bold') {
        boldSeen = s.style?.fontWeight == FontWeight.w700;
      }
      return true;
    });
    expect(boldSeen, isTrue);
    // Cursor no início (linha 1) → os `**` da linha 3 ficam escondidos.
    var hiddenStars = 0;
    span.visitChildren((s) {
      if (s is TextSpan && s.text == '**' && s.style?.fontSize == 0.1) {
        hiddenStars++;
      }
      return true;
    });
    expect(hiddenStars, 2);
  });

  test('Enter continues lists, numbering increments, empty item exits', () {
    final c = MarkdownEditingController(text: '- a');
    c.value = const TextEditingValue(
      text: '- a\n',
      selection: TextSelection.collapsed(offset: 4),
    );
    expect(c.text, '- a\n- ');
    expect(c.selection.baseOffset, 6);
    // item vazio + Enter → encerra
    c.value = const TextEditingValue(
      text: '- a\n- \n',
      selection: TextSelection.collapsed(offset: 7),
    );
    expect(c.text, '- a\n\n');
    final n = MarkdownEditingController(text: '1. x\n- [x] y');
    n.value = const TextEditingValue(
      text: '1. x\n\n- [x] y',
      selection: TextSelection.collapsed(offset: 5),
    );
    expect(n.text, '1. x\n2. \n- [x] y');
    final t = MarkdownEditingController(text: '- [x] y');
    t.value = const TextEditingValue(
      text: '- [x] y\n',
      selection: TextSelection.collapsed(offset: 8),
    );
    expect(t.text, '- [x] y\n- [ ] ');
  });

  testWidgets('renders inside a real TextField (inline glyphs allowed)', (
    tester,
  ) async {
    final c = MarkdownEditingController(text: '- um\n- [x] dois\n**b**');
    await tester.pumpWidget(
      ShadcnApp(
        theme: buildTheme(brightness: Brightness.dark),
        home: material.Material(
          child: material.TextField(controller: c, maxLines: null),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(material.TextField), findsOneWidget);
    // Digitar e mover o cursor por cima dos glifos não pode estourar.
    await tester.tap(find.byType(material.TextField));
    await tester.pump();
    c.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();
    await tester.enterText(
      find.byType(material.TextField),
      '- um x\n- [x] dois\n**b**',
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the checkbox glyph toggles the item', (tester) async {
    final c = MarkdownEditingController(text: 'a\n- [ ] dois');
    await tester.pumpWidget(
      ShadcnApp(
        theme: buildTheme(brightness: Brightness.dark),
        home: material.Material(
          child: material.TextField(controller: c, maxLines: null),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(material.Icons.check_box_outline_blank));
    await tester.pump();
    expect(c.text, 'a\n- [x] dois');
    await tester.tap(find.byIcon(material.Icons.check_box));
    await tester.pump();
    expect(c.text, 'a\n- [ ] dois');
  });

  test('Backspace right after a list marker removes the whole marker', () {
    final c = MarkdownEditingController(text: 'x\n- [ ] ');
    c.selection = const TextSelection.collapsed(offset: 8);
    c.value = const TextEditingValue(
      text: 'x\n- [ ]',
      selection: TextSelection.collapsed(offset: 7),
    );
    expect(c.text, 'x\n');
    expect(c.selection.baseOffset, 2);
    final b = MarkdownEditingController(text: '- abc');
    b.selection = const TextSelection.collapsed(offset: 2);
    b.value = const TextEditingValue(
      text: '-abc',
      selection: TextSelection.collapsed(offset: 1),
    );
    expect(b.text, 'abc');
    // Backspace no meio do texto segue normal.
    final n = MarkdownEditingController(text: '- abc');
    n.selection = const TextSelection.collapsed(offset: 5);
    n.value = const TextEditingValue(
      text: '- ab',
      selection: TextSelection.collapsed(offset: 4),
    );
    expect(n.text, '- ab');
  });

  testWidgets('image off the cursor line becomes an inline widget', (
    tester,
  ) async {
    final c = MarkdownEditingController(
      text: 'x\n![](_assets/nope.png)',
      imageBaseDir: '/tmp/none.notebook',
    );
    late TextSpan span;
    await tester.pumpWidget(
      ShadcnApp(
        theme: buildTheme(brightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            span = c.buildTextSpan(context: context, withComposing: false);
            return const SizedBox();
          },
        ),
      ),
    );
    var widgets = 0;
    span.visitChildren((s) {
      if (s is WidgetSpan) widgets++;
      return true;
    });
    expect(widgets, 1);
    expect(span.toPlainText().length, c.text.length);
  });

  testWidgets('[[link]] off the cursor line is a tappable chip', (
    tester,
  ) async {
    String? opened;
    final c = MarkdownEditingController(text: 'x\nveja [[Outra nota]] ok')
      ..onWikiLink = (t) => opened = t;
    await tester.pumpWidget(
      ShadcnApp(
        theme: buildTheme(brightness: Brightness.dark),
        home: material.Material(
          child: material.TextField(controller: c, maxLines: null),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Outra nota'));
    await tester.pump();
    expect(opened, 'Outra nota');
    expect(c.text, 'x\nveja [[Outra nota]] ok');
  });

  testWidgets('tall inline image makes the field grow (strut disabled)', (
    tester,
  ) async {
    final c = MarkdownEditingController(
      text: 'linha 1\n![](nope.png)\nlinha 3',
      imageBaseDir: '/tmp/none.notebook',
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      ShadcnApp(
        theme: buildTheme(brightness: Brightness.dark),
        home: material.Material(
          child: SingleChildScrollView(
            child: material.TextField(
              key: key,
              controller: c,
              maxLines: null,
              strutStyle: StrutStyle.disabled,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final box = key.currentContext!.findRenderObject() as RenderBox;
    // 3 linhas de texto (~72) + caixa da imagem (220) → bem acima de 200.
    expect(box.size.height, greaterThan(200));
  });
}
