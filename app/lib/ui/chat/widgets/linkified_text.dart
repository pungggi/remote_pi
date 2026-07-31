import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'linkify.dart';

/// Renders [text] with any bare HTTP(S) URLs as tappable links that open in the
/// system browser (via [openUrl]).
///
/// When [selectable] (the default) the text is wrapped in a [SelectionArea] so
/// it can still be copied, matching the old plain `SelectableText` behaviour.
/// Used for the user's own chat bubble — the agent reply uses Markdown, whose
/// links are handled by `AgentMarkdown` + the `AutoLinkMd` component.
class LinkifiedText extends StatefulWidget {
  const LinkifiedText(
    this.text, {
    super.key,
    required this.style,
    this.linkStyle,
    this.selectable = true,
  });

  final String text;

  /// Style for non-link runs of text.
  final TextStyle style;

  /// Style for URL runs (typically accent + underline).
  final TextStyle? linkStyle;

  /// Wrap in a [SelectionArea] so the text can be selected/copied.
  final bool selectable;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final List<GestureRecognizer> _recognizers = [];
  late InlineSpan _span;

  @override
  void initState() {
    super.initState();
    _span = _build();
  }

  @override
  void didUpdateWidget(covariant LinkifiedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.linkStyle != widget.linkStyle) {
      _disposeRecognizers();
      _span = _build();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  InlineSpan _build() {
    final spans = <InlineSpan>[];
    widget.text.splitMapJoin(
      urlRegExp,
      onMatch: (m) {
        // Peel trailing prose punctuation so it isn't part of the link target
        // (mirrors the Markdown autolinker via the shared peelUrl helper).
        final (:url, :trailing) = peelUrl(m[0]!);
        final recognizer = TapGestureRecognizer()
          ..onTap = () {
            if (!mounted) return;
            openUrl(context, url);
          };
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(text: url, style: widget.linkStyle, recognizer: recognizer),
        );
        if (trailing.isNotEmpty) {
          spans.add(TextSpan(text: trailing, style: widget.style));
        }
        return '';
      },
      onNonMatch: (nonMatch) {
        if (nonMatch.isNotEmpty) {
          spans.add(TextSpan(text: nonMatch, style: widget.style));
        }
        return '';
      },
    );
    return TextSpan(children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final rich = Text.rich(_span, style: widget.style);
    return widget.selectable ? SelectionArea(child: rich) : rich;
  }
}
