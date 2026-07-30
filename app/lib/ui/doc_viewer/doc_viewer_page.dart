import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/doc_viewer/html_viewer.dart';
import 'package:app/ui/doc_viewer/markdown_viewer.dart';
import 'package:app/ui/doc_viewer/pdf_viewer.dart';
import 'package:app/ui/doc_viewer/text_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';


/// Plan/126 - full-screen viewer for a document the agent pushed from the repo
/// (`show_file` tool). Routes by [kind] to the right sub-viewer (Markdown /
/// text / PDF / HTML+JS) and provides common chrome: a top bar (title + close)
/// and a bottom Share action. Swipe down dismisses (photo-app convention).
///
/// Mirrors [ImageViewerPage]'s (plan/114) chrome discipline: SystemUiOverlayStyle
/// follows the theme; the route restores the previous style when popped.
class DocViewerPage extends StatefulWidget {
  final Uint8List bytes;
  final String kind; // markdown | text | pdf | html
  final String? mime;
  final String title;
  final String caption;
  final bool allowNetwork; // HTML only

  const DocViewerPage({
    super.key,
    required this.bytes,
    required this.kind,
    required this.title,
    this.mime,
    this.caption = '',
    this.allowNetwork = false,
  });

  @override
  State<DocViewerPage> createState() => _DocViewerPageState();
}

class _DocViewerPageState extends State<DocViewerPage> {
  bool _busy = false;

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Share straight from memory (mirrors ImageViewerPage) — no temp file.
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(widget.bytes, mimeType: _shareMime())],
        fileNameOverrides: [_fileName()],
      ));
    } catch (_) {
      _toast('Share failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _shareMime() => widget.mime ?? switch (widget.kind) {
        'markdown' => 'text/markdown',
        'text' => 'text/plain',
        'html' => 'text/html',
        'pdf' => 'application/pdf',
        _ => 'application/octet-stream',
      };

  String _fileName() {
    final t = widget.title.trim();
    String base = 'document';
    if (t.isNotEmpty) {
      final parts = t.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty);
      if (parts.isNotEmpty) base = parts.last;
    }
    String cleaned = base.replaceAll(RegExp(r'[^\w.\-]'), '_');
    if (cleaned.isEmpty) cleaned = 'document';
    final ext = switch (widget.kind) {
      'markdown' => 'md',
      'text' => 'txt',
      'html' => 'html',
      'pdf' => 'pdf',
      _ => 'bin',
    };
    final hasExt = RegExp(r'\.[A-Za-z0-9]{1,5}$').hasMatch(cleaned);
    return hasExt ? cleaned : '$cleaned.$ext';
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Widget _bodyForKind() {
    switch (widget.kind) {
      case 'markdown':
        return MarkdownViewer(bytes: widget.bytes);
      case 'text':
        return TextViewer(bytes: widget.bytes);
      case 'pdf':
        return PdfViewer(bytes: widget.bytes);
      case 'html':
        return HtmlViewer(
          bytes: widget.bytes,
          allowNetwork: widget.allowNetwork,
        );
      default:
        return Center(
          child: Text(
            'Unsupported kind: ${widget.kind}',
            style: context.typo.sansBody.copyWith(color: context.colors.muted),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // System-bar icons follow the theme brightness so they stay legible on both
    // the dark (black) and light (white) scaffold backgrounds (plan/126 #4).
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconBrightness = isDark ? Brightness.light : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: iconBrightness, // Android
        statusBarBrightness: iconBrightness, // iOS (light content = light icons)
        systemNavigationBarColor: colors.bg,
        systemNavigationBarIconBrightness: iconBrightness,
      ),
      child: Scaffold(
        backgroundColor: colors.bg,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          // Swipe down fast -> dismiss (photo-app convention). Use a small
          // threshold so vertical scrolling inside text/markdown still works.
          onVerticalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) > 600) {
              Navigator.of(context).pop();
            }
          },
          child: Column(
            children: [
              _topBar(context),
              Expanded(child: _bodyForKind()),
              _bottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close),
                color: colors.text,
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Text(
                  widget.title,
                  style:
                      context.typo.sansBody.copyWith(color: colors.text),
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

  Widget _bottomBar() {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _action(Icons.ios_share, 'Share', _share),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, Future<void> Function() onTap) {
    final colors = context.colors;
    return InkWell(
      onTap: _busy ? null : onTap,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: colors.text, size: 26),
            const SizedBox(height: 4),
            Text(
              label,
              style: context.typo.sansBody
                  .copyWith(color: colors.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
