import 'dart:convert';
import 'dart:typed_data';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/doc_viewer/doc_viewer_page.dart';
import 'package:flutter/material.dart';

/// Plan/125 - left-aligned, tappable card for an [AgentFileMsg] (a document
/// the agent pushed from the repo via the `show_file` tool: Markdown / text /
/// PDF / HTML). Decodes the inline base64 once and shows an icon + filename +
/// a small preview / sandbox badge; tapping opens [DocViewerPage], which routes
/// by [kind] to the right viewer. Distinct from [AgentImageBubble] (plan/114).
class AgentFileBubble extends StatefulWidget {
  final AgentFileMsg message;
  const AgentFileBubble(this.message, {super.key});

  @override
  State<AgentFileBubble> createState() => _AgentFileBubbleState();
}

class _AgentFileBubbleState extends State<AgentFileBubble> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _decode(widget.message.data);
  }

  @override
  void didUpdateWidget(covariant AgentFileBubble old) {
    super.didUpdateWidget(old);
    if (old.message.data != widget.message.data) {
      _bytes = _decode(widget.message.data);
    }
  }

  static Uint8List? _decode(String data) {
    try {
      final b = base64Decode(data);
      return b.isEmpty ? null : b;
    } catch (_) {
      return null;
    }
  }

  String get _title {
    final caption = widget.message.caption.trim();
    if (caption.isNotEmpty) return caption;
    final p = widget.message.path;
    return (p == null || p.isEmpty) ? _defaultName() : p;
  }

  String _defaultName() => switch (widget.message.kind) {
        'markdown' => 'Markdown',
        'text' => 'Text file',
        'pdf' => 'PDF document',
        'html' => 'HTML page',
        _ => 'Document',
      };

  /// Basename of the repo path, for display.
  String get _filename {
    final p = widget.message.path;
    if (p == null || p.isEmpty) return _defaultName();
    final parts = p.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty);
    return parts.isEmpty ? p : parts.last;
  }

  IconData get _icon => switch (widget.message.kind) {
        'markdown' => Icons.description_outlined,
        'text' => Icons.article_outlined,
        'pdf' => Icons.picture_as_pdf_outlined,
        'html' => Icons.code_outlined,
        _ => Icons.drafts_outlined,
      };

  String? get _previewText {
    if (widget.message.kind != 'markdown' && widget.message.kind != 'text') {
      return null;
    }
    final bytes = _bytes;
    if (bytes == null) return null;
    final decoded = utf8.decode(bytes, allowMalformed: true);
    final lines = decoded.split(RegExp(r'\r?\n')).take(3).join('  ').trim();
    if (decoded.isEmpty || lines.isEmpty) return null;
    return lines.length > 140 ? '${lines.substring(0, 140)}…' : lines;
  }

  void _open() {
    final bytes = _bytes;
    if (bytes == null) return;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (_, _, _) => DocViewerPage(
          bytes: bytes,
          kind: widget.message.kind,
          mime: widget.message.mime,
          title: widget.message.path ?? _title,
          caption: widget.message.caption,
          allowNetwork: widget.message.allowNetwork,
        ),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final colors = context.colors;
    // Plan/125 review #6 — if the inline base64 failed to decode, show an
    // explicit error card instead of a normal card that silently no-ops on tap.
    if (_bytes == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.error),
            ),
            child: Row(
              children: [
                Icon(Icons.broken_image_outlined, color: colors.error, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Couldn\'t decode this file',
                    style: context.typo.sansBody
                        .copyWith(color: colors.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: GestureDetector(
          onTap: _open,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(_icon, color: colors.accent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _filename,
                        style: context.typo.sansBody.copyWith(
                          color: colors.text,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(Icons.chevron_right, color: colors.muted, size: 18),
                  ],
                ),
                if (_previewText != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _previewText!,
                    style: context.typo.monoSmall.copyWith(color: colors.muted2),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 6),
                _metaRow(colors),
                if (m.caption.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      m.caption.trim(),
                      style:
                          context.typo.sansBody.copyWith(color: colors.text),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metaRow(AppColors colors) {
    final kindLabel = switch (widget.message.kind) {
      'markdown' => 'Markdown',
      'text' => 'Text',
      'pdf' => 'PDF',
      'html' => 'HTML',
      _ => widget.message.kind,
    };
    final children = <Widget>[
      _pill(kindLabel, colors),
    ];
    if (widget.message.kind == 'html') {
      children.add(_pill(
          widget.message.allowNetwork ? 'JS · online' : 'JS · sandboxed',
          colors,
          warn: widget.message.allowNetwork));
    }
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  Widget _pill(String label, AppColors colors, {bool warn = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colors.codeBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: warn ? colors.warning : colors.border,
        ),
      ),
      child: Text(
        label,
        style: context.typo.monoSmall.copyWith(
          color: warn ? colors.warning : colors.muted,
          fontSize: 10,
        ),
      ),
    );
  }
}
