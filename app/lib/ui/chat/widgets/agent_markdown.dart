import 'package:app/ui/chat/widgets/copy_button.dart';
import 'package:app/ui/chat/widgets/linkify.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Plan/32b — renders the agent's Markdown reply (GFM + code) themed to the
/// app's dark/mono look. Links open in the system browser (url_launcher);
/// code blocks get a copy button. Tolerant of partial markdown so it can also
/// drive the live streaming bubble.
class AgentMarkdown extends StatefulWidget {
  const AgentMarkdown(this.data, {super.key, this.selectable = false});

  final String data;

  /// Wrap in a [SelectionArea] so prose/code can be selected + copied. Off for
  /// the streaming bubble (content changes every frame).
  final bool selectable;

  @override
  State<AgentMarkdown> createState() => _AgentMarkdownState();
}

class _AgentMarkdownState extends State<AgentMarkdown> {
  AppTypography? _themeTypography;
  Brightness? _themeBrightness;
  GptMarkdownThemeData? _gptTheme;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final typo = context.typo;
    final brightness = Theme.of(context).brightness;
    // Keep the package theme identical across token updates. Its inherited
    // wrapper compares by identity, so recreating it would notify the whole
    // Markdown subtree and undermine the renderer's incremental cache.
    if (_gptTheme == null ||
        !identical(typo, _themeTypography) ||
        brightness != _themeBrightness) {
      _themeTypography = typo;
      _themeBrightness = brightness;
      _gptTheme = buildMarkdownTheme(typo: typo, brightness: brightness);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final markdown = GptMarkdownTheme(
      gptThemeData: _gptTheme!,
      child: GptMarkdown(
        widget.data,
        style: typo.mono,
        onLinkTap: (url, _) => openUrl(context, url),
        // Bare URLs, explicit links, punctuation peeling, and balanced
        // parentheses use the renderer's built-in GFM autolink path.
        // Inline `code` — subtle highlight, keeps the baseline.
        inlineCodeBuilder: (context, text, style, codeStyle) => TextSpan(
          text: text,
          style: typo.mono.copyWith(
            color: colors.highlight,
            backgroundColor: colors.codeBg,
          ),
        ),
        // Fenced ``` blocks — dark card + copy button.
        codeBuilder: (context, name, code, closed) =>
            _CodeBlock(language: name, code: code),
      ),
    );
    return widget.selectable
        ? SelectionArea(child: markdown)
        : markdown;
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


