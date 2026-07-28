import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

/// Plan/114 — full-screen image viewer for images the agent pushes from the
/// repo (`show_image` tool). Pinch-zoom + pan via [InteractiveViewer], tap to
/// toggle the chrome (title bar + actions), swipe-down to dismiss. Save writes
/// the bytes to the system gallery (gal); Share opens the platform share sheet
/// (share_plus). Opens with a [Hero] transition from the chat bubble.
class ImageViewerPage extends StatefulWidget {
  final Uint8List bytes;
  final String heroTag;
  final String title;

  /// MIME of [bytes] (e.g. `image/png`). Drives the Save extension and the
  /// share type. Defaults to PNG.
  final String mime;

  const ImageViewerPage({
    super.key,
    required this.bytes,
    required this.heroTag,
    required this.title,
    this.mime = 'image/png',
  });

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  final TransformationController _controller = TransformationController();
  bool _chromeVisible = true;
  bool _busy = false;
  Offset? _doubleTapPosition;
  bool _zoomed = false;

  @override
  void dispose() {
    _controller.dispose();
    // Restore default system UI on leave (viewer forces light icons on black).
    SystemChrome.setSystemUiOverlayStyle(const SystemUiOverlayStyle());
    super.dispose();
  }

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  static const double _doubleTapScale = 2.5;

  void _onDoubleTapDown(TapDownDetails details) {
    _doubleTapPosition = details.localPosition;
  }

  /// Toggle between 1× and a fixed ~2.5× centered on the last tap point.
  void _onDoubleTap() {
    final pos = _doubleTapPosition;
    if (_zoomed) {
      _controller.value = Matrix4.identity();
      _zoomed = false;
      return;
    }
    final m = Matrix4.identity();
    if (pos != null) {
      m.translate(pos.dx, pos.dy);
      m.scale(_doubleTapScale);
      m.translate(-pos.dx, -pos.dy);
    } else {
      m.scale(_doubleTapScale);
    }
    _controller.value = m;
    _zoomed = true;
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await Gal.putImageBytes(widget.bytes, name: _fileName());
      _toast('Saved to gallery');
    } on GalException catch (_) {
      _toast('Save failed: permission denied');
    } catch (_) {
      _toast('Save failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await Share.shareXFiles(
        [XFile.fromData(widget.bytes, mimeType: widget.mime)],
        fileNameOverrides: [_fileName()],
      );
    } catch (_) {
      _toast('Share failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Derive a filesystem-safe filename from the title (repo path or caption),
  /// using [mime] for the extension when the title lacks one.
  String _fileName() {
    final t = widget.title.trim();
    String base = 'image';
    if (t.isNotEmpty) {
      final parts = t.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
      if (parts.isNotEmpty) base = parts.last;
    }
    String cleaned = base.replaceAll(RegExp(r'[^\w.\-]'), '_');
    if (cleaned.isEmpty) cleaned = 'image';
    final hasExt = RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false)
        .hasMatch(cleaned);
    if (hasExt) return cleaned;
    final ext = switch (widget.mime) {
      'image/jpeg' => 'jpg',
      'image/png' => 'png',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => 'png',
    };
    return '$cleaned.$ext';
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        systemNavigationBarColor: Colors.black,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleChrome,
          onDoubleTapDown: _onDoubleTapDown,
          onDoubleTap: _onDoubleTap,
          // Swipe down fast → dismiss (photo-app convention).
          onVerticalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) > 300) {
              Navigator.of(context).pop();
            }
          },
          child: Stack(
            children: [
              Center(
                child: Hero(
                  tag: widget.heroTag,
                  child: InteractiveViewer(
                    transformationController: _controller,
                    minScale: 1.0,
                    maxScale: 4.5,
                    boundaryMargin: const EdgeInsets.all(double.infinity),
                    clipBehavior: Clip.none,
                    child: Image.memory(
                      widget.bytes,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white54,
                        size: 48,
                      ),
                    ),
                  ),
                ),
              ),
              AnimatedOpacity(
                opacity: _chromeVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: IgnorePointer(
                  ignoring: !_chromeVisible,
                  child: Column(
                    children: [
                      _topBar(context),
                      const Spacer(),
                      _bottomBar(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close),
                color: Colors.white,
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Text(
                  widget.title,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
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
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _action(Icons.download_outlined, 'Save', _save),
              _action(Icons.ios_share, 'Share', _share),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, Future<void> Function() onTap) {
    return InkWell(
      onTap: _busy ? null : onTap,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 26),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
