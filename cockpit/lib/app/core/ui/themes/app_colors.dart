import 'package:flutter/widgets.dart';

/// Tokens de cor do Cockpit — espelham `tokens.css` do design (dark pro-tool,
/// accent verde Matrix (Piper)). Lidos via `context.colors.<token>`.
@immutable
class AppColors {
  const AppColors({
    required this.bg,
    required this.panel,
    required this.panel2,
    required this.panel3,
    required this.border,
    required this.border2,
    required this.text,
    required this.text2,
    required this.text3,
    required this.text4,
    required this.accent,
    required this.accentSoft,
    required this.accentText,
    required this.online,
    required this.ok,
    required this.error,
    required this.warn,
    required this.edited,
    required this.editedBg,
    required this.gitStaged,
    required this.gitUntracked,
    required this.gitDeleted,
    required this.gitConflict,
  });

  final Color bg; // app backdrop, deepest
  final Color panel; // pane / rail surface
  final Color panel2; // raised: composer, cards
  final Color panel3; // hover / inset code
  final Color border; // hairlines
  final Color border2; // stronger divider
  final Color text; // primary
  final Color text2; // secondary
  final Color text3; // tertiary / placeholder
  final Color text4; // faint, icons-at-rest
  final Color accent;
  final Color accentSoft;
  final Color accentText;
  final Color online; // online status (distinct from the Matrix accent)
  final Color ok;
  final Color error;
  final Color warn;
  final Color edited; // recently-edited file accent
  final Color editedBg;

  // Git status (file tree). Modificado reusa [warn] (âmbar, mesma da branch).
  final Color gitStaged; // staged no index → verde
  final Color gitUntracked; // novo / não-rastreado → azul
  final Color gitDeleted; // removido → vermelho
  final Color gitConflict; // conflito de merge → laranja

  static const AppColors dark = AppColors(
    bg: Color(0xFF0D0D0F),
    panel: Color(0xFF18181B),
    panel2: Color(0xFF1F1F23),
    panel3: Color(0xFF27272C),
    border: Color(0xFF26262A),
    border2: Color(0xFF323238),
    text: Color(0xFFECECEF),
    text2: Color(0xFF9B9BA4),
    text3: Color(0xFF6A6A73),
    text4: Color(0xFF46464D),
    accent: Color(0xFF00FF41),
    accentSoft: Color(0x3300FF41),
    accentText: Color(0xFF80FFA0),
    online: Color(0xFF3FB868),
    ok: Color(0xFF3FB868),
    error: Color(0xFFE5484D),
    warn: Color(0xFFE0A33A),
    edited: Color(0xFFC98A2B),
    editedBg: Color(0xFF2A210F),
    gitStaged: Color(0xFF3FB868),
    gitUntracked: Color(0xFF4F9DF0),
    gitDeleted: Color(0xFFE5484D),
    gitConflict: Color(0xFFF0883E),
  );

  /// Variante light — mesmos papéis, luminância invertida; accent azul mantido.
  static const AppColors light = AppColors(
    bg: Color(0xFFF5F5F7),
    panel: Color(0xFFFFFFFF),
    panel2: Color(0xFFF0F0F3),
    panel3: Color(0xFFE7E7EC),
    border: Color(0xFFE2E2E7),
    border2: Color(0xFFD1D1D8),
    text: Color(0xFF1A1A1F),
    text2: Color(0xFF5B5B66),
    text3: Color(0xFF8A8A94),
    text4: Color(0xFFB4B4BC),
    accent: Color(0xFF00802B),
    accentSoft: Color(0x2200802B),
    accentText: Color(0xFF006624),
    online: Color(0xFF2E9E54),
    ok: Color(0xFF2E9E54),
    error: Color(0xFFD32F2F),
    warn: Color(0xFFB7791F),
    edited: Color(0xFFB7791F),
    editedBg: Color(0xFFFBF1DC),
    gitStaged: Color(0xFF2E9E54),
    gitUntracked: Color(0xFF2F6FF0),
    gitDeleted: Color(0xFFD32F2F),
    gitConflict: Color(0xFFD9730D),
  );

  AppColors copyWith({
    Color? bg,
    Color? panel,
    Color? panel2,
    Color? panel3,
    Color? border,
    Color? border2,
    Color? text,
    Color? text2,
    Color? text3,
    Color? text4,
    Color? accent,
    Color? accentSoft,
    Color? accentText,
    Color? online,
    Color? ok,
    Color? error,
    Color? warn,
    Color? edited,
    Color? editedBg,
    Color? gitStaged,
    Color? gitUntracked,
    Color? gitDeleted,
    Color? gitConflict,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      panel: panel ?? this.panel,
      panel2: panel2 ?? this.panel2,
      panel3: panel3 ?? this.panel3,
      border: border ?? this.border,
      border2: border2 ?? this.border2,
      text: text ?? this.text,
      text2: text2 ?? this.text2,
      text3: text3 ?? this.text3,
      text4: text4 ?? this.text4,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      accentText: accentText ?? this.accentText,
      online: online ?? this.online,
      ok: ok ?? this.ok,
      error: error ?? this.error,
      warn: warn ?? this.warn,
      edited: edited ?? this.edited,
      editedBg: editedBg ?? this.editedBg,
      gitStaged: gitStaged ?? this.gitStaged,
      gitUntracked: gitUntracked ?? this.gitUntracked,
      gitDeleted: gitDeleted ?? this.gitDeleted,
      gitConflict: gitConflict ?? this.gitConflict,
    );
  }
}
