import 'dart:convert';
import 'dart:typed_data';

import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/doc_viewer/doc_viewer_page.dart';
import 'package:flutter/material.dart';

/// Plan/126 - left-aligned, tappable card for an [AgentFileMsg]. Decodes the
/// inline base64 once and shows an icon + filename + a small preview / sandbox
/// badge; tapping opens [DocViewerPage], which routes by [kind] to the right
/// viewer. Distinct from [AgentImageBubble] (plan/114).
///
/// Plan/158 — metadata-only refs render the same card WITHOUT bytes: tapping
/// (or saving/sharing) first pulls the content from the Pi through [fetcher]
/// (chunked `agent_file_fetch` unicast), with inline progress. Typed failures
/// drive the card states:
/// - **gone**: the file no longer exists on the Pi → inert error card.
/// - **changed**: the file moved since the ref was pushed → tap fetches the
///   current version.
/// - **transient** (timeout, busy, offline): tap retries.
class AgentFileBubble extends StatefulWidget {
  final AgentFileMsg message;

  /// Plan/158 — the chunked fetch loop (ChatViewModel pass-through). Null on
  /// surfaces without a live SyncService (transcript golden tests): refs then
  /// degrade to a static "unavailable" card instead of crashing.
  final Future<Uint8List> Function(
    String fileId, {
    void Function(int received, int total)? onProgress,
  })? fetcher;

  const AgentFileBubble(this.message, {super.key, this.fetcher});

  @override
  State<AgentFileBubble> createState() => _AgentFileBubbleState();
}

class _AgentFileBubbleState extends State<AgentFileBubble> {
  Uint8List? _bytes;
  bool _fetching = false;
  int? _received;
  int? _total;
  AgentFileFetchException? _error;

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

  static Uint8List? _decode(String? data) {
    if (data == null || data.isEmpty) return null;
    try {
      final b = base64Decode(data);
      return b.isEmpty ? null : b;
    } catch (_) {
      return null;
    }
  }

  bool get _isRef => widget.message.data == null || widget.message.data!.isEmpty;

  String get _title {
    final caption = widget.message.caption.trim();
    if (caption.isNotEmpty) return caption;
    return _displayName() ?? _defaultName();
  }

  /// Plan/158 — refs announce a basename; legacy inline pushes carry a repo
  /// path. Either may be absent.
  String? _displayName() {
    final n = widget.message.name;
    if (n != null && n.isNotEmpty) return n;
    final p = widget.message.path;
    if (p == null || p.isEmpty) return null;
    return p;
  }

  String _defaultName() => switch (widget.message.kind) {
        'markdown' => 'Markdown',
        'text' => 'Text file',
        'pdf' => 'PDF document',
        'html' => 'HTML page',
        'mermaid' => 'Mermaid diagram',
        _ => 'Document',
      };

  /// Basename of the announced name / repo path, for display.
  String get _filename {
    final base = _displayName();
    if (base == null || base.isEmpty) return _defaultName();
    final parts = base.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty);
    return parts.isEmpty ? base : parts.last;
  }

  IconData get _icon => switch (widget.message.kind) {
        'markdown' => Icons.description_outlined,
        'text' => Icons.article_outlined,
        'pdf' => Icons.picture_as_pdf_outlined,
        'html' => Icons.code_outlined,
        'mermaid' => Icons.account_tree_outlined,
        _ => Icons.drafts_outlined,
      };

  String? get _previewText {
    // Mermaid is text-y too: preview the diagram source's first lines.
    if (widget.message.kind != 'markdown' &&
        widget.message.kind != 'text' &&
        widget.message.kind != 'mermaid') {
      return null;
    }
    final bytes = _bytes;
    if (bytes == null) return null;
    final decoded = utf8.decode(bytes, allowMalformed: true);
    final lines = decoded.split(RegExp(r'\r?\n')).take(3).join('  ').trim();
    if (decoded.isEmpty || lines.isEmpty) return null;
    return lines.length > 140 ? '${lines.substring(0, 140)}…' : lines;
  }

  String? get _sizeLabel {
    // Prefer the locally-known truth; refs carry the Pi's declared size.
    final bytes = _bytes?.length ?? widget.message.bytes;
    if (bytes == null || bytes <= 0) return null;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ---------------------------------------------------------------------------
  // Plan/158 — tap handling: open, or fetch-then-open.
  // ---------------------------------------------------------------------------

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
          title: _displayName() ?? _title,
          caption: widget.message.caption,
          allowNetwork: widget.message.allowNetwork,
        ),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  Future<void> _fetchAndOpen() async {
    final fetcher = widget.fetcher;
    final fileId = widget.message.fileId;
    if (fetcher == null || fileId == null || _fetching) return;
    setState(() {
      _fetching = true;
      _error = null;
      _received = 0;
      _total = widget.message.bytes;
    });
    try {
      final bytes = await fetcher(
        fileId,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _fetching = false;
      });
      _open();
    } on AgentFileFetchException catch (e) {
      if (!mounted) return;
      setState(() {
        _fetching = false;
        _error = e;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _fetching = false;
        _error = AgentFileUnavailableException();
      });
    }
  }

  void _onTap() {
    if (_bytes != null) {
      _open();
      return;
    }
    if (_error is AgentFileChangedException ||
        _error is AgentFileUnavailableException) {
      // Changed on the Pi → fetch the current version; transient failure →
      // plain retry. Both re-run the same chunked loop.
      _fetchAndOpen();
      return;
    }
    if (_error is AgentFileGoneException) return; // inert card
    _fetchAndOpen();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final m = widget.message;

    // Plan/158 — a ref whose bytes could not be fetched: typed card states.
    final error = _error;
    if (_bytes == null && error != null && !_fetching) {
      final gone = error is AgentFileGoneException;
      final changed = error is AgentFileChangedException;
      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: GestureDetector(
            // gone: inert. changed/transient: tap refetches.
            onTap: gone ? null : _onTap,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: gone ? colors.error : colors.warning),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        gone ? Icons.folder_off_outlined : Icons.sync_problem_outlined,
                        color: gone ? colors.error : colors.warning,
                        size: 20,
                      ),
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
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    gone
                        ? 'No longer on the Pi'
                        : changed
                            ? 'Changed on the Pi · tap for current version'
                            : "Couldn't fetch · tap to retry",
                    style: context.typo.monoSmall.copyWith(
                      color: gone ? colors.error : colors.warning,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Plan/158 — legacy inline card whose base64 failed to decode: explicit
    // error card instead of a normal card that silently no-ops on tap.
    if (_bytes == null && !_isRef && !_fetching) {
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
                    "Couldn't decode this file",
                    style: context.typo.sansBody.copyWith(color: colors.text),
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

    final busy = _fetching;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: GestureDetector(
          onTap: busy ? null : _onTap,
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
                    if (busy)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (_bytes == null)
                      Icon(Icons.download_outlined, color: colors.muted, size: 18)
                    else
                      Icon(Icons.chevron_right, color: colors.muted, size: 18),
                  ],
                ),
                if (busy) ...[
                  const SizedBox(height: 6),
                  _progressRow(colors),
                ] else if (_previewText != null) ...[
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
                      style: context.typo.sansBody.copyWith(color: colors.text),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _progressRow(AppColors colors) {
    final received = _received ?? 0;
    final total = _total ?? 0;
    final label = total > 0
        ? 'Receiving… ${(received * 100 / total).clamp(0, 100).toStringAsFixed(0)}%'
        : 'Receiving…';
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: total > 0 ? (received / total).clamp(0.0, 1.0) : null,
              minHeight: 3,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: context.typo.monoSmall.copyWith(color: colors.muted, fontSize: 10),
        ),
      ],
    );
  }

  Widget _metaRow(AppColors colors) {
    final kindLabel = switch (widget.message.kind) {
      'markdown' => 'Markdown',
      'text' => 'Text',
      'pdf' => 'PDF',
      'html' => 'HTML',
      'mermaid' => 'Mermaid',
      _ => widget.message.kind,
    };
    final children = <Widget>[
      _pill(kindLabel, colors),
    ];
    if (_isRef && _bytes == null && !_fetching) {
      // Plan/158 — ref not yet fetched: show the declared size + a hint.
      final size = _sizeLabel;
      if (size != null) children.add(_pill(size, colors));
      children.add(_pill('tap to download', colors));
    }
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
