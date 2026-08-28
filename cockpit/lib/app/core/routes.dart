/// Constantes de path de navegação. Cada feature declara sua rota no seu próprio
/// módulo (`createModule(path: …)`); estes consts só evitam strings mágicas nos
/// call-sites de navegação (`context.pushNamed(RoutePaths.settings)`).
abstract final class RoutePaths {
  static const String shell = '/';
  static const String settings = '/settings';
}

/// Aba inicial da tela de Configurações, passada como `arguments` do
/// `pushNamed(RoutePaths.settings, arguments: SettingsTab.x)`. Público (não o
/// `_Category` interno da página) pra outras features fazerem deep-link — ex.: a
/// `WelcomeView` do mobile manda direto pra "Remote hosts" (chave do device).
enum SettingsTab { remoteHosts }
