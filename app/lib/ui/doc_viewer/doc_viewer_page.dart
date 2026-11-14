import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/doc_viewer/html_viewer.dart';
import 'package:app/ui/doc_viewer/markdown_viewer.dart';
import 'package:app/ui/doc_viewer/mermaid_viewer.dart';
import 'package:app/ui/doc_viewer/pdf_viewer.dart';
import 'package:app/ui/doc_viewer/text_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';


/// Plan/126 - full-screen viewer for a document the agent pushed from the repo
/// (`show_file` tool). Routes by [kind] to the right sub-viewer (Markdown /
/// text / PDF / HTML+JS / Mermaid, plan/144) and provides common chrome: a top bar (title + close)
/// and a bottom Share action. Swipe down dismisses (photo-app convention).
///
/// Mirrors [ImageViewerPage]'s (plan/114) chrome discipline: SystemUiOverlayStyle
/// follows the theme; the route restores the previous style when popped.
class DocViewerPage extends StatefulWidget {
  final Uint8List bytes;
  final String kind; // markdown | text | pdf | html | mermaid | file
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

  static const _filesChannel = MethodChannel('ch.pungitore.piper/files');

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

  /// Plan/158 — copy the bytes into the user's Downloads via MediaStore
  /// (platform channel; works on any device, no file-manager interaction).
  /// Plan/163 — native returns {name, uri}; the snackbar gains an Open
  /// action that VIEWs the saved file. Tolerates an older native side that
  /// still returns only the display-name string (no Open action then).
  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await _filesChannel.invokeMethod(
        'saveToDownloads',
        {'name': _fileName(), 'mime': _shareMime(), 'bytes': widget.bytes},
      );
      String? name;
      String? uri;
      if (res is Map) {
        name = res['name'] as String?;
        uri = res['uri'] as String?;
      } else if (res is String) {
        name = res;
      }
      final label = 'Saved to Downloads${name == null ? '' : ' · $name'}';
      if (!mounted) return;
      if (uri == null) {
        _toast(label);
        return;
      }
      final openUri = uri; // promoted non-null; captured by the closure below
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(label),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(label: 'Open', onPressed: () => _openSaved(openUri)),
        ),
      );
    } on PlatformException catch (e) {
      _toast(e.message == null || e.message!.isEmpty
          ? 'Save failed'
          : 'Save failed: ${e.message}');
    } catch (_) {
      _toast('Save failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Plan/163 — VIEW the saved Downloads file. `false` means Android found
  /// no handler for the MIME type; say so instead of failing silently.
  Future<void> _openSaved(String uri) async {
    try {
      final ok = await _filesChannel.invokeMethod<bool>(
        'openSavedFile',
        {'uri': uri, 'mime': _shareMime()},
      );
      if (ok == false) _toast('No app can open this file type');
    } on PlatformException catch (e) {
      _toast(e.message == null || e.message!.isEmpty
          ? 'Could not open saved file'
          : 'Open failed: ${e.message}');
    } catch (_) {
      _toast('Could not open saved file');
    }
  }

  String _shareMime() => widget.mime ?? switch (widget.kind) {
        'markdown' => 'text/markdown',
        'text' => 'text/plain',
        'html' => 'text/html',
        'pdf' => 'application/pdf',
        'mermaid' => 'text/vnd.mermaid',
        _ => 'application/octet-stream',
      };

  String _fileName() {
    final t = widget.title.trim();
    String base = 'document';
    if (t.isNotEmpty) {
      final parts = t.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty);
      if (parts.isNotEmpty) base = parts.last;
    }
    String cleaned = base.replaceAll(RegExp(r'[^[0-9A-Za-z_.\-]]'), '_');
    if (cleaned.isEmpty) cleaned = 'document';
    cleaned = cleaned.replaceAll(RegExp(r'\.+$'), '');
    final ext = switch (widget.kind) {
      'markdown' => 'md',
      'text' => 'txt',
      'html' => 'html',
      'pdf' => 'pdf',
      'mermaid' => 'mmd',
      _ => 'bin',
    };
    // Trust the announced name's own suffix when it looks like an extension.
    // Basenames come from the PC filesystem, so any trailing dot + alphanumeric
    // run is kept as-is — the old 1-5 char cap mangled real ones like
    // `.jwlibrary` (9 chars) into `Backup.jwlibrary.bin` (plan/163 follow-up).
    final hasExt = RegExp(r'\.[A-Za-z0-9]{1,32}$').hasMatch(cleaned);
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
      case 'mermaid':
        return MermaidViewer(bytes: widget.bytes);
      case 'file':
        return _BinaryFileBody(
          name: _fileName(),
          bytes: widget.bytes.length,
          mime: _shareMime(),
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
          // Mermaid is exempt (plan/144): this vertical-drag recognizer wins
          // the gesture arena over the WebView and would kill in-viewer
          // panning; the mermaid viewer handles its own gestures.
          onVerticalDragEnd: widget.kind == 'mermaid'
              ? null
              : (details) {
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
              _action(Icons.save_alt, 'Save', _save),
              const SizedBox(width: 24),
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

/// Plan/162 — body for the generic `file` kind: no in-app viewer for
/// arbitrary binaries (.jwlibrary backups, archives, office docs). The page
/// exists for its Save (Downloads via MediaStore) + Share actions; the body
/// just states what arrived so the buttons have context.
class _BinaryFileBody extends StatelessWidget {
  final String name;
  final int bytes;
  final String mime;

  const _BinaryFileBody({
    required this.name,
    required this.bytes,
    required this.mime,
  });

  String get _sizeLabel {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_zip_outlined, size: 56, color: colors.accent),
            const SizedBox(height: 12),
            Text(
              name,
              style: context.typo.sansBody.copyWith(
                color: colors.text,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Text(
              '$_sizeLabel · $mime',
              style: context.typo.monoSmall.copyWith(color: colors.muted),
            ),
            const SizedBox(height: 16),
            Text(
              'No preview for this file type.\n'
              'Use Save (Downloads) or Share below to keep it —\n'
              'e.g. import a .jwlibrary backup into JW Library from Share.',
              style: context.typo.sansBody.copyWith(color: colors.muted2),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
