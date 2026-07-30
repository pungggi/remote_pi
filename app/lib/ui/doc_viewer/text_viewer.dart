import 'dart:convert';
import 'dart:typed_data';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Plan/125 - plain-text / code viewer for a text-y file the agent pushed via
/// `show_file` (`.txt`, `.json`, `.yaml`, `.dart`, `.ts`, ...). Monospace,
/// line-numbered gutter, selectable. A toolbar chip toggles soft-wrap on/off.
/// Syntax highlighting is a follow-up (cockpit uses the `highlight` package);
/// MVP renders plain monospace.
///
/// Renders lines lazily via [ListView.builder] so a 1 MiB file (tens of
/// thousands of lines) only builds the visible rows — no eager widget tree.
/// No-wrap mode truncates over-long lines with an ellipsis (wrap shows them
/// in full); this trades full-width horizontal scrolling for the
/// constant-memory lazy layout.
class TextViewer extends StatefulWidget {
  final Uint8List bytes;

  const TextViewer({super.key, required this.bytes});

  @override
  State<TextViewer> createState() => _TextViewerState();
}

class _TextViewerState extends State<TextViewer> {
  bool _wrap = true;
  // Decoded + split once per `bytes` (not per build/toggle).
  late List<String> _lines;

  @override
  void initState() {
    super.initState();
    _lines = _decode().split('\n');
  }

  @override
  void didUpdateWidget(covariant TextViewer old) {
    super.didUpdateWidget(old);
    if (old.bytes != widget.bytes) {
      _lines = _decode().split('\n');
    }
  }

  String _decode() => utf8.decode(widget.bytes, allowMalformed: true);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final gutterChars = _lines.length.toString().length.clamp(2, 6);
    // ~monospace advance; good enough for the gutter column width.
    final gutterWidth = gutterChars * 8.0;

    return Column(
      children: [
        Container(
          color: colors.surface,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              _toggle(context, 'Wrap', _wrap, () {
                if (!_wrap) setState(() => _wrap = true);
              }),
              const SizedBox(width: 6),
              _toggle(context, 'No wrap', !_wrap, () {
                if (_wrap) setState(() => _wrap = false);
              }),
            ],
          ),
        ),
        Expanded(
          // SelectionArea makes the plain Text rows selectable as a group.
          child: SelectionArea(
            child: ListView.builder(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              itemCount: _lines.length,
              itemBuilder: (context, i) => _row(i, gutterWidth),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(int i, double gutterWidth) {
    final colors = context.colors;
    final line = _lines[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: gutterWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                '${i + 1}',
                style: context.typo.monoSmall.copyWith(
                  color: colors.muted,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              line.isEmpty ? ' ' : line,
              softWrap: _wrap,
              // No-wrap: clip the overflow with an ellipsis so the row stays
              // one line (toggle Wrap to read the full line).
              overflow: _wrap ? TextOverflow.clip : TextOverflow.ellipsis,
              style: context.typo.mono.copyWith(color: colors.text, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggle(
      BuildContext context, String label, bool active, VoidCallback onTap) {
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
}
