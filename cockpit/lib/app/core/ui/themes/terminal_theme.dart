import 'package:flutter/widgets.dart';
import 'package:cockpit/app/core/terminal/xterm/xterm.dart';

/// Tema **dark** do `TerminalView` (fundo `#18181B`, cursor accent verde Matrix,
/// paleta ANSI dark). O fundo e a paleta de 16 cores são do emulador (nossos) —
/// o oh-my-zsh só emite os códigos ANSI do prompt/`ls`; quem pinta é este tema.
/// O `blue`/`brightBlue` ANSI permanecem azuis (cor semântica do terminal); só
/// cursor/selection/search-hit acompanharam o accent verde do produto.
const TerminalTheme cockpitTerminalThemeDark = TerminalTheme(
  cursor: Color(0xFF00FF41), // accent verde Matrix
  selection: Color(0x4000FF41),
  foreground: Color(0xFFECECEF), // text
  background: Color(0xFF18181B), // panel (mesmo fundo do corpo do agente)
  black: Color(0xFF26262A),
  red: Color(0xFFE5484D),
  green: Color(0xFF3FB868),
  yellow: Color(0xFFE0A33A),
  blue: Color(0xFF2F6FF0),
  magenta: Color(0xFFC792EA),
  cyan: Color(0xFF1AA5A0),
  white: Color(0xFFC9C9CF),
  brightBlack: Color(0xFF6A6A73),
  brightRed: Color(0xFFFF6B6F),
  brightGreen: Color(0xFF82E0A5),
  brightYellow: Color(0xFFFFCB6B),
  brightBlue: Color(0xFF82AAFF),
  brightMagenta: Color(0xFFD6A0FF),
  brightCyan: Color(0xFF89DDFF),
  brightWhite: Color(0xFFECECEF),
  searchHitBackground: Color(0xFFE0A33A),
  searchHitBackgroundCurrent: Color(0xFF00FF41),
  searchHitForeground: Color(0xFF0D0D0F),
);

/// Tema **light** do terminal — fundo claro + paleta ANSI escurecida (estilo
/// GitHub light), legível sobre branco. Cores claras (yellow/white) viram tons
/// mais escuros pra não sumirem; prompts do oh-my-zsh ficam legíveis.
const TerminalTheme cockpitTerminalThemeLight = TerminalTheme(
  cursor: Color(0xFF00802B), // accent verde Matrix (profundo, legível no branco)
  selection: Color(0x2200802B),
  foreground: Color(0xFF1A1A1F), // text (dark)
  background: Color(0xFFFFFFFF), // panel (mesmo fundo do corpo do agente)
  black: Color(0xFF1A1A1F),
  red: Color(0xFFCF222E),
  green: Color(0xFF1A7F37),
  yellow: Color(0xFF9A6700),
  blue: Color(0xFF0969DA),
  magenta: Color(0xFF8250DF),
  cyan: Color(0xFF1B7C83),
  white: Color(0xFF6E7781),
  brightBlack: Color(0xFF57606A),
  brightRed: Color(0xFFA40E26),
  brightGreen: Color(0xFF116329),
  brightYellow: Color(0xFF7D4E00),
  brightBlue: Color(0xFF0550AE),
  brightMagenta: Color(0xFF6639BA),
  brightCyan: Color(0xFF3192AA),
  brightWhite: Color(0xFF24292F),
  searchHitBackground: Color(0xFFFFDF5D),
  searchHitBackgroundCurrent: Color(0xFF00802B),
  searchHitForeground: Color(0xFFFFFFFF),
);

/// Tema do terminal conforme o brilho do app.
TerminalTheme cockpitTerminalThemeFor(Brightness brightness) =>
    brightness == Brightness.dark
    ? cockpitTerminalThemeDark
    : cockpitTerminalThemeLight;
