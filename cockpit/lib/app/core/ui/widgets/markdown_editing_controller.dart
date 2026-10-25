import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'dart:io' show File;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

/// `TextEditingController` que pinta markdown **ao vivo** enquanto se digita:
/// `**negrito**` sai em negrito, `# título` grande, `- [ ]` com marcador em
/// destaque, `` `código` `` mono com fundo. Os marcadores (`**`, `#`, `` ` ``…)
/// ficam **escondidos** (fonte ~0, transparentes) em todas as linhas menos na
/// linha do cursor, onde aparecem esmaecidos pra poder editar a sintaxe —
/// mesmo comportamento do live preview do Obsidian. O texto no disco é
/// markdown puro e o cursor anda caractere a caractere (os escondidos ainda
/// existem, só não ocupam espaço). É o "WYSIWYG possível" sobre um TextField:
/// um só modo, sem alternar fonte ↔ preview.
///
/// Mesma técnica do [CodeEditingController]: sobrescrever [buildTextSpan]. O
/// parser é por linha (blocos) + regex inline, tolerante — nunca lança e nunca
/// muda o texto.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text, this.imageBaseDir}) {
    selection = const TextSelection.collapsed(offset: 0);
  }

  /// Pasta base para `![](caminho relativo)`. `null` = imagens só como texto.
  /// Mutável: a mesma controller serve várias notas do mesmo caderno.
  String? imageBaseDir;

  /// Clique num `[[Título]]` fora da linha do cursor. `null` = link só pinta.
  void Function(String title)? onWikiLink;

  /// `[[Título]]` — link entre notas do caderno (estilo Obsidian).
  static final wikiLink = RegExp(r'\[\[([^\]\n]+)\]\]');

  static final _heading = RegExp(r'^(#{1,6})( )(.*)$');
  static final _task = RegExp(r'^(\s*)([-*+] \[[ xX]\] )(.*)$');
  static final _bullet = RegExp(r'^(\s*)([-*+] )(.*)$');
  static final _numbered = RegExp(r'^(\s*)(\d+[.)] )(.*)$');
  static final _quote = RegExp(r'^(> ?)(.*)$');
  static final _fence = RegExp(r'^\s*(```|~~~)');
  static final _rule = RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$');

  // Inline: código primeiro (dentro de `` ` `` nada mais vale), depois
  // negrito+itálico, negrito, itálico, riscado, imagem, link.
  static final _inline = RegExp(
    r'(`[^`\n]+`)'
    r'|(\*\*\*[^*\n]+?\*\*\*)'
    r'|(\*\*[^*\n]+?\*\*|__[^_\n]+?__)'
    r'|((?<![\w*])\*[^*\n]+?\*(?![\w*])|(?<![\w_])_[^_\n]+?_(?![\w_]))'
    r'|(~~[^~\n]+?~~)'
    r'|(!\[[^\]\n]*\]\([^)\n]*\))'
    r'|(\[[^\]\n]+\]\([^)\n]*\))'
    r'|(\[\[[^\]\n]+\]\])',
  );

  static final _listPrefix = RegExp(
    r'^(\s*)([-*+] \[[ xX]\] |[-*+] |\d+[.)] |> )',
  );

  /// Enter numa linha de lista continua a lista (`- `, `1. ` → `2. `,
  /// `- [ ] `, `> `); Enter numa linha de lista **vazia** encerra a lista
  /// (apaga o marcador). Só age quando a edição foi exatamente "um \n
  /// digitado no cursor" — colar, undo e edições programáticas passam direto.
  @override
  set value(TextEditingValue newValue) {
    final old = super.value;
    final sel = newValue.selection;
    // Backspace logo depois de um marcador de lista ("- |", "- [ ] |", "1. |",
    // "> |") apaga o marcador inteiro de uma vez — o usuário vê um ponto, não
    // dois caracteres, então um Backspace só é o esperado.
    if (sel.isCollapsed &&
        old.selection.isCollapsed &&
        newValue.text.length == old.text.length - 1 &&
        sel.baseOffset == old.selection.baseOffset - 1 &&
        old.text.substring(0, sel.baseOffset) ==
            newValue.text.substring(0, sel.baseOffset)) {
      final caret = old.selection.baseOffset;
      final lineStart = old.text.lastIndexOf('\n', caret - 1) + 1;
      final head = old.text.substring(lineStart, caret);
      final m = _listPrefix.firstMatch(head);
      if (m != null && m.group(0)!.length == head.length) {
        final indent = m.group(1)!.length;
        super.value = TextEditingValue(
          text: old.text.replaceRange(lineStart + indent, caret, ''),
          selection: TextSelection.collapsed(offset: lineStart + indent),
        );
        return;
      }
    }
    if (sel.isCollapsed &&
        newValue.text.length == old.text.length + 1 &&
        sel.baseOffset > 0 &&
        newValue.text[sel.baseOffset - 1] == '\n' &&
        newValue.text.substring(0, sel.baseOffset - 1) ==
            old.text.substring(0, sel.baseOffset - 1)) {
      final caret = sel.baseOffset;
      final prevStart = newValue.text.lastIndexOf('\n', caret - 2) + 1;
      final prevLine = newValue.text.substring(prevStart, caret - 1);
      final m = _listPrefix.firstMatch(prevLine);
      if (m != null) {
        final prefix = m.group(0)!;
        if (prevLine.length == prefix.length) {
          // Item vazio + Enter → sai da lista: remove o marcador da linha.
          final text = newValue.text.replaceRange(prevStart, caret, '\n');
          super.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: prevStart + 1),
          );
          return;
        }
        var next = prefix;
        final num = RegExp(r'^(\s*)(\d+)([.)] )$').firstMatch(prefix);
        if (num != null) {
          next =
              '${num.group(1)}${int.parse(num.group(2)!) + 1}${num.group(3)}';
        } else {
          next = prefix.replaceFirst(RegExp(r'\[[xX]\]'), '[ ]');
        }
        final text = newValue.text.replaceRange(caret, caret, next);
        super.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: caret + next.length),
        );
        return;
      }
    }
    super.value = newValue;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final colors = context.colors;
    final typo = context.typo;
    final base = style ?? typo.body;
    final dim = base.copyWith(color: colors.text3);
    // Escondido: fonte quase zero e transparente — ocupa ~0px mas segue no
    // texto, então seleção/cursor continuam válidos.
    final hidden = base.copyWith(
      fontSize: 0.1,
      color: const Color(0x00000000),
      letterSpacing: 0,
    );
    final cursor = selection.isValid ? selection.extentOffset : -1;
    final mono = typo.mono.copyWith(
      fontSize: (base.fontSize ?? 14) - 1,
      color: colors.text,
      backgroundColor: colors.panel3,
    );

    final text = this.text;
    final spans = <InlineSpan>[];
    var inFence = false;
    var offset = 0;
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final isLast = i == lines.length - 1;
      final nl = isLast ? '' : '\n';
      // Linha do cursor revela os marcadores; as outras escondem.
      final onCursor = cursor >= offset && cursor <= offset + line.length;
      final marker = onCursor ? dim : hidden;

      if (_fence.hasMatch(line)) {
        inFence = !inFence;
        spans.add(TextSpan(text: '$line$nl', style: marker));
      } else if (inFence) {
        spans.add(TextSpan(text: line, style: mono));
        if (nl.isNotEmpty) spans.add(TextSpan(text: nl, style: base));
      } else if (_rule.hasMatch(line)) {
        spans.add(TextSpan(text: '$line$nl', style: marker));
      } else if (_heading.firstMatch(line) case final m?) {
        final level = m.group(1)!.length;
        final size = switch (level) {
          1 => 1.6,
          2 => 1.35,
          3 => 1.18,
          _ => 1.05,
        };
        final hStyle = base.copyWith(
          fontSize: (base.fontSize ?? 14) * size,
          fontWeight: FontWeight.w700,
          color: colors.text,
          height: 1.4,
        );
        spans.add(
          TextSpan(
            text: '${m.group(1)}${m.group(2)}',
            style: onCursor ? hStyle.copyWith(color: colors.text3) : hidden,
          ),
        );
        spans.addAll(_inlineSpans(m.group(3)!, hStyle, colors, marker, mono));
        spans.add(TextSpan(text: nl, style: base));
      } else if (_task.firstMatch(line) case final m?) {
        final done = m.group(2)!.contains(RegExp(r'\[[xX]\]'));
        final mk = m.group(2)!; // "- [ ] " — 6 chars: - ␠ [ x ] ␠
        spans.add(TextSpan(text: m.group(1), style: base));
        // Some "- [" e "]"; o caractere de dentro vira a caixa desenhada.
        // Cada WidgetSpan substitui exatamente UM caractere → os offsets
        // do texto batem e o cursor segue certo.
        spans.add(TextSpan(text: mk.substring(0, 3), style: hidden));
        final innerOffset = offset + m.group(1)!.length + 3;
        spans.add(
          _glyph(
            done ? Icons.check_box : Icons.check_box_outline_blank,
            base,
            done ? colors.online : colors.accent,
            onTap: () => toggleTaskAt(innerOffset),
          ),
        );
        spans.add(TextSpan(text: mk.substring(4, 5), style: hidden));
        spans.add(TextSpan(text: mk.substring(5), style: base));
        final body = done
            ? base.copyWith(
                color: colors.text3,
                decoration: TextDecoration.lineThrough,
              )
            : base;
        spans.addAll(_inlineSpans(m.group(3)!, body, colors, marker, mono));
        spans.add(TextSpan(text: nl, style: base));
      } else if (_bullet.firstMatch(line) case final m?) {
        // "- texto" → "• texto": o hífen vira um ponto desenhado (1 char ↔ 1
        // WidgetSpan), o espaço fica.
        spans.add(TextSpan(text: m.group(1), style: base));
        spans.add(_glyph(Icons.circle, base, colors.text2, scale: 0.42));
        spans.add(TextSpan(text: m.group(2)!.substring(1), style: base));
        spans.addAll(_inlineSpans(m.group(3)!, base, colors, marker, mono));
        spans.add(TextSpan(text: nl, style: base));
      } else if (_numbered.firstMatch(line) case final m?) {
        spans.add(TextSpan(text: m.group(1), style: base));
        spans.add(
          TextSpan(
            text: m.group(2),
            style: base.copyWith(
              color: colors.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
        spans.addAll(_inlineSpans(m.group(3)!, base, colors, marker, mono));
        spans.add(TextSpan(text: nl, style: base));
      } else if (_quote.firstMatch(line) case final m?) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: onCursor ? base.copyWith(color: colors.accent) : hidden,
          ),
        );
        final q = base.copyWith(
          color: colors.text2,
          fontStyle: FontStyle.italic,
        );
        spans.addAll(_inlineSpans(m.group(2)!, q, colors, marker, mono));
        spans.add(TextSpan(text: nl, style: base));
      } else {
        spans.addAll(_inlineSpans(line, base, colors, marker, mono));
        spans.add(TextSpan(text: nl, style: base));
      }
      offset += line.length + nl.length;
    }
    assert(offset == text.length);
    return TextSpan(style: base, children: spans);
  }

  /// Ícone inline no lugar de um caractere. `alignment: middle` centra na
  /// linha; o tamanho segue a fonte do texto.
  static WidgetSpan _glyph(
    IconData icon,
    TextStyle base,
    Color color, {
    double scale = 1.0,
    VoidCallback? onTap,
  }) {
    final size = (base.fontSize ?? 14) * 1.1;
    Widget child = SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Icon(icon, size: size * scale, color: color),
      ),
    );
    if (onTap != null) {
      child = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: child,
        ),
      );
    }
    return WidgetSpan(alignment: PlaceholderAlignment.middle, child: child);
  }

  /// Inverte a caixa de um item de checklist: [innerOffset] é o offset do
  /// caractere entre `[` e `]`. Mantém a seleção onde estava.
  void toggleTaskAt(int innerOffset) {
    final t = text;
    if (innerOffset < 0 || innerOffset >= t.length) return;
    final ch = t[innerOffset];
    final next = (ch == 'x' || ch == 'X') ? ' ' : 'x';
    final sel = selection;
    value = TextEditingValue(
      text: t.replaceRange(innerOffset, innerOffset + 1, next),
      selection: sel.isValid ? sel : TextSelection.collapsed(offset: 0),
    );
  }

  List<InlineSpan> _inlineSpans(
    String s,
    TextStyle base,
    AppColors colors,
    TextStyle marker,
    TextStyle mono,
  ) {
    if (s.isEmpty) return const [];
    final out = <InlineSpan>[];
    var last = 0;
    for (final m in _inline.allMatches(s)) {
      if (m.start > last) {
        out.add(TextSpan(text: s.substring(last, m.start), style: base));
      }
      final tok = m.group(0)!;
      final mk = marker.fontSize == 0.1
          ? marker
          : marker.copyWith(fontSize: base.fontSize);
      if (m.group(1) != null) {
        // `código`
        out.add(TextSpan(text: '`', style: mk));
        out.add(
          TextSpan(
            text: tok.substring(1, tok.length - 1),
            style: mono.copyWith(fontSize: (base.fontSize ?? 14) - 1),
          ),
        );
        out.add(TextSpan(text: '`', style: mk));
      } else if (m.group(2) != null) {
        _wrapped(
          out,
          tok,
          3,
          mk,
          base.copyWith(
            fontWeight: FontWeight.w700,
            fontStyle: FontStyle.italic,
          ),
        );
      } else if (m.group(3) != null) {
        _wrapped(out, tok, 2, mk, base.copyWith(fontWeight: FontWeight.w700));
      } else if (m.group(4) != null) {
        _wrapped(out, tok, 1, mk, base.copyWith(fontStyle: FontStyle.italic));
      } else if (m.group(5) != null) {
        _wrapped(
          out,
          tok,
          2,
          mk,
          base.copyWith(
            color: colors.text3,
            decoration: TextDecoration.lineThrough,
          ),
        );
      } else if (m.group(6) != null) {
        // ![alt](src) — na linha do cursor mostra a sintaxe (esmaecida) pra
        // editar; fora dela esconde o texto e desenha a imagem num WidgetSpan
        // sobre o primeiro caractere (mesma técnica da caixa do checklist).
        final hiddenLine = marker.fontSize == 0.1;
        final src = _imageSrc(tok);
        final path = _resolveImage(src);
        if (!hiddenLine || path == null) {
          out.add(
            TextSpan(
              text: tok,
              style: base.copyWith(color: colors.text3),
            ),
          );
        } else {
          out.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.bottom,
              child: _InlineImage(path: path, alt: src),
            ),
          );
          out.add(TextSpan(text: tok.substring(1), style: marker));
        }
      } else if (m.group(8) != null) {
        // [[Título]] — link pra outra nota. Fora da linha do cursor vira um
        // chip clicável (WidgetSpan no primeiro char, resto escondido); na
        // linha do cursor mostra a sintaxe com o título em destaque.
        final title = tok.substring(2, tok.length - 2);
        final hiddenLine = marker.fontSize == 0.1;
        if (hiddenLine) {
          out.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _WikiLinkChip(
                title: title,
                style: base,
                onTap: onWikiLink == null ? null : () => onWikiLink!(title),
              ),
            ),
          );
          out.add(TextSpan(text: tok.substring(1), style: marker));
        } else {
          out.add(TextSpan(text: '[[', style: mk));
          out.add(
            TextSpan(
              text: title,
              style: base.copyWith(color: colors.accent),
            ),
          );
          out.add(TextSpan(text: ']]', style: mk));
        }
      } else {
        // [texto](url) — texto como link, url esmaecida.
        final close = tok.indexOf('](');
        out.add(TextSpan(text: '[', style: mk));
        out.add(
          TextSpan(
            text: tok.substring(1, close),
            style: base.copyWith(
              color: colors.gitUntracked,
              decoration: TextDecoration.underline,
            ),
          ),
        );
        out.add(TextSpan(text: tok.substring(close), style: mk));
      }
      last = m.end;
    }
    if (last < s.length) {
      out.add(TextSpan(text: s.substring(last), style: base));
    }
    return out;
  }

  static String _imageSrc(String tok) {
    final open = tok.indexOf('](');
    return tok.substring(open + 2, tok.length - 1).trim();
  }

  /// Caminho absoluto da imagem local, ou `null` pra http(s)/sem base.
  String? _resolveImage(String src) {
    if (src.isEmpty ||
        src.startsWith('http://') ||
        src.startsWith('https://')) {
      return null;
    }
    final decoded = Uri.decodeFull(src);
    if (decoded.startsWith('/')) return decoded;
    final base = imageBaseDir;
    if (base == null || base.isEmpty) return null;
    return '$base${base.endsWith('/') ? '' : '/'}$decoded';
  }

  static void _wrapped(
    List<InlineSpan> out,
    String tok,
    int n,
    TextStyle marker,
    TextStyle inner,
  ) {
    out.add(TextSpan(text: tok.substring(0, n), style: marker));
    out.add(TextSpan(text: tok.substring(n, tok.length - n), style: inner));
    out.add(TextSpan(text: tok.substring(tok.length - n), style: marker));
  }
}

/// Imagem inline do editor. `FileImage` é chaveado por caminho no ImageCache
/// do Flutter, então reconstruir a cada tecla não decodifica de novo.
///
/// O tamanho é **fixo** (não depende da decodificação): um placeholder inline
/// que cresce depois do primeiro frame deixa o texto do campo com o layout
/// antigo até algo forçar re-layout (era a imagem "por cima" que só se
/// ajeitava ao rolar). Com caixa fixa o layout do texto é o mesmo antes e
/// depois de a imagem chegar. Erro de leitura mostra o caminho.
class _InlineImage extends StatelessWidget {
  const _InlineImage({required this.path, required this.alt});
  final String path;
  final String alt;

  static const double boxHeight = 220;
  static const double boxWidth = 480;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SizedBox(
        width: boxWidth,
        height: boxHeight,
        child: Align(
          alignment: Alignment.centerLeft,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image(
              image: FileImage(File(path)),
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
              // Sem fade/troca de tamanho entre frames: o que muda é só o
              // conteúdo dentro da caixa.
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => Text(
                alt,
                style: context.typo.mono.copyWith(
                  fontSize: 11,
                  color: colors.text3,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Chip de link entre notas: título em cor de destaque com um ícone
/// discreto; clique abre (ou cria) a nota.
class _WikiLinkChip extends StatelessWidget {
  const _WikiLinkChip({required this.title, required this.style, this.onTap});
  final String title;
  final TextStyle style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.description_outlined,
            size: (style.fontSize ?? 14) * 0.85,
            color: colors.accent,
          ),
          const SizedBox(width: 4),
          Text(title, style: style.copyWith(color: colors.accent)),
        ],
      ),
    );
    if (onTap == null) return chip;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: chip,
      ),
    );
  }
}
