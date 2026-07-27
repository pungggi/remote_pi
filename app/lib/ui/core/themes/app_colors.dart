import 'package:flutter/material.dart';

/// Semantic color tokens for the whole app.
///
/// This is the SINGLE source of truth for every color used in the UI. Widgets
/// must never hardcode `Color(0x…)` or `Colors.*` — they read from here via
/// `context.colors.<token>` (see `theme_extensions.dart`).
///
/// Registered on [ThemeData.extensions] by `buildDarkTheme()` /
/// `buildLightTheme()` so `Theme.of(context).extension<AppColors>()` resolves
/// the right palette for the active brightness.
///
/// Design tokens originate from `app/wareframe/screens.jsx` (dark). The light
/// palette is a first-pass derivation — tune the hexes here, in one place.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.border,
    required this.text,
    required this.muted,
    required this.muted2,
    required this.accent,
    required this.onAccent,
    required this.highlight,
    required this.success,
    required this.error,
    required this.warning,
    required this.working,
    required this.codeBg,
    required this.userBubble,
    required this.modelBadgeBg,
    required this.modelBadgeBorder,
    required this.denyBorder,
    required this.inputFill,
  });

  /// App background (scaffold). Was `kBg`.
  final Color bg;

  /// Slightly raised surface (cards, sheets). Was `kSurface`.
  final Color surface;

  /// Hairline borders / dividers. Was `kBorder`.
  final Color border;

  /// Primary foreground text. Was `kText`.
  final Color text;

  /// Secondary / de-emphasized text. Was `kMuted`.
  final Color muted;

  /// Tertiary text — slightly more prominent than [muted]. Was `kMuted2`.
  final Color muted2;

  /// Brand accent (links, active states, primary buttons). Was `kAccent`.
  final Color accent;

  /// Foreground painted on top of [accent] (e.g. filled-button label). Was the
  /// hardcoded `Colors.black` / `onPrimary`.
  final Color onAccent;

  /// Code / file paths inside agent messages. Was `kHighlight`.
  final Color highlight;

  /// Success state (✓ tool results). Was `kSuccess`.
  final Color success;

  /// Error / destructive state (✗ tool results, failed sends, delete). Was
  /// `kError` and the scattered `Colors.redAccent`.
  final Color error;

  /// Warning state (relay offline). Was the scattered `Colors.amber`.
  final Color warning;

  /// "Working" / in-progress accent (session running a turn). Was the local
  /// `kWorking` (hardcoded azure) duplicated in session_tile and chat_page.
  final Color working;

  /// Background of inline/he block code. Was `kCodeBg`.
  final Color codeBg;

  /// User chat bubble background. Was `kUserBubble`.
  final Color userBubble;

  /// Model badge background. Was `kModelBadgeBg`.
  final Color modelBadgeBg;

  /// Model badge border. Was `kModelBadgeBorder`.
  final Color modelBadgeBorder;

  /// Border for a denied tool-call card. Was `kDenyBorder`.
  final Color denyBorder;

  /// Text-field fill. Was the hardcoded `Color(0xFF0E0E0E)`.
  final Color inputFill;

  /// Dark palette (default). Mirrors the original `app_theme.dart` constants.
  static const AppColors dark = AppColors(
    bg: Color(0xFF000000),
    surface: Color(0xFF0A0A0A),
    border: Color(0xFF1A1A1A),
    text: Color(0xFFFFFFFF),
    muted: Color(0xFF6B6B6B),
    muted2: Color(0xFF8A8A8A),
    accent: Color(0xFF00FF41),
    onAccent: Color(0xFF000000),
    highlight: Color(0xFF80FFA0),
    success: Color(0xFF6CD28A),
    error: Color(0xFFE5484D),
    warning: Color(0xFFFFB300),
    working: Color(0xFF00E676),
    codeBg: Color(0xFF050505),
    userBubble: Color(0xFF1A1A1A),
    modelBadgeBg: Color(0xFF161616),
    modelBadgeBorder: Color(0xFF1F1F1F),
    denyBorder: Color(0xFF2A2A2A),
    inputFill: Color(0xFF0E0E0E),
  );

  /// Light palette — derived from [dark]. Foreground tints are tuned for
  /// WCAG-AA contrast on the white [bg] (≥4.5:1 for body, ≥3:1 for large/UI):
  /// `muted`/`muted2` are dark grays (not the dark-theme mid-grays, which were
  /// washed out on white), and `accent`/`highlight` are deepened greens so
  /// accent-colored *text* (links, "Use default" buttons) stays legible.
  static const AppColors light = AppColors(
    bg: Color(0xFFFFFFFF),
    surface: Color(0xFFF4F4F5),
    border: Color(0xFFDADADD),
    text: Color(0xFF0A0A0A),
    muted: Color(0xFF565656), // ~7:1 on white (was 0xFF6B6B6B, ~4:1)
    muted2: Color(0xFF424242), // ~9:1 on white
    accent: Color(0xFF00802B), // ~4.6:1 on white — legible as text AND fill
    onAccent: Color(0xFFFFFFFF),
    highlight: Color(0xFF006624), // code/paths — deeper for body contrast
    success: Color(0xFF1E7A41),
    error: Color(0xFFC42026),
    warning: Color(0xFF9A6300),
    working: Color(0xFF1B7A40),
    codeBg: Color(0xFFF0F0F0),
    userBubble: Color(0xFFEAEAEC),
    modelBadgeBg: Color(0xFFEDEDEF),
    modelBadgeBorder: Color(0xFFD7D7DA),
    denyBorder: Color(0xFFC9C9CD),
    inputFill: Color(0xFFF0F0F2),
  );

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? border,
    Color? text,
    Color? muted,
    Color? muted2,
    Color? accent,
    Color? onAccent,
    Color? highlight,
    Color? success,
    Color? error,
    Color? warning,
    Color? working,
    Color? codeBg,
    Color? userBubble,
    Color? modelBadgeBg,
    Color? modelBadgeBorder,
    Color? denyBorder,
    Color? inputFill,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      border: border ?? this.border,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      muted2: muted2 ?? this.muted2,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      highlight: highlight ?? this.highlight,
      success: success ?? this.success,
      error: error ?? this.error,
      warning: warning ?? this.warning,
      working: working ?? this.working,
      codeBg: codeBg ?? this.codeBg,
      userBubble: userBubble ?? this.userBubble,
      modelBadgeBg: modelBadgeBg ?? this.modelBadgeBg,
      modelBadgeBorder: modelBadgeBorder ?? this.modelBadgeBorder,
      denyBorder: denyBorder ?? this.denyBorder,
      inputFill: inputFill ?? this.inputFill,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      border: Color.lerp(border, other.border, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      muted2: Color.lerp(muted2, other.muted2, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      highlight: Color.lerp(highlight, other.highlight, t)!,
      success: Color.lerp(success, other.success, t)!,
      error: Color.lerp(error, other.error, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      working: Color.lerp(working, other.working, t)!,
      codeBg: Color.lerp(codeBg, other.codeBg, t)!,
      userBubble: Color.lerp(userBubble, other.userBubble, t)!,
      modelBadgeBg: Color.lerp(modelBadgeBg, other.modelBadgeBg, t)!,
      modelBadgeBorder: Color.lerp(modelBadgeBorder, other.modelBadgeBorder, t)!,
      denyBorder: Color.lerp(denyBorder, other.denyBorder, t)!,
      inputFill: Color.lerp(inputFill, other.inputFill, t)!,
    );
  }
}
