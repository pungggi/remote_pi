import 'package:flutter/material.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'linkify.dart';

/// GPT-Markdown inline component that turns bare `http(s)://` URLs into tappable
/// links, mirroring how explicit `[text](url)` links are rendered: underlined,
/// coloured with the theme link colour, and routed through `onLinkTap`.
///
/// It is appended LAST to [MarkdownComponent.inlineComponents] so explicit
/// Markdown links, inline code, emphasis, images, etc. always take precedence —
/// a bare URL only wins when nothing else matches at that position.
class AutoLinkMd extends InlineMd {
  @override
  RegExp get exp => urlRegExp;

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    // The combined regex hands us the full greedy URL run. Peel trailing prose
    // punctuation (and an unmatched ')') so it stays as normal text instead of
    // becoming part of the link target — e.g. "see https://x.com." or
    // "(https://x.com)".
    final urlEnd = _urlEnd(text);
    final url = text.substring(0, urlEnd);
    final trailing = text.substring(urlEnd);

    final theme = GptMarkdownTheme.of(context);
    final base = config.style ?? const TextStyle();
    final linkStyle = base.copyWith(
      color: theme.linkColor,
      decoration: TextDecoration.underline,
      decorationColor: theme.linkColor,
    );

    final linkSpan = WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: GestureDetector(
        onTap: url.isEmpty ? null : () => config.onLinkTap?.call(url, url),
        child: Text(url, style: linkStyle),
      ),
    );

    // Re-parse the peeled tail (empty when there was nothing to peel) so any
    // inline Markdown there still renders; the URL itself is a tappable span.
    final trailingSpans = MarkdownComponent.generate(context, trailing, config, false);
    return TextSpan(children: [linkSpan, ...trailingSpans]);
  }

  /// Index in [token] just past the real URL, before trailing punctuation.
  static int _urlEnd(String token) {
    var end = token.length;
    const trailingPunct = '.,;:!?';
    while (end > 0 && trailingPunct.contains(token[end - 1])) {
      end--;
    }
    // Drop a trailing ')' when the parens in the remainder are unbalanced —
    // e.g. prose "(see https://x.com)" where the ')' isn't part of the URL.
    var depth = 0;
    for (var i = 0; i < end; i++) {
      final c = token[i];
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
      }
    }
    if (depth < 0) end--;
    return end;
  }
}
