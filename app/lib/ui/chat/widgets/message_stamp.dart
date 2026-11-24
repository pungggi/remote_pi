import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Plan/172 — clock stamps for chat rows.
//
// One formatter for every stamp in the transcript (user bubble, assistant
// reply, expanded tool card), so a row always reads the same way:
//
//   last 7 days   Tue 14:03:12
//   older, 2026   Tue 24 Nov 14:03:12
//   other year    Tue 24 Nov 2025 14:03:12
//
// Local time, English weekday abbreviations, no `intl` dependency (same
// choice as the plan-usage reset label). The day is part of the stamp by
// owner request: a Pi session lives for weeks, so a bare clock time is
// ambiguous the moment the user scrolls up.
//
// The formatters are pure ([now] is injectable) so they are unit-testable
// without a widget tree or a fake clock.
// ---------------------------------------------------------------------------

const List<String> _weekdays = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _two(int v) => v.toString().padLeft(2, '0');

/// Day label + clock time of [ts] in local time.
///
/// The day label is the weekday inside the last 7 days (the only occurrence
/// of that weekday in the window, so it is unambiguous), the weekday plus
/// day and month beyond that, and the year too when it differs from [now]'s.
/// [now] exists for tests; production uses the wall clock.
({String day, String time}) stampParts(DateTime ts, {DateTime? now}) {
  final local = ts.toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  // Day arithmetic on UTC midnights: a local-midnight difference is 23h or
  // 25h across a DST change, which would truncate to the wrong day count.
  final ageDays = DateTime.utc(
    ref.year,
    ref.month,
    ref.day,
  ).difference(DateTime.utc(local.year, local.month, local.day)).inDays;
  final wd = _weekdays[local.weekday - 1];
  final String day;
  // `ageDays` is negative for a stamp slightly AHEAD of this device's clock
  // (the Pi's clock leads the phone's across midnight, or plain skew). One
  // day of lead still reads as recent, so a skewed clock cannot flip one row
  // to the dated form in the middle of a conversation; a larger jump falls
  // through and shows the date, which exposes the oddity instead of hiding it.
  if (ageDays >= -1 && ageDays < 7) {
    day = wd;
  } else if (local.year == ref.year) {
    day = '$wd ${local.day} ${_months[local.month - 1]}';
  } else {
    day = '$wd ${local.day} ${_months[local.month - 1]} ${local.year}';
  }
  return (
    day: day,
    time: '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}',
  );
}

/// `Tue 14:03:12` — the stamp under a bubble.
String formatStamp(DateTime ts, {DateTime? now}) {
  final p = stampParts(ts, now: now);
  return '${p.day} ${p.time}';
}

/// `Tue 14:03:12 → 14:03:19` — a tool's run window. The day is printed once
/// when both ends share it, twice when the run crossed midnight
/// (`Tue 23:59:58 → Wed 00:00:04`).
String formatSpan(DateTime start, DateTime end, {DateTime? now}) {
  final a = stampParts(start, now: now);
  final b = stampParts(end, now: now);
  // `day` is `Wed` while recent and `Wed 25 Nov` once older, so the two ends
  // compare equal only when they land on the same day in the same shape —
  // which holds for every recorded run once `now` is at or after it.
  final tail = a.day == b.day ? b.time : '${b.day} ${b.time}';
  return '${a.day} ${a.time} → $tail';
}

/// A measured duration: `412ms`, `6.8s`, `42s`, `2m 05s`, `1h 03m`.
///
/// One decimal below 10s (the precision the SDK reports is worth showing),
/// whole seconds below a minute, then minutes and hours. Rounds to the
/// nearest unit of the chosen shape, so 59.7s reads `1m 00s`, never `60s`.
String formatDuration(int ms) {
  if (ms < 1000) return '${ms}ms';
  if (ms < 9950) {
    final tenths = (ms + 50) ~/ 100;
    return '${tenths ~/ 10}.${tenths % 10}s';
  }
  return formatElapsed((ms + 500) ~/ 1000);
}

/// A whole-second duration: `6s`, `1m 02s`, `1h 03m`. Used for the live
/// elapsed counter of a running tool, where decimals would flicker.
String formatElapsed(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final m = seconds ~/ 60;
  final s = seconds % 60;
  if (m < 60) return '${m}m ${_two(s)}s';
  final h = m ~/ 60;
  return '${h}h ${_two(m % 60)}m';
}

/// Plan/172 — the timing of an expanded tool card, one display part per line
/// (the card stacks them: invocation above, execution window below). Empty
/// when nothing is known (the card then shows no timing block).
///
/// Shapes, richest first (each part only when its value exists):
/// - running:  `reply Tue 14:03:05 · running since Tue 14:03:12 (6s)`
/// - finished: `reply Tue 14:03:05 · ran Tue 14:03:12 → 14:03:19 · 6.8s`
/// - finished, start unknown (a session recorded before the SDK logged tool
///   wall time): `reply Tue 14:03:05 · finished Tue 14:03:19`
/// - legacy row with no execution window at all: its plain row stamp.
List<String> toolTimingParts(ToolEvent t, {DateTime? now}) {
  final reply = t.replyAt;
  final start = t.startedAt;
  final end = t.endedAt;
  final durationMs = t.durationMs;

  if (reply == null && start == null && end == null) {
    final ts = t.ts;
    return ts == null ? const [] : [formatStamp(ts, now: now)];
  }

  final parts = <String>[
    if (reply != null) 'reply ${formatStamp(reply, now: now)}',
  ];
  if (t.isRunning) {
    if (start != null) parts.add(_runningLabel(start, now: now));
    return parts;
  }
  if (start != null && end != null) {
    final ms = durationMs ?? end.difference(start).inMilliseconds;
    parts.add(
      'ran ${formatSpan(start, end, now: now)} · ${formatDuration(ms)}',
    );
  } else if (end != null) {
    parts.add(
      'finished ${formatStamp(end, now: now)}'
      '${durationMs != null ? ' · ${formatDuration(durationMs)}' : ''}',
    );
  }
  return parts;
}

String _runningLabel(DateTime start, {DateTime? now}) {
  final at = (now ?? DateTime.now()).difference(start).inMilliseconds;
  final elapsedMs = at < 0 ? 0 : at;
  // Under a second the counter is noise: the start time alone is exact.
  final counter = elapsedMs >= 1000
      ? ' (${formatElapsed(elapsedMs ~/ 1000)})'
      : '';
  return 'running since ${formatStamp(start, now: now)}$counter';
}

/// Muted 11px style shared by every stamp under a bubble (matches the
/// existing "sending… / not delivered" caption).
TextStyle stampStyle(BuildContext context) =>
    context.typo.sansBody.copyWith(color: context.colors.muted, fontSize: 11);

/// Plan/172 — the clock stamp under a message. Renders nothing when [show]
/// is off (the Settings switch) or the message carries no time (synthetic
/// messages in tests); callers may therefore place it unconditionally.
class MessageStamp extends StatelessWidget {
  final DateTime? ts;
  final bool show;

  const MessageStamp(this.ts, {super.key, this.show = true});

  @override
  Widget build(BuildContext context) {
    final t = ts;
    if (!show || t == null) return const SizedBox.shrink();
    return Text(formatStamp(t), style: stampStyle(context));
  }
}
