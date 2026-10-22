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
/// Gesture model (plan/144 fix): ALL motion gestures are tracked on the
/// Flutter side by a raw [Listener] around the WebView — the TLHC platform
/// view loses the gesture arena to surrounding detectors, so touchmove
/// streams are unreliable inside the page. The Listener drives pan
/// (window.mmdPan) and pinch (window.mmdZoom with a focal point) via
/// runJavaScript; the page itself handles only double-tap (touchend) and
/// desktop wheel. Zoom buttons (＋/－/fit) call the same entry points, so
/// zooming always works even where gestures cannot.
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

  /// Brightness the current page was rendered for. When the platform theme
  /// flips while the viewer is open (ThemeMode.system), the page is rebuilt
  /// with the new theme so SVG labels stay readable on the transparent
  /// WebView (review finding: stale theme on live brightness change).
  Brightness? _renderedFor;

  /// Locates the WebView's render box to convert screen-global pointer
  /// positions into WebView-local CSS px (the zoom focal point's frame).
  final GlobalKey _webViewKey = GlobalKey();

  /// Active pointers for the Flutter-side pinch bridge (plan/144 fix): the
  /// TLHC platform view does not deliver a second finger to the page, so a
  /// [Listener] around the [WebViewWidget] measures the pinch and drives the
  /// in-page zoom via runJavaScript. [__pinchDist] is null when idle.
  final Map<int, Offset> _pinchPointers = {};
  double? _pinchDist;

  /// Accumulated single-finger pan delta since the last mmdPan eval (the JS
  /// bridge is only hit every ~2px so slow drags don't spam platform calls).
  Offset _panAcc = Offset.zero;

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
          // The page posts 'rendered'/'error:...' after mermaid finishes and
          // 'gesture:...' for zoom diagnostics. Everything is echoed to logcat
          // (debugPrint) so device tests can follow the gesture lifecycle.
          debugPrint('[mmd] ${msg.message}');
          if (mounted && _loading) {
            final kind = msg.message.split(':').first;
            if (kind == 'rendered' || kind == 'error') {
              setState(() => _loading = false);
            }
          }
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
    // Theme brightness needs a context, which initState does not have. The
    // first call builds the page; a LATER call with a different brightness
    // (system theme flip while the viewer is open) rebuilds it themed.
    final brightness = Theme.of(context).brightness;
    if (_renderedFor == brightness) return;
    final firstBuild = _renderedFor == null;
    _renderedFor = brightness;
    _prepare(reload: !firstBuild);
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

  Future<void> _prepare({bool reload = false}) async {
    // Capture theme + colors BEFORE the first await (the lint
    // use_build_context_synchronously forbids context use across async gaps).
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = context.colors;
    if (reload) {
      // Theme flip while open: spin again and drop the old temp page so
      // dispose() tracks exactly the newest file.
      final old = _tempFile;
      if (old != null) {
        try {
          if (old.existsSync()) old.deleteSync();
        } catch (_) {}
        _tempFile = null;
      }
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
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
<div id="hint">drag = pan · pinch = zoom · double-tap = zoom / fit</div>
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
    // Align the renderer's text budget with the 1 MiB wire cap: the default
    // 50k chars rejects files show_file already accepted (review finding).
    maxTextSize: 1048576,
  });

  mermaid.render('mmd-diagram', source).then(function (out) {
    document.getElementById('canvas').innerHTML = out.svg;
    fitCenter();
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

  // ── Pan / pinch-zoom ──────────────────────────────────────────────────
  // Touch path uses touch events — the most reliable event stream inside
  // an Android WebView; pointer events handle mouse-pan + wheel (desktop).
  // If the platform view swallows multi-touch entirely, the Flutter-side
  // zoom buttons still work: they call window.mmdZoom/mmdReset.
  var stage = document.getElementById('stage');
  var canvas = document.getElementById('canvas');
  var MIN_S = 0.25, MAX_S = 8;
  var scale = 1, tx = 0, ty = 0;
  function clampS(s) { return Math.min(MAX_S, Math.max(MIN_S, s)); }
  function apply() {
    canvas.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
  }
  // Reset state: scale 1, content centered when smaller than the viewport,
  // top/left-aligned when larger (reading order for diagrams).
  function fitCenter() {
    var r = canvas.getBoundingClientRect();
    var w = r.width / scale, h = r.height / scale; // untransformed size
    scale = 1;
    tx = w <= window.innerWidth ? (window.innerWidth - w) / 2 : 0;
    ty = h <= window.innerHeight ? (window.innerHeight - h) / 2 : 0;
    apply(); notifyGesture('fit');
  }
  function notifyGesture(what) { notify('gesture', what + ' scale=' + scale.toFixed(2)); }

  // extPinch: true while a Flutter-side pinch bridge drives the zoom (the
  // TLHC platform view never delivers finger 2 to the page, so a Flutter
  // Listener detects the pinch and calls mmdZoom/mmdPinch from Dart).
  var extPinch = false;
  window.mmdPinch = function (on) { extPinch = on; };

  // Pan by (dx, dy) viewport px — driven by the Flutter Listener.
  window.mmdPan = function (dx, dy) { tx += dx; ty += dy; apply(); };

  // Zoom by factor f around (cx, cy) in viewport px.
  function zoomAt(f, cx, cy) {
    var ns = clampS(scale * f);
    var applied = ns / scale;
    scale = ns;
    tx = cx - (cx - tx) * applied;
    ty = cy - (cy - ty) * applied;
    apply(); notifyGesture('zoom');
  }
  window.mmdZoom = function (f, cx, cy) {
    if (typeof cx !== 'number') cx = window.innerWidth / 2;
    if (typeof cy !== 'number') cy = window.innerHeight / 2;
    zoomAt(f, cx, cy);
  };
  window.mmdReset = function () { fitCenter(); };

  function tDist(t) {
    return Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY);
  }

  // Touch tracking in-page is limited to tap detection (double-tap): motion
  // streams (touchmove) are unreliable under TLHC — an ancestor gesture
  // detector can win the arena and the stream is cancelled. Pan and pinch
  // therefore live on the Flutter side (Listener → mmdPan / mmdZoom).
  var moved = false, lastTap = 0, lastTapPos = null, downPos = null;
  stage.addEventListener('touchstart', function (e) {
    e.preventDefault();
    moved = false;
    if (e.touches.length === 1) {
      downPos = { x: e.touches[0].clientX, y: e.touches[0].clientY };
    } else if (e.touches.length === 2) {
      downPos = null;
      notifyGesture('pinch-start');
    }
  }, { passive: false });
  stage.addEventListener('touchmove', function (e) {
    e.preventDefault();
    // Count as a drag once the finger travelled past a small slop, so a
    // sloppy tap still counts towards double-tap but a drag does not.
    if (e.touches.length === 1 && downPos) {
      var t = e.touches[0];
      if (Math.hypot(t.clientX - downPos.x, t.clientY - downPos.y) > 8) moved = true;
    } else if (e.touches.length === 2) {
      moved = true;
    }
  }, { passive: false });
  function tEnd(e) {
    if (e.touches.length > 0) return;
    if (!moved) {
      var t = e.changedTouches[0];
      var pos = t ? { x: t.clientX, y: t.clientY } : lastTapPos;
      var now = Date.now();
      if (now - lastTap < 350 && lastTapPos && pos) {
        // Double-tap: zoomed in → back to fit; at fit → 2.5x around the tap.
        if (scale > 1.05) { fitCenter(); }
        else { zoomAt(2.5, pos.x, pos.y); }
      }
      lastTap = now; lastTapPos = pos;
    }
  }
  stage.addEventListener('touchend', tEnd, { passive: false });
  // A cancelled stream (gesture-arena steal) must never count as a tap: mark
  // the sequence as moved and forget the last tap position (review finding).
  stage.addEventListener('touchcancel', function () {
    moved = true;
    downPos = null;
    lastTapPos = null;
  }, { passive: false });

  // Mouse drags pan through the same Flutter bridge (single code path — a
  // page-side mouse pan would apply the delta twice, review finding).
  // Desktop/web parity for zoom stays in-page: wheel.
  stage.addEventListener('wheel', function (e) {
    e.preventDefault();
    scale = clampS(scale * (e.deltaY < 0 ? 1.15 : 0.87));
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
          _pinchBridge(
            WebViewWidget(key: _webViewKey, controller: _controller),
          ),
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
        // Zoom controls (plan/144 fix): the Android platform view may not
        // deliver multi-touch to the page, so these buttons drive the same
        // in-page transform via runJavaScript — zoom always works.
        if (_loadError == null)
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ZoomBtn(Icons.add, () => _zoom(1.3)),
                  const SizedBox(height: 8),
                  _ZoomBtn(Icons.remove, () => _zoom(1 / 1.3)),
                  const SizedBox(height: 8),
                  _ZoomBtn(Icons.filter_center_focus_outlined, _reset),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Raw-pointer wrapper around the WebView. A [Listener] (unlike a
  /// GestureDetector) observes every pointer regardless of the gesture
  /// arena, so finger 2 — which the TLHC platform view never forwards to the
  /// page — still reaches Dart and drives the pinch zoom.
  Widget _pinchBridge(Widget child) => Listener(
        onPointerDown: _onPinchPointer,
        onPointerMove: _onPinchPointer,
        onPointerUp: _onPinchPointerEnd,
        onPointerCancel: _onPinchPointerEnd,
        child: child,
      );

  /// Screen-global → WebView-local. Null before the first layout.
  Offset? _webViewLocal(Offset global) {
    final ro = _webViewKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.hasSize) return ro.globalToLocal(global);
    return null;
  }

  void _onPinchPointer(PointerEvent e) {
    // Local coordinates: the page's zoom focal point is in viewport CSS px
    // while PointerEvent.position is screen-global — global coords would
    // drift the pinch center by the top-bar offset (review finding). Pan
    // deltas are offset-invariant; one normalized path serves both.
    final local = _webViewLocal(e.position);
    if (local == null) return;
    final prev = _pinchPointers[e.pointer];
    _pinchPointers[e.pointer] = local;
    // Single-pointer motion pans — but only outside an active pinch. The
    // stored position keeps updating during a pinch, so handing back to one
    // finger continues the pan without a jump.
    if (e is PointerMoveEvent &&
        _pinchPointers.length == 1 &&
        _pinchDist == null &&
        prev != null) {
      _panAcc += e.position - prev;
      if (_panAcc.dx.abs() + _panAcc.dy.abs() >= 2) {
        _eval(
          'window.mmdPan && window.mmdPan('
          '${_panAcc.dx.toStringAsFixed(1)}, ${_panAcc.dy.toStringAsFixed(1)});',
        );
        _panAcc = Offset.zero;
      }
    }
    _updatePinch();
  }

  void _onPinchPointerEnd(PointerEvent e) {
    _pinchPointers.remove(e.pointer);
    _updatePinch();
  }

  void _updatePinch() {
    if (_pinchPointers.length != 2) {
      if (_pinchDist != null) {
        // Pinch ended (a finger lifted or a third joined): unfreeze page pan.
        _eval('window.mmdPinch && window.mmdPinch(false);');
        _pinchDist = null;
      }
      return;
    }
    final pts = _pinchPointers.values.toList();
    final d = (pts[0] - pts[1]).distance;
    final last = _pinchDist;
    if (last == null) {
      // Pinch begins: freeze the page's own single-finger pan so finger 1's
      // moves don't fight the zoom.
      _eval('window.mmdPinch && window.mmdPinch(true);');
      _pinchDist = d;
      return;
    }
    // Only eval when the distance moved meaningfully (~0.5%) — keeps the JS
    // bridge quiet while still feeling continuous.
    if (last > 0 && (d / last - 1).abs() > 0.005) {
      final mid = Offset(
        (pts[0].dx + pts[1].dx) / 2,
        (pts[0].dy + pts[1].dy) / 2,
      );
      _eval(
        'window.mmdZoom && window.mmdZoom('
        '${(d / last).toStringAsFixed(4)}, '
        '${mid.dx.toStringAsFixed(1)}, ${mid.dy.toStringAsFixed(1)});',
      );
      _pinchDist = d;
    }
  }

  /// Best-effort JS eval: the page may not be ready yet; a rejected future
  /// is ignored rather than surfacing an error (the next tap retries).
  void _eval(String js) {
    _controller.runJavaScript(js).catchError((Object _) {});
  }

  void _zoom(double factor) =>
      _eval('window.mmdZoom && window.mmdZoom($factor);');
  void _reset() => _eval('window.mmdReset && window.mmdReset();');
}

class _ZoomBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ZoomBtn(this.icon, this.onTap);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.bg.withValues(alpha: 0.7),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: colors.text),
        ),
      ),
    );
  }
}
