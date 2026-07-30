import 'dart:typed_data';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

/// Plan/126 - PDF viewer for a `.pdf` file the agent pushed via `show_file`.
/// Uses `pdfx` (native renderers: PDFKit on iOS, PdfRenderer on Android) via a
/// [PdfController] + [PdfView]. Paginated; pinch-to-zoom is handled natively by
/// PdfView. Shows a spinner while the document opens; pdfx renders its own
/// default error for a corrupt/unreadable file.
///
/// NOTE: pdfx 2.x is the approved renderer (plan/126). If `flutter pub get`
/// ever fails to resolve pdfx on a future Flutter, swap this widget for
/// `pdfrx`'s `PdfViewer` (different API) — the rest of the feature is agnostic.
class PdfViewer extends StatefulWidget {
  final Uint8List bytes;

  const PdfViewer({super.key, required this.bytes});

  @override
  State<PdfViewer> createState() => _PdfViewerState();
}

class _PdfViewerState extends State<PdfViewer> {
  late final PdfController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PdfController(
      document: PdfDocument.openData(widget.bytes),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return PdfView(
      controller: _controller,
      backgroundDecoration: BoxDecoration(color: colors.bg),
      pageSnapping: false,
      builders: PdfViewBuilders<DefaultBuilderOptions>(
        options: const DefaultBuilderOptions(),
        documentLoaderBuilder: (_) => Center(
          child: CircularProgressIndicator(
            color: colors.accent,
            strokeWidth: 2,
          ),
        ),
        pageLoaderBuilder: (_) => Center(
          child: CircularProgressIndicator(
            color: colors.muted2,
            strokeWidth: 2,
          ),
        ),
      ),
    );
  }
}
