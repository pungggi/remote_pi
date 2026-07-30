import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Plan/126 - HTML viewer (with JavaScript) for an `.html` file the agent
/// pushed via `show_file`. Renders in a [WebViewWidget] (webview_flutter) with
/// JavaScript ENABLED.
///
/// SANDBOX (the key plan/126 decision): when [allowNetwork] is false (the
/// default) a strict Content-Security-Policy `<meta>` is injected into the
/// document before loading. The CSP allows inline scripts/styles and `data:`
/// images/fonts/media (so self-contained JS — canvas, DOM, local charts —
/// runs), but blocks ALL network: remote scripts/styles/images/fonts,
/// `fetch`/XHR, websockets, iframes, and form/base actions. CSP is enforced by
/// the WebView renderer (works on both WKWebView and Android WebView), so the
/// sandbox holds regardless of the INTERNET permission the app needs for the
/// relay.
///
/// When [allowNetwork] is true the CSP is omitted — remote resources load. A
/// badge in the toolbar warns the user.
class HtmlViewer extends StatefulWidget {
  final Uint8List bytes;

  /// HTML only. When false (default) a no-network CSP is injected; when true
  /// the document can reach the network.
  final bool allowNetwork;

  const HtmlViewer({
    super.key,
    required this.bytes,
    this.allowNetwork = false,
    this.onTitle,
  });

  /// Optional callback fired with the document title after load (reserved for a
  /// future status readout; unused today).
  final void Function(String title)? onTitle;

  @override
  State<HtmlViewer> createState() => _HtmlViewerState();
}

class _HtmlViewerState extends State<HtmlViewer> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _loadError;

  /// Temp file written by `_load` so the WebView can `loadFile` it. Deleted in
  /// [dispose] to avoid accumulating one file per open (plan/126 review #3).
  File? _tempFile;

  /// Strict no-network CSP: inline JS + styles + data: assets only.
  static const String _sandboxCsp =
      "default-src 'none'; "
      "script-src 'unsafe-inline' 'unsafe-eval'; "
      "style-src 'unsafe-inline'; "
      "img-src data: blob:; "
      "font-src data:; "
      "media-src data: blob:; "
      "connect-src 'none'; "
      "base-uri 'none'; "
      "form-action 'none'; "
      "frame-ancestors 'none';";

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (_loading && p >= 100) setState(() => _loading = false);
          },
          onPageFinished: (_) {
            if (_loading) setState(() => _loading = false);
          },
          onWebResourceError: (e) {
            // Non-fatal sub-resource errors are expected in sandbox mode
            // (blocked remote resources). Only surface terminal failures.
            if (e.isForMainFrame == true) {
              setState(() {
                _loading = false;
                _loadError = e.description;
              });
            }
          },
          // Defense-in-depth alongside CSP: when sandboxed, prevent any
          // navigation that leaves the local file (link clicks, iframes,
          // window.open). CSP already blocks the network; this stops the
          // navigation itself from being attempted.
          onNavigationRequest: (req) {
            if (widget.allowNetwork) return NavigationDecision.navigate;
            if (req.url.startsWith('file://') ||
                req.url.startsWith('about:blank') ||
                req.url.startsWith('data:')) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
        ),
      );
    _load();
  }

  @override
  void dispose() {
    // Clean up the temp HTML file we wrote for `loadFile` (best-effort — the
    // WebView has already read it into memory by now).
    final f = _tempFile;
    if (f != null) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // Best-effort; OS temp dir is GC'd anyway.
      }
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final html = utf8.decode(widget.bytes, allowMalformed: true);
      final prepared = widget.allowNetwork ? html : _injectCsp(html);
      // Write to a temp file and loadFile: avoids data:-URL size limits and
      // lets relative `file://` resources (none expected, but harmless)
      // resolve under the document origin the WebView uses for CSP.
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/agent-doc-${DateTime.now().millisecondsSinceEpoch}.html');
      await file.writeAsString(prepared);
      _tempFile = file; // tracked for dispose()-time cleanup
      await _controller.loadFile(file.path);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '$e';
        });
      }
    }
  }

  /// Inject the CSP `<meta>` as the first child of `<head>`; when no head is
  /// present, inject a head after `<html>` or wrap the fragment in a minimal
  /// document. ALWAYS inject when sandboxed (never defer to an authored CSP):
  /// multiple CSPs combine as an intersection (a request must satisfy ALL of
  /// them), so our restrictive policy dominates any permissive one the document
  /// ships — that is exactly what makes the sandbox hold.
  String _injectCsp(String html) {
    final meta =
        '<meta http-equiv="Content-Security-Policy" content="$_sandboxCsp">';
    final headMatch =
        RegExp(r'<head[^>]*>', caseSensitive: false).firstMatch(html);
    if (headMatch != null) {
      return html.replaceRange(headMatch.end, headMatch.end, meta);
    }
    // No <head>: inject a head right after <html> when present...
    final htmlMatch =
        RegExp(r'<html[^>]*>', caseSensitive: false).firstMatch(html);
    if (htmlMatch != null) {
      return html.replaceRange(
          htmlMatch.end, htmlMatch.end, '<head>$meta</head>');
    }
    // ...otherwise wrap the whole fragment in a minimal document.
    return '<!DOCTYPE html><html><head>$meta</head><body>$html</body></html>';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Stack(
      children: [
        if (_loadError != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Failed to render HTML:\n$_loadError',
                style: context.typo.sansBody.copyWith(color: colors.error),
              ),
            ),
          )
        else
          WebViewWidget(controller: _controller),
        if (_loading && _loadError == null)
          Center(
            child: CircularProgressIndicator(
              color: colors.accent,
              strokeWidth: 2,
            ),
          ),
        // Sandbox badge — always visible so the user knows the trust state.
        Positioned(
          top: 8,
          right: 12,
          child: _badge(context),
        ),
      ],
    );
  }

  Widget _badge(BuildContext context) {
    final colors = context.colors;
    final online = widget.allowNetwork;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.bg.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: online ? colors.warning : colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            online ? Icons.cloud_outlined : Icons.shield_outlined,
            size: 12,
            color: online ? colors.warning : colors.muted2,
          ),
          const SizedBox(width: 4),
          Text(
            online ? 'JS · online' : 'JS · sandboxed',
            style: context.typo.monoSmall.copyWith(
              color: online ? colors.warning : colors.muted2,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}
