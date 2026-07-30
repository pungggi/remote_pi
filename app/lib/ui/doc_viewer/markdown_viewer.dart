import 'dart:convert';
import 'dart:typed_data';

import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Plan/126 - Markdown viewer for a `.md` file the agent pushed via `show_file`.
/// Renders GFM + code blocks with the same [AgentMarkdown] renderer used for
/// agent replies (plan/32b), selectable + with copy buttons. A toolbar chip
/// toggles between **Rendered** and **Source** (raw markdown). Scrollable.
class MarkdownViewer extends StatefulWidget {
  final Uint8List bytes;

  const MarkdownViewer({super.key, required this.bytes});

  @override
  State<MarkdownViewer> createState() => _MarkdownViewerState();
}

class _MarkdownViewerState extends State<MarkdownViewer> {
  bool _showSource = false;

  String get _source => utf8.decode(widget.bytes, allowMalformed: true);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      children: [
        // Thin toolbar: Rendered / Source toggle.
        Container(
          color: colors.surface,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              _toggle(context, 'Rendered', !_showSource, () {
                if (_showSource) setState(() => _showSource = false);
              }),
              const SizedBox(width: 6),
              _toggle(context, 'Source', _showSource, () {
                if (!_showSource) setState(() => _showSource = true);
              }),
            ],
          ),
        ),
        Expanded(
          child: _showSource
              ? _sourceView(context)
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: AgentMarkdown(_source, selectable: true),
                ),
        ),
      ],
    );
  }

  Widget _toggle(BuildContext context, String label, bool active, VoidCallback onTap) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active ? colors.accent : colors.codeBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.border),
        ),
        child: Text(
          label,
          style: context.typo.sansBody.copyWith(
            color: active ? colors.onAccent : colors.muted2,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _sourceView(BuildContext context) {
    final colors = context.colors;
    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text(
          _source,
          style: context.typo.mono.copyWith(color: colors.text, height: 1.45),
        ),
      ),
    );
  }
}
