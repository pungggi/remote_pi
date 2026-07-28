import 'dart:convert';
import 'dart:typed_data';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/image_viewer/image_viewer_page.dart';
import 'package:flutter/material.dart';

/// Plan/114 — left-aligned, tappable image bubble for an [AgentImageMsg]
/// (an image the agent pushed from the repo via `show_image`). Decodes the
/// inline base64 once and shows a capped thumbnail; tapping opens
/// [ImageViewerPage] with a [Hero] transition for pinch-zoom / save / share.
/// Distinct from the user-side [ImageBubble] (plan/30), which is a static,
/// non-interactive thumbnail.
class AgentImageBubble extends StatefulWidget {
  final AgentImageMsg message;
  const AgentImageBubble(this.message, {super.key});

  /// Cap the thumbnail height; width follows the bubble's 300px max.
  static const double maxHeight = 260;

  @override
  State<AgentImageBubble> createState() => _AgentImageBubbleState();
}

class _AgentImageBubbleState extends State<AgentImageBubble> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _decode(widget.message.image.data);
  }

  @override
  void didUpdateWidget(covariant AgentImageBubble old) {
    super.didUpdateWidget(old);
    if (old.message.image.data != widget.message.image.data) {
      _bytes = _decode(widget.message.image.data);
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

  String get _heroTag => 'agent_image_${widget.message.id}';

  String get _title {
    final caption = widget.message.caption.trim();
    if (caption.isNotEmpty) return caption;
    final p = widget.message.path;
    return (p == null || p.isEmpty) ? 'Image' : p;
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
        pageBuilder: (_, _, _) => ImageViewerPage(
          bytes: bytes,
          heroTag: _heroTag,
          title: widget.message.path ?? _title,
          mime: widget.message.image.mime,
        ),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final bytes = _bytes;
    final colors = context.colors;
    final subtitle = m.path ?? '';
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _open,
              child: Hero(
                tag: _heroTag,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    constraints: const BoxConstraints(
                      maxHeight: AgentImageBubble.maxHeight,
                    ),
                    color: colors.codeBg,
                    child: bytes == null
                        ? _broken(context)
                        : Image.memory(
                            bytes,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => _broken(context),
                          ),
                  ),
                ),
              ),
            ),
            if (m.caption.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 2),
                child: Text(
                  m.caption.trim(),
                  style: context.typo.sansBody.copyWith(color: colors.text),
                ),
              ),
            if (subtitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 2),
                child: Text(
                  subtitle,
                  style: context.typo.sansBody.copyWith(color: colors.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _broken(BuildContext context) {
    return SizedBox(
      height: 120,
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: context.colors.muted,
          size: 28,
        ),
      ),
    );
  }
}
