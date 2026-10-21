import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Plan/144 - Mermaid diagram viewer for a `.mmd`/`.mermaid` file the agent
/// pushed via `show_file` (kind `mermaid`). Renders the diagram source with a
/// BUNDLED copy of mermaid.js (`assets/mermaid/mermaid.min.js`), inlined into
/// a temp HTML page and loaded in a [WebViewWidget] with JavaScript enabled.
///
/// OFFLINE SANDBOX (mirrors [HtmlViewer]'s plan/126 discipline): the page
/// carries a strict CSP (`default-src 'none'`, `connect-src 'none'`, inline
/// script/style only), so the renderer cannot reach the network and no remote
/// resource is ever fetched — the diagram renders fully offline. Mermaid stays
/// at its default `securityLevel: "strict"`, so diagram labels are sanitized
/// before insertion.
///
/// The diagram theme follows the app brightness (`dark` / `default`) and the
/// page background is transparent so the viewer scaffold shows through.
/// Pan/pinch-zoom is implemented in-page (pointer events + CSS transform)
/// because webview_flutter exposes no native pinch-zoom API.
class MermaidViewer extends StatefulWidget {
  final Uint8List bytes;

  const MermaidViewer({super.key, required this.bytes});

  @override
  State<MermaidViewer> createState() => _MermaidViewerState();
}

class _MermaidViewerState extends State<MermaidViewer> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _loadError;

  /// Temp file written by `_prepare` so the WebView can `loadFile` it. Deleted
  /// in [dispose] (mirrors [HtmlViewer]'s cleanup discipline).
  File? _tempFile;

  /// True once [didChangeDependencies] kicked off `_prepare` (it can fire more
  /// than once; the page must be built exactly once).
  bool _started = false;

  /// The bundled renderer is ~2.7 MB — read it from the asset bundle once per
  /// app run, not once per opened diagram.
  static Future<String>? _mermaidLibFuture;

  /// Strict offline CSP: inline JS + styles + data: images only. The renderer
  /// and bootstrap are inlined into the page, so no external origin is needed.
  static const String _csp =
      "default-src 'none'; "
      "script-src 'unsafe-inline'; "
      "style-src 'unsafe-inline'; "
      "img-src data:; "
      "font-src data:; "
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
      ..addJavaScriptChannel(
        'MermaidNotify',
        onMessageReceived: (msg) {
          // The page posts 'rendered' or 'error:...' after mermaid finishes.
          // Either way the spinner stops; errors are shown in-page.
          if (mounted && _loading) setState(() => _loading = false);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (e) {
            if (e.isForMainFrame == true) {
              setState(() {
                _loading = false;
                _loadError = e.description;
              });
            }
          },
          // Defense-in-depth alongside CSP: only the local temp file itself may
          // load; any navigation attempt (links, window.open) is blocked.
          onNavigationRequest: (req) {
            if (req.url.startsWith('file://') ||
                req.url.startsWith('about:blank')) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
        ),
      );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme brightness needs a context, which initState does not have — build
    // the page here, once.
    if (!_started) {
      _started = true;
      _prepare();
    }
  }

  @override
  void dispose() {
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

  Future<void> _prepare() async {
    // Capture theme + colors BEFORE the first await (the lint
    // use_build_context_synchronously forbids context use across async gaps).
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = context.colors;
    try {
      final source = utf8.decode(widget.bytes, allowMalformed: true);
      final lib = await (_mermaidLibFuture ??= rootBundle.loadString(
        'assets/mermaid/mermaid.min.js',
      ));
      final html = _buildPage(
        lib: lib,
        source: source,
        isDark: isDark,
        textColor: _hex(colors.text),
        errorColor: _hex(colors.error),
        mutedColor: _hex(colors.muted),
      );
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/agent-mmd-${DateTime.now().millisecondsSinceEpoch}.html',
      );
      await file.writeAsString(html);
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

  static String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

  /// Embed a Dart string as a JS string literal. jsonEncode handles quotes and
  /// control chars; `<` is escaped as `\u003c` so a literal `</script>` (or any
  /// tag) inside the diagram source cannot break out of the script block.
  static String _jsString(String value) =>
      jsonEncode(value).replaceAll('<', '\\u003c');

  String _buildPage({
    required String lib,
    required String source,
    required bool isDark,
    required String textColor,
    required String errorColor,
    required String mutedColor,
  }) {
    final theme = isDark ? 'dark' : 'default';
    return '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
<meta http-equiv="Content-Security-Policy" content="$_csp">
<style>
  html, body { margin: 0; padding: 0; background: transparent; height: 100%; overflow: hidden; }
  #stage { position: absolute; inset: 0; overflow: hidden; touch-action: none; }
  #canvas { position: absolute; top: 0; left: 0; transform-origin: 0 0; padding: 16px; }
  #canvas svg { display: block; }
  #err { display: none; position: absolute; inset: 0; padding: 24px; overflow: auto;
         font-family: monospace; font-size: 13px; white-space: pre-wrap; }
  #hint { position: absolute; left: 0; right: 0; bottom: 6px; text-align: center;
          font-family: sans-serif; font-size: 10px; color: $mutedColor; pointer-events: none; }
</style>
</head>
<body>
<div id="stage"><div id="canvas"></div></div>
<div id="err"></div>
<div id="hint">drag to pan · pinch to zoom · double-tap to reset</div>
<script>$lib</script>
<script>
(function () {
  var source = ${_jsString(source)};
  var theme = ${_jsString(theme)};
  var textColor = ${_jsString(textColor)};
  var errorColor = ${_jsString(errorColor)};

  function notify(kind, message) {
    try {
      if (window.MermaidNotify) {
        window.MermaidNotify.postMessage(message ? kind + ':' + message : kind);
      }
    } catch (_) {}
  }
  window.addEventListener('error', function (e) {
    notify('error', String(e.message || e));
    var el = document.getElementById('err');
    el.style.display = 'block';
    el.style.color = errorColor;
    el.textContent = 'Failed to render diagram:\\n' + (e.message || e);
  });

  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    theme: theme,
    themeVariables: { fontFamily: 'system-ui, sans-serif' },
  });

  mermaid.render('mmd-diagram', source).then(function (out) {
    document.getElementById('canvas').innerHTML = out.svg;
    notify('rendered');
  }).catch(function (e) {
    var msg = (e && e.message) ? e.message : String(e);
    var el = document.getElementById('err');
    el.style.display = 'block';
    el.style.color = errorColor;
    el.textContent = 'Mermaid parse error:\\n' + msg;
    // mermaid leaves its error bomb SVG in the DOM on parse failure — remove it.
    var bomb = document.getElementById('dmmd-diagram');
    if (bomb) bomb.remove();
    notify('error', msg);
  });

  // ── Pan / pinch-zoom (webview_flutter has no native pinch API) ──────────
  var stage = document.getElementById('stage');
  var canvas = document.getElementById('canvas');
  var scale = 1, tx = 0, ty = 0;
  var pointers = new Map();
  var lastPinch = 0, moved = false, lastTap = 0;

  function apply() {
    canvas.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
  }
  function reset() { scale = 1; tx = 0; ty = 0; apply(); }
  function pinchDist() {
    var p = Array.from(pointers.values());
    return Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y);
  }
  stage.addEventListener('pointerdown', function (e) {
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    stage.setPointerCapture(e.pointerId);
    if (pointers.size === 2) lastPinch = pinchDist();
    moved = false;
  });
  stage.addEventListener('pointermove', function (e) {
    if (!pointers.has(e.pointerId)) return;
    var prev = pointers.get(e.pointerId);
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 1) {
      tx += e.clientX - prev.x; ty += e.clientY - prev.y;
      moved = true;
    } else if (pointers.size === 2) {
      var d = pinchDist();
      if (lastPinch > 0) {
        scale = Math.min(8, Math.max(0.25, scale * d / lastPinch));
      }
      lastPinch = d;
      moved = true;
    }
    apply();
  });
  function up(e) {
    pointers.delete(e.pointerId);
    if (pointers.size < 2) lastPinch = 0;
    if (!moved) {
      var now = Date.now();
      if (now - lastTap < 300) reset();
      lastTap = now;
    }
  }
  stage.addEventListener('pointerup', up);
  stage.addEventListener('pointercancel', up);
  // Desktop/web parity (harmless on mobile): ctrl+wheel or plain wheel zooms.
  stage.addEventListener('wheel', function (e) {
    e.preventDefault();
    scale = Math.min(8, Math.max(0.25, scale * (e.deltaY < 0 ? 1.15 : 0.87)));
    apply();
  }, { passive: false });
})();
</script>
</body>
</html>''';
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
                'Failed to render diagram:\n$_loadError',
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
        // Offline badge — same trust-signal discipline as the HTML viewer.
        Positioned(
          top: 8,
          right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colors.bg.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.shield_outlined, size: 12, color: colors.muted2),
                const SizedBox(width: 4),
                Text(
                  'mermaid · offline',
                  style: context.typo.monoSmall.copyWith(
                    color: colors.muted2,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
