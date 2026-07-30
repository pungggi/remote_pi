/// Centralized GoRouter path constants (see `routing/CLAUDE.md`).
///
/// Navigation call sites and [GoRoute.path] declarations must use these —
/// never invent a new string literal for a route that already lives here.
abstract final class RoutePaths {
  static const boot = '/boot';
  static const syncRequired = '/sync-required';
  static const home = '/home';
  static const session = '/session';
  static const pair = '/pair';
  static const onboarding = '/onboarding';
  static const chat = '/chat';
  static const settings = '/settings';
  static const settingsReliability = '/settings/reliability';
  /// Plan/121 — discovered git projects (spawn worktree from phone).
  static const projects = '/projects';
}
