import 'dart:io';

/// O que a plataforma consegue oferecer de navegador (plano 58, decisão B).
///
/// - [inline]: webview embutida na árvore de widgets (WKWebView no macOS/iOS,
///   WebView2 no Windows, Android WebView no Android, via flutter_inappwebview)
///   — pane de navegador e preview de markdown/HTML.
/// - [systemBrowser]: sem webview (Linux) — "abrir navegador" delega ao
///   browser do SO via url_launcher e a UI **não** oferece o que não existe
///   (sem botão morto; preview de .md segue no renderer Flutter).
enum BrowserCapability {
  inline,
  systemBrowser;

  /// Inline em todas as plataformas com webview nativa; só o Linux (sem
  /// implementação) degrada pro browser do SO (plano 60).
  static BrowserCapability resolve() =>
      Platform.isLinux ? systemBrowser : inline;

  bool get isInline => this == inline;
}
