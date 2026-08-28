import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/unzoomed_native_view.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

/// Preview de markdown via webview (plano 58) — receita VS Code: markdown-it
/// (GFM + HTML embutido) → DOMPurify → morphdom (diff de DOM, preserva scroll).
/// Tema entra por CSS variables ([_themeVars]); troca de tema re-injeta sem
/// re-render. Imagens relativas do documento passam pelo scheme controlado
/// `ckp-res:`, que só serve arquivos dentro de [workspaceRoot].
class WebMarkdownPreview extends StatefulWidget {
  const WebMarkdownPreview({
    super.key,
    required this.text,
    required this.docDir,
    required this.workspaceRoot,
  });

  final String text;

  /// Diretório do arquivo `.md` — base das imagens relativas.
  final String docDir;

  /// Raiz permitida pro scheme `ckp-res:` (nada fora dela é servido).
  final String workspaceRoot;

  @override
  State<WebMarkdownPreview> createState() => _WebMarkdownPreviewState();
}

class _WebMarkdownPreviewState extends State<WebMarkdownPreview> {
  InAppWebViewController? _web;
  bool _loaded = false;
  String? _html;

  /// Último tema injetado na página, pra não reinjetar igual a cada rebuild.
  Map<String, String>? _pushedTheme;

  /// Página montada uma vez por processo: esqueleto + CSS + os três motores JS
  /// inlined sob nonce (a CSP não deixa a página pedir nada além de imagem).
  static String? _cachedPage;

  static Future<String> _composePage() async {
    final cached = _cachedPage;
    if (cached != null) return cached;
    const base = 'assets/md_preview';
    final results = await Future.wait([
      rootBundle.loadString('$base/preview.html'),
      rootBundle.loadString('$base/preview.css'),
      rootBundle.loadString('$base/markdown-it.min.js'),
      rootBundle.loadString('$base/purify.min.js'),
      rootBundle.loadString('$base/morphdom-umd.min.js'),
      rootBundle.loadString('$base/preview.js'),
    ]);
    final nonce = base64Url.encode(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final page = results[0]
        .replaceAll('__NONCE__', nonce)
        // replaceAll, não replaceFirst: qualquer outra ocorrência do token
        // (um comentário no HTML, por exemplo) roubava a substituição e o
        // <style> ficava com o literal — página sem estilo, fundo branco.
        .replaceAll('__CSS__', results[1])
        .replaceFirst('__JS_MARKDOWN_IT__;', results[2])
        .replaceFirst('__JS_PURIFY__;', results[3])
        .replaceFirst('__JS_MORPHDOM__;', results[4])
        .replaceFirst('__JS_PREVIEW__;', results[5]);
    return _cachedPage = page;
  }

  @override
  void initState() {
    super.initState();
    _composePage().then((page) {
      if (mounted) setState(() => _html = page);
    });
  }

  @override
  void didUpdateWidget(WebMarkdownPreview old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.docDir != widget.docDir) _push();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Troca de tema chega POR AQUI: os parâmetros do widget não mudam, então
    // `didUpdateWidget` não dispara e o preview ficava com as cores do tema
    // anterior até ser reaberto.
    final vars = _themeVars(context);
    if (mapEquals(vars, _pushedTheme)) return;
    _pushedTheme = vars;
    unawaited(_pushTheme(vars));
  }

  /// Só as variáveis de cor — o conteúdo não precisa ser reenviado numa troca
  /// de tema (o CSS reage sozinho às variáveis).
  Future<void> _pushTheme(Map<String, String> vars) async {
    final web = _web;
    if (web == null || !_loaded || !mounted) return;
    await web.evaluateJavascript(
      source: 'window.__cockpit.setTheme(${jsonEncode(vars)});',
    );
  }

  Map<String, String> _themeVars(BuildContext context) {
    final colors = context.colors;
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return {
      '--ckp-bg': hex(colors.panel),
      '--ckp-text': hex(colors.text),
      '--ckp-text-muted': hex(colors.text3),
      '--ckp-border': hex(colors.border),
      '--ckp-code-bg': hex(colors.panel3),
      '--ckp-link': hex(colors.accent),
    };
  }

  Future<void> _push() async {
    final web = _web;
    if (web == null || !_loaded || !mounted) return;
    final vars = _themeVars(context);
    _pushedTheme = vars;
    final theme = jsonEncode(vars);
    final text = jsonEncode(widget.text);
    final dir = jsonEncode(widget.docDir);
    await web.evaluateJavascript(
      source:
          'window.__cockpit.setTheme($theme);'
          'window.__cockpit.setContent($text, $dir);',
    );
  }

  /// Serve `ckp-res://local/<path url-encoded>` — só arquivos dentro do
  /// workspace (path canônico, sem `..` escapando).
  Future<CustomSchemeResponse?> _serveLocal(
    InAppWebViewController web,
    WebResourceRequest request,
  ) async {
    final encoded = request.url.toString().replaceFirst('ckp-res://local/', '');
    final path = Uri.decodeComponent(encoded);
    final root = File(widget.workspaceRoot).absolute.path;
    final file = File(path).absolute;
    final canonical = file.path;
    if (root.isEmpty ||
        !canonical.startsWith('$root${Platform.pathSeparator}')) {
      return null;
    }
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return CustomSchemeResponse(
      data: bytes,
      contentType: _mimeOf(canonical),
      contentEncoding: 'utf-8',
    );
  }

  static String _mimeOf(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'svg' => 'image/svg+xml',
      'bmp' => 'image/bmp',
      'ico' => 'image/x-icon',
      _ => 'application/octet-stream',
    };
  }

  @override
  Widget build(BuildContext context) {
    final html = _html;
    if (html == null) {
      return ColoredBox(color: context.colors.panel);
    }
    // Fora do zoom do app (platform view recebe mouse direto do sistema): sem
    // isso a seleção de texto cai deslocada. Ver [UnzoomedNativeView].
    return UnzoomedNativeView(
      builder: (context, contentZoom) => InAppWebView(
        initialData: InAppWebViewInitialData(data: html),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          resourceCustomSchemes: ['ckp-res'],
          isInspectable: false,
          transparentBackground: true,
          pageZoom: contentZoom,
        ),
        onWebViewCreated: (web) => _web = web,
        onLoadStop: (web, _) {
          _loaded = true;
          _push();
        },
        onLoadResourceWithCustomScheme: _serveLocal,
        // Link clicado abre no browser do SO — o preview não navega pra fora.
        shouldOverrideUrlLoading: (web, action) async {
          final url = action.request.url;
          if (url == null || url.scheme == 'about' || url.scheme == 'data') {
            return NavigationActionPolicy.ALLOW;
          }
          if (url.scheme == 'http' || url.scheme == 'https') {
            await launcher.launchUrl(url);
          }
          return NavigationActionPolicy.CANCEL;
        },
      ),
    );
  }
}

/// Preview de arquivo `.html`/`.htm` (plano 58): carrega o arquivo direto no
/// webview, com leitura restrita à raiz do workspace (recursos relativos
/// funcionam; nada fora da raiz é legível). JS desligado — é um preview de
/// documento, não um runtime.
class WebHtmlPreview extends StatelessWidget {
  const WebHtmlPreview({
    super.key,
    required this.path,
    required this.workspaceRoot,
  });

  final String path;
  final String workspaceRoot;

  @override
  Widget build(BuildContext context) {
    // Mesmo motivo do preview de markdown: platform view fora do zoom do app.
    return UnzoomedNativeView(
      builder: (context, contentZoom) => InAppWebView(
        key: ValueKey('html:$path'),
        initialUrlRequest: URLRequest(url: WebUri.uri(Uri.file(path))),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: false,
          isInspectable: false,
          pageZoom: contentZoom,
          // Leitura restrita à raiz do workspace (loadFileURL:allowingReadAccessTo:).
          allowingReadAccessTo: workspaceRoot.isEmpty
              ? null
              : WebUri.uri(Uri.directory(workspaceRoot)),
        ),
      ),
    );
  }
}
