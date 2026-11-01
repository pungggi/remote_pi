import 'dart:async';

import 'package:app/data/preferences/preferences.dart' show HomeGroupBy;
import 'package:app/protocol/protocol.dart' show PlanUsage;
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
///
/// Plan/156 — in model grouping the header also carries the provider
/// subscription usage (`5h 3% · wk 4%` plus a hairline fill bar), but ONLY
/// when the caller sourced it from an ONLINE session: offline caches would
/// paint stale quota as if it were live.
class SessionGroupHeader extends StatefulWidget {
  final String label;
  final int count;

  /// Plan/156 — provider plan usage; null renders the plain header.
  final PlanUsage? usage;

  const SessionGroupHeader({
    super.key,
    required this.label,
    required this.count,
    this.usage,
  });

  /// PR #89 review — tests pin the countdown's "now" here (widget tests'
  /// fake async advances timers but NOT `DateTime.now()`, so a countdown
  /// test would otherwise be unfalsifiable). Production code never sets it;
  /// null = real wall clock.
  @visibleForTesting
  static int Function()? debugNowMs;

  @override
  State<SessionGroupHeader> createState() => _SessionGroupHeaderState();
}

/// PR #89 review — the "resets 2h 14m" countdown is computed from
/// `resetAt - now`, but a StatelessWidget never rebuilds on its own, so the
/// text would go stale until the next 10-min plan-usage push. This state
/// keeps a 1-min periodic tick — ONLY while a usage with a live countdown
/// is on screen — so the label counts down (and drops the suffix at zero)
/// without any push. Groups without usage pay no timer at all.
class _SessionGroupHeaderState extends State<SessionGroupHeader> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(SessionGroupHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Usage appearing/disappearing (group went offline, provider switch
    // tombstone) must start/stop the tick accordingly.
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    final want = widget.usage?.nearestResetWindow()?.resetAt != null;
    if (want && _ticker == null) {
      _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!want && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  /// Pressure ladder, tuned like plan/147's context fill: <50% is healthy
  /// (accent), ≥50% is "watch it" (warning), ≥80% is "about to throttle"
  /// (error). Alpha stays subtle — the bar is decoration behind a label.
  Color _barTint(AppColors colors, int percent) {
    if (percent >= 80) return colors.error.withValues(alpha: 0.20);
    if (percent >= 50) return colors.warning.withValues(alpha: 0.14);
    return colors.accent.withValues(alpha: 0.10);
  }

  Color _textTint(AppColors colors, int percent) {
    if (percent >= 80) return colors.error;
    if (percent >= 50) return colors.warning;
    return colors.muted;
  }

  static String _resetCountdown(int msLeft) {
    final minutes = (msLeft / 60000).ceil();
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    if (hours < 24) return rest > 0 ? '${hours}h ${rest}m' : '${hours}h';
    final days = hours ~/ 24;
    final restHours = hours % 24;
    return restHours > 0 ? '${days}d ${restHours}h' : '${days}d';
  }

  static String _usageText(PlanUsage usage) {
    final parts = usage.displayWindows
        .map((w) => '${w.label} ${w.percent}%')
        .toList();
    final reset = usage.nearestResetWindow();
    if (reset?.resetAt != null) {
      final nowMs = SessionGroupHeader.debugNowMs?.call() ??
          DateTime.now().millisecondsSinceEpoch;
      final left = reset!.resetAt! - nowMs;
      if (left > 0) parts.add('resets ${_resetCountdown(left)}');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final usage = widget.usage;
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
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
                if (usage != null) ...[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      _usageText(usage),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: kMonoFamily,
                        fontSize: 11,
                        color: _textTint(colors, usage.maxPercent),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                Text(
                  '${widget.count}',
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 11,
                    color: colors.muted,
                  ),
                ),
              ],
            ),
            // Hairline fill bar — width tracks the worst window's percent
            // (400ms ease-out, same language as the plan/147 tile wedge).
            if (usage != null && usage.maxPercent > 0)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRect(
                        child: AnimatedFractionallySizedBox(
                          widthFactor: (usage.maxPercent / 100)
                              .clamp(0.0, 1.0),
                          alignment: Alignment.centerLeft,
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeOutCubic,
                          child: Container(
                            height: 2,
                            color: _barTint(colors, usage.maxPercent),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
