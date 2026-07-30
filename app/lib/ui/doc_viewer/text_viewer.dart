import 'dart:convert';
import 'dart:typed_data';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Plan/125 - plain-text / code viewer for a text-y file the agent pushed via
/// `show_file` (`.txt`, `.json`, `.yaml`, `.dart`, `.ts`, ...). Monospace,
/// line-numbered gutter, selectable. A toolbar chip toggles soft-wrap on/off.
/// Syntax highlighting is a follow-up (cockpit uses the `highlight` package);
/// MVP renders plain monospace.
class TextViewer extends StatefulWidget {
  final Uint8List bytes;

  const TextViewer({super.key, required this.bytes});

  @override
  State<TextViewer> createState() => _TextViewerState();
}

class _TextViewerState extends State<TextViewer> {
  bool _wrap = true;

  String get _source => utf8.decode(widget.bytes, allowMalformed: true);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final lines = _source.split('\n');
    final gutterChars = lines.length.toString().length.clamp(2, 6);
    // ~monospace advance; good enough for the gutter column width.
    final gutterWidth = gutterChars * 8.0;

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < lines.length; i++)
          Padding(
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
                if (_wrap)
                  Expanded(
                    child: Text(
                      lines[i].isEmpty ? ' ' : lines[i],
                      style: context.typo.mono
                          .copyWith(color: colors.text, height: 1.4),
                    ),
                  )
                else
                  Text(
                    lines[i].isEmpty ? ' ' : lines[i],
                    style: context.typo.mono
                        .copyWith(color: colors.text, height: 1.4),
                  ),
              ],
            ),
          ),
      ],
    );

    final body = _wrap
        ? SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: column,
          )
        : SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: IntrinsicWidth(child: column),
            ),
          );

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
        Expanded(child: SelectionArea(child: body)),
      ],
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
