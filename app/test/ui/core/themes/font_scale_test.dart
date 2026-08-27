import 'package:app/ui/core/themes/font_scale.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A deliberately non-linear scaler, mimicking how iOS's accessibility text
/// sizes curve upward past the "large" breakpoints.
class _AccessibilityCurveScaler extends TextScaler {
  const _AccessibilityCurveScaler();

  @override
  double scale(double fontSize) =>
      fontSize <= 14 ? fontSize : fontSize * (1 + (fontSize - 14) / 20);

  @override
  double get textScaleFactor => 1.0;
}

void main() {
  group('applyFontScale (plan 131)', () {
    test('identity: factor 1.0 returns the base scaler untouched', () {
      final base = TextScaler.linear(1.3);
      expect(applyFontScale(base, 1.0), same(base));
      expect(applyFontScale(TextScaler.noScaling, 1.0),
          same(TextScaler.noScaling));
    });

    test('composes linearly onto a linear base', () {
      // mono 12.5 × 1.15 (large)
      expect(
        applyFontScale(TextScaler.noScaling, 1.15).scale(12.5),
        closeTo(14.375, 1e-9),
      );
      // monoSmall 11 × 0.9 (small)
      expect(
        applyFontScale(TextScaler.noScaling, 0.9).scale(11),
        closeTo(9.9, 1e-9),
      );
      // sansBody 14 × 1.3 (XL)
      expect(
        applyFontScale(TextScaler.noScaling, 1.3).scale(14),
        closeTo(18.2, 1e-9),
      );
    });

    test('multiplies on top of a non-1.0 system scale (composition)', () {
      // System setting 1.3× × user preset 1.15× → 14.95×… i.e. multiplies.
      final scaled = applyFontScale(TextScaler.linear(1.3), 1.15);
      expect(scaled.scale(10), closeTo(10 * 1.3 * 1.15, 1e-9));
    });

    test('preserves a non-linear accessibility curve', () {
      final base = const _AccessibilityCurveScaler();
      final scaled = applyFontScale(base, 1.15);
      for (final fs in [8.0, 11.0, 14.0, 18.0, 24.0]) {
        expect(scaled.scale(fs), closeTo(base.scale(fs) * 1.15, 1e-9));
      }
      // The curve really is non-linear: doubling fontSize more-than-doubles
      // the scaled size past the breakpoint.
      expect(base.scale(24), greaterThan(base.scale(12) * 2));
    });
  });

  group('ScaledTextScaler', () {
    test('scale multiplies the base at every input', () {
      const scaler = ScaledTextScaler(TextScaler.linear(2.0), 1.3);
      for (final fs in [1.0, 10.0, 12.5, 100.0]) {
        expect(scaler.scale(fs), closeTo(fs * 2.0 * 1.3, 1e-9));
      }
    });

    test('toString mentions base and factor (debuggability)', () {
      const scaler = ScaledTextScaler(TextScaler.noScaling, 1.15);
      expect(scaler.toString(), contains('1.15'));
    });
  });
}
