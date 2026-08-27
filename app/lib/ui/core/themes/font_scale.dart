import 'package:flutter/widgets.dart';

/// Plan 131 (upstream #114) — user font-size preference, applied by
/// composing the ambient [TextScaler] in `MaterialApp.builder`.
///
/// The app's text styles live in [AppTypography], but many one-off sizes
/// reach widgets via `.copyWith(fontSize: …)` (and framework widgets bring
/// their own). Scaling only the typography tokens would leave half the UI
/// unscaled — including Settings itself. A [TextScaler] applies to **every**
/// `Text` in the tree with zero per-widget edits, and composes with the OS
/// accessibility setting instead of replacing it.

/// A [TextScaler] that multiplies any base scaler by a constant [factor].
///
/// Subclassing (rather than `TextScaler.linear(base × factor)`) keeps the
/// base's *shape*: iOS's accessibility text sizes follow a non-linear curve,
/// and flattening it to a linear scale would misrender large-size users.
/// `scale(fontSize) = base.scale(fontSize) * factor` preserves the curve.
class ScaledTextScaler extends TextScaler {
  const ScaledTextScaler(this.base, this.factor);

  /// The ambient (system-derived) scaler being scaled.
  final TextScaler base;

  /// User-selected multiplier (e.g. 0.9 for `UiFontScale.small`).
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  String toString() => 'ScaledTextScaler($base × $factor)';
}

/// Compose the user's font-size [factor] onto [base].
///
/// Returns [base] **untouched** when `factor == 1.0` (the default preset):
/// identity keeps `MediaQueryData` value-equal across rebuilds, so the
/// default preset causes zero extra text relayouts.
TextScaler applyFontScale(TextScaler base, double factor) {
  if (factor == 1.0) return base;
  return ScaledTextScaler(base, factor);
}
