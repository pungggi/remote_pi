import 'package:app/ui/chat/widgets/autolink_md.dart';
import 'package:app/ui/chat/widgets/copy_button.dart';
import 'package:app/ui/chat/widgets/linkify.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Plan/32b — renders the agent's Markdown reply (GFM + code) themed to the
/// app's dark/mono look. Links open in the system browser (url_launcher);
/// code blocks get a copy button. Tolerant of partial markdown so it can also
/// drive the live streaming bubble.
class AgentMarkdown extends StatelessWidget {
  const AgentMarkdown(this.data, {super.key, this.selectable = false});

  final String data;

  /// Wrap in a [SelectionArea] so prose/code can be selected + copied. Off for
  /// the streaming bubble (content changes every frame).
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final markdown = GptMarkdown(
      data,
      style: typo.mono,
      onLinkTap: (url, _) => openUrl(context, url),
      // Bare `http(s)://` URLs become tappable links too (not just explicit
      // `[text](url)` Markdown). Appended last so all other inline syntax —
      // links, code spans, emphasis — keeps precedence.
      inlineComponents: [
        ...MarkdownComponent.inlineComponents,
        AutoLinkMd(),
      ],
      // Inline `code` — subtle highlight, keeps the baseline.
      highlightBuilder: (context, text, style) => Text(
        text,
        style: typo.mono.copyWith(
          color: colors.highlight,
          backgroundColor: colors.codeBg,
        ),
      ),
      // Fenced ``` blocks — dark card + copy button.
      codeBuilder: (context, name, code, closed) =>
          _CodeBlock(language: name, code: code),
    );
    return selectable ? SelectionArea(child: markdown) : markdown;
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.language, required this.code});

  final String language;
  final String code;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: colors.codeBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    language.isEmpty ? 'code' : language,
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 10,
                      color: colors.muted,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                CopyButton(
                  key: const Key('code-copy'),
                  text: code,
                  tooltip: 'Copy code',
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Text(
              code,
              style: typo.mono.copyWith(color: colors.text, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}


