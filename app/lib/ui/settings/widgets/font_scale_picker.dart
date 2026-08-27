import 'package:app/data/preferences/preferences.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Plan 131 (upstream #114) — font-size preset picker (Settings → Display).
///
/// Four presets composed onto the OS text scale in `main.dart`
/// (`applyFontScale`); [Preferences.uiFontScale] is the single source of
/// truth, so the current selection survives here even though the scaling
/// itself happens at the app root.
///
/// Public (and self-contained) so it's widget-testable without pumping the
/// whole SettingsPage with its ViewModel dependencies.
class FontScalePicker extends StatelessWidget {
  const FontScalePicker({super.key});

  static const _labels = <UiFontScale, String>{
    UiFontScale.small: 'Small',
    UiFontScale.normal: 'Default',
    UiFontScale.large: 'Large',
    UiFontScale.extraLarge: 'XL',
  };

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<Preferences>();
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Font size',
            style: context.typo.sansBody.copyWith(color: colors.text),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<UiFontScale>(
              showSelectedIcon: false,
              segments: [
                for (final entry in _labels.entries)
                  ButtonSegment(value: entry.key, label: Text(entry.value)),
              ],
              selected: {prefs.uiFontScale},
              onSelectionChanged: (s) => prefs.setUiFontScale(s.first),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Scales all app text on top of the system accessibility size.',
            style: context.typo.sansBody.copyWith(
              color: colors.muted,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
