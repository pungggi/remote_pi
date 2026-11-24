// Plan/172 — the transcript's clock formatters and the tool timing line.
//
// Every function here is pure with an injectable `now`, so each shape is
// pinned to a fixed calendar instead of the wall clock (a test that reads
// "Tue" would otherwise fail at midnight or on a DST change).
//
// Reference calendar: `now` is Tue 2026-11-24 20:00 local unless stated.
//   Tue 24 Nov 2026 · Mon 23 Nov · Sun 22 Nov · Sat 21 Nov · Wed 18 Nov ·
//   Tue 17 Nov (exactly 7 days) · Mon 16 Nov · Mon 24 Nov 2025.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/message_stamp.dart';
import 'package:flutter_test/flutter_test.dart';

final DateTime _now = DateTime(2026, 11, 24, 20, 0, 0);

/// 14:03:12 on [year]-[month]-[day], local time.
DateTime _at(
  int year,
  int month,
  int day, {
  int h = 14,
  int m = 3,
  int s = 12,
}) => DateTime(year, month, day, h, m, s);

void main() {
  group('formatStamp', () {
    test('inside the last 7 days: weekday + clock time', () {
      expect(formatStamp(_at(2026, 11, 24), now: _now), 'Tue 14:03:12');
      expect(formatStamp(_at(2026, 11, 21), now: _now), 'Sat 14:03:12');
      // 6 days back is still the bare weekday.
      expect(formatStamp(_at(2026, 11, 18), now: _now), 'Wed 14:03:12');
    });

    test('7 days or older: weekday + day + month', () {
      expect(formatStamp(_at(2026, 11, 17), now: _now), 'Tue 17 Nov 14:03:12');
      expect(formatStamp(_at(2026, 11, 16), now: _now), 'Mon 16 Nov 14:03:12');
    });

    test('another year: the year is appended', () {
      expect(
        formatStamp(_at(2025, 11, 24), now: _now),
        'Mon 24 Nov 2025 14:03:12',
      );
    });

    test('day count survives a DST change (UTC-midnight arithmetic)', () {
      // Europe left DST on 2026-10-25: 2026-10-24 → 2026-10-30 is 6 calendar
      // days but one hour less wall time, which a local-midnight difference
      // would truncate to 5 (still fine) — and the reverse direction would
      // turn a true 7 into 6. Both must read as calendar days.
      final now = DateTime(2026, 10, 31, 9, 0, 0);
      expect(
        formatStamp(DateTime(2026, 10, 24, 14, 3, 12), now: now),
        'Sat 24 Oct 14:03:12',
      );
      expect(
        formatStamp(DateTime(2026, 10, 25, 14, 3, 12), now: now),
        'Sun 14:03:12',
      );
    });

    test('null now uses the wall clock (smoke: local hh:mm:ss)', () {
      final ts = DateTime.now().subtract(const Duration(minutes: 1));
      final out = formatStamp(ts);
      final local = ts.toLocal();
      expect(
        out,
        endsWith(
          '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}:'
          '${local.second.toString().padLeft(2, '0')}',
        ),
      );
    });

    test('a UTC instant is rendered in local time', () {
      final utc = DateTime.utc(2026, 11, 24, 13, 3, 12);
      final local = utc.toLocal();
      // Same text as the equivalent local DateTime — the formatter converts.
      expect(formatStamp(utc, now: _now), formatStamp(local, now: _now));
      final p = stampParts(utc, now: _now);
      expect(p.time, '${local.hour.toString().padLeft(2, '0')}:03:12');
    });
  });

  group('formatSpan', () {
    test('same day: the day is printed once', () {
      expect(
        formatSpan(
          _at(2026, 11, 24, h: 14, m: 3, s: 12),
          _at(2026, 11, 24, h: 14, m: 3, s: 19),
          now: _now,
        ),
        'Tue 14:03:12 → 14:03:19',
      );
    });

    test('across midnight: each end keeps its own day', () {
      // `now` is the morning after: both ends are in the past.
      final morningAfter = DateTime(2026, 11, 25, 9);
      expect(
        formatSpan(
          _at(2026, 11, 24, h: 23, m: 59, s: 58),
          _at(2026, 11, 25, h: 0, m: 0, s: 4),
          now: morningAfter,
        ),
        'Tue 23:59:58 → Wed 00:00:04',
      );
    });

    test('a Pi clock slightly ahead of the phone stays in weekday form', () {
      // Phone: Tue 23:58. Pi: Wed 00:01 (leads by 3 minutes). One row must not
      // switch to the dated form in the middle of a conversation.
      expect(
        formatStamp(
          _at(2026, 11, 25, h: 0, m: 1, s: 0),
          now: DateTime(2026, 11, 24, 23, 58),
        ),
        'Wed 00:01:00',
      );
      // More than a day ahead → the dated form exposes the oddity.
      expect(
        formatStamp(_at(2026, 11, 27), now: DateTime(2026, 11, 24, 23, 58)),
        'Fri 27 Nov 14:03:12',
      );
    });
  });

  group('formatDuration', () {
    test('shapes by magnitude', () {
      expect(formatDuration(0), '0ms');
      expect(formatDuration(412), '412ms');
      expect(formatDuration(999), '999ms');
      expect(formatDuration(6821), '6.8s');
      expect(formatDuration(6000), '6.0s');
      expect(formatDuration(9949), '9.9s');
      expect(formatDuration(9950), '10s');
      expect(formatDuration(42_400), '42s');
      // 59.7s rounds up to a whole minute, never "60s".
      expect(formatDuration(59_700), '1m 00s');
      expect(formatDuration(125_000), '2m 05s');
      expect(formatDuration(3_781_000), '1h 03m');
    });
  });

  group('formatElapsed', () {
    test('whole seconds only', () {
      expect(formatElapsed(0), '0s');
      expect(formatElapsed(6), '6s');
      expect(formatElapsed(59), '59s');
      expect(formatElapsed(62), '1m 02s');
      expect(formatElapsed(3780), '1h 03m');
    });
  });

  group('toolTimingParts', () {
    final reply = _at(2026, 11, 24, h: 14, m: 3, s: 5);
    final start = _at(2026, 11, 24, h: 14, m: 3, s: 12);
    final end = _at(2026, 11, 24, h: 14, m: 3, s: 19);

    ToolEvent tool({
      ToolEventStatus status = ToolEventStatus.completed,
      DateTime? ts,
      DateTime? replyAt,
      DateTime? startedAt,
      DateTime? endedAt,
      int? durationMs,
    }) => ToolEvent(
      id: 'tc1',
      toolCallId: 'tc1',
      tool: 'Bash',
      args: const {},
      status: status,
      ts: ts,
      replyAt: replyAt,
      startedAt: startedAt,
      endedAt: endedAt,
      durationMs: durationMs,
    );

    test(
      'finished with the full window: reply · ran start → end · duration',
      () {
        expect(
          toolTimingParts(
            tool(
              ts: start,
              replyAt: reply,
              startedAt: start,
              endedAt: end,
              durationMs: 6821,
            ),
            now: _now,
          ),
          ['reply Tue 14:03:05', 'ran Tue 14:03:12 → 14:03:19 · 6.8s'],
        );
      },
    );

    test('duration falls back to end − start when the SDK reported none', () {
      final parts = toolTimingParts(
        tool(startedAt: start, endedAt: end),
        now: _now,
      );
      expect(parts, ['ran Tue 14:03:12 → 14:03:19 · 7.0s']);
    });

    test('running: start is known → live elapsed counter (whole seconds)', () {
      // 6.4 s after the start reads "6s"; under a second, no counter at all.
      expect(
        toolTimingParts(
          tool(
            status: ToolEventStatus.pending,
            replyAt: reply,
            startedAt: start,
          ),
          now: start.add(const Duration(milliseconds: 6400)),
        ),
        ['reply Tue 14:03:05', 'running since Tue 14:03:12 (6s)'],
      );
      expect(
        toolTimingParts(
          tool(status: ToolEventStatus.allowed, startedAt: start),
          now: start.add(const Duration(milliseconds: 900)),
        ),
        ['running since Tue 14:03:12'],
      );
    });

    test('running with no known start (replayed pending row): reply only', () {
      expect(
        toolTimingParts(
          tool(status: ToolEventStatus.pending, replyAt: reply),
          now: _now,
        ),
        ['reply Tue 14:03:05'],
      );
    });

    test('finished, start unknown (legacy SDK session): reply · finished', () {
      expect(
        toolTimingParts(
          tool(replyAt: reply, endedAt: end),
          now: _now,
        ),
        ['reply Tue 14:03:05', 'finished Tue 14:03:19'],
      );
      // A duration without a start is still worth showing.
      expect(
        toolTimingParts(
          tool(replyAt: reply, endedAt: end, durationMs: 6821),
          now: _now,
        ),
        ['reply Tue 14:03:05', 'finished Tue 14:03:19 · 6.8s'],
      );
    });

    test('legacy row with no execution window: its plain row stamp', () {
      expect(toolTimingParts(tool(ts: start), now: _now), ['Tue 14:03:12']);
    });

    test('nothing known at all → no line', () {
      expect(toolTimingParts(tool(), now: _now), isEmpty);
    });

    test('a failed call keeps its window (when it ran and died)', () {
      expect(
        toolTimingParts(
          tool(status: ToolEventStatus.failed, startedAt: start, endedAt: end),
          now: _now,
        ),
        ['ran Tue 14:03:12 → 14:03:19 · 7.0s'],
      );
    });
  });
}
