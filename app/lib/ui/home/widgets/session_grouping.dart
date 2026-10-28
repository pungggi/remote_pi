import 'package:app/data/preferences/preferences.dart' show HomeGroupBy;
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Two-way control that switches the Home list between model and repository
/// sections. The selected mode is announced by [SegmentedButton] semantics.
class HomeGroupingControl extends StatelessWidget {
  final HomeGroupBy value;
  final ValueChanged<HomeGroupBy> onChanged;

  const HomeGroupingControl({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'GROUP BY',
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 11,
              color: colors.muted,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<HomeGroupBy>(
              segments: const [
                ButtonSegment(value: HomeGroupBy.model, label: Text('Model')),
                ButtonSegment(
                  value: HomeGroupBy.repository,
                  label: Text('Repo'),
                ),
              ],
              selected: {value},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => onChanged(selection.first),
              style: ButtonStyle(
                minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? colors.surface
                      : colors.bg,
                ),
                foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? colors.text
                      : colors.muted,
                ),
                side: WidgetStatePropertyAll(BorderSide(color: colors.border)),
                textStyle: const WidgetStatePropertyAll(
                  TextStyle(fontFamily: kMonoFamily, fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Label and session count for one model or repository section.
class SessionGroupHeader extends StatelessWidget {
  final String label;
  final int count;

  const SessionGroupHeader({
    super.key,
    required this.label,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 12,
                  color: colors.muted2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$count',
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 11,
                color: colors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
