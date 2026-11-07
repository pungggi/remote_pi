# 160 — Session tile: swipe to cycle info

## Context

The Home session tile's subtitle used `_SubtitleClock`: one shared 3-second
timer that flipped every tile between the git summary and the secondary line
(model by-repo / last prompt by-model) in lock-step. Auto-alternation is
passive — the user waits for the line they want — and the timer runs for
every mounted tile even when nobody is looking.

Decision (user, 2026-11-06): replace it with manual cycling. A **left swipe
on the tile cycles forward** through the available lines, a right swipe
cycles back, and **the position is remembered per session list item**.

## Expected structure

- `app/lib/ui/home/widgets/session_tile.dart`
  - `_SubtitleClock` deleted (no timer, no shared ValueNotifier).
  - `SessionTile` gains `subtitlePhase: int` (raw position, normalized
    inside the tile against the current line count),
    `onCycleSubtitle: void Function(int delta)?` (+1 next, -1 previous),
    and `lastResponseAt: DateTime?` (the third cyclable line,
    `Last response: 5m ago`).
  - The gesture registers only when a caller stores the phase AND more
    than one line is available. Direction is decided by **net drag
    displacement** (not release velocity) so slow deliberate swipes work.
  - `_TitleBlock` is stateless; the cyclable lines are git + secondary
    + last response (never the "Last paired" placeholder);
    `AnimatedSwitcher` keeps the 300 ms crossfade; `git` stays first.
- `app/lib/data/local/boxes.dart` + `app/lib/ui/home/viewmodels/home_viewmodel.dart`
  - `lastAssistantTs(epk, roomId)` — epoch-ms of the newest `assistant`
    row in the msgs box (ts chronology, seq tie-break); viewmodel exposes
    it as `lastResponseAt` DateTime. Reads the same box the unread
    listenable watches, so the line refreshes on every delivery.
- `app/lib/ui/home/home_page.dart`
  - The raw phase lives in the HomeViewModel as `Map<String, int>` keyed
    by the row's session key (`epk|roomId`), read/written through
    `subtitlePhaseFor` / `cycleSubtitle`. It survives group reordering,
    rebuilds AND lazy scroll-outs (a SliverList matches children
    positionally, so widget-local state resets on any index change or
    cacheExtent eviction — review f1, PR #103). Deliberately resets on
    app restart: it's a reading position, not a durable preference.
  - **Staleness tradeoff (review f4, PR #103)**: the relative time
    ("Last response: 5m ago") is computed at render time only — no
    periodic timer refreshes it. A quiet session's "5m" stays frozen
    until the next list rebuild (any delivery, unread change or swipe).
    Accepted: correctness on every observable refresh, zero timers.

## Steps with acceptance criteria

1. Swipe wiring — **done**: left drag ≥ 16 net px requests +1, right -1;
   tap/long-press/vertical scroll unaffected (different gesture axes).
2. Phase normalization — **done**: phase wraps modulo the CURRENT line
   count, so an arriving/departing git snapshot or prompt degrades
   gracefully (never out of range, never crashes).
3. Per-session memory — **done**: row keyed by session; scrolling a tile
   out and back keeps its position.
4. Tests — **done**: `session_tile_test.dart` group
   "subtitle cycling (plan/160)" covers callback direction, phase
   rendering (by-repo + by-model), the three-line cycle with wrap,
   response-only tiles, and single-line/zero-line tiles registering no
   gesture. Full `flutter test` green.

## DoD

- [x] No `_SubtitleClock` remains; no timer runs for the subtitle.
- [x] `flutter analyze` — no new errors/warnings (pre-existing SDK-3.50
      `deprecated_member_use` infos are repo-wide and out of scope).
- [x] `flutter test` — 1022/1022 pass.

## Next plans

- Optional (not planned): a subtle chevron/dots affordance hinting the
  swipe on tiles with >1 line; persisted phase per session across app
  restarts if it proves wanted.
