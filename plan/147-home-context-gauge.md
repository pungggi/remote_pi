# Plan 147 — Home list context gauge

## Context

The Home session list already alternates its subtitle between the git
branch summary and the selected model (plan/107b). The model line,
however, never says how big that model's context window is, and the
only place context pressure is visible today is inside the chat header
(plan/115, `73% 96k/200k`) — you must open every session to check it.

The user wants context pressure visible **at a glance across all online
sessions**, without opening anything:

1. **Model subtitle** — show the model's max context window behind the
   model name: `claude-sonnet-4-5 · 200k`.
2. **Context fill bar** — paint the *used* context size as a subtle
   full-height background wedge inside each tile (width = used
   fraction, low-alpha tint), so a scan down the online list shows
   which sessions are filling up.

## Data source

Everything needed already arrives on the app side:

- `RoomInfo.contextUsage` (`tokens` / `contextWindow` / `percent`),
  published by the extension as opaque `room_meta.context_usage`
  (plan/115) and preserved across list refreshes + reconnects by the
  connection manager.
- Null `context_usage` (before the first LLM response, or offline
  cached rooms) ⇒ no bar, plain model name — the tile degrades
  gracefully to its previous look.

## Expected structure

All changes live in `app/lib/ui/home/widgets/session_tile.dart`:

- `_modelLabel(name, contextWindow)` — replaces `_truncateModel`;
  appends ` · Nk` from `contextUsage.contextWindow` when known.
- `_contextFraction(usage)` — normalized 0..1 fill fraction; prefers
  SDK `percent`, falls back to `tokens / contextWindow` (covers the
  post-compaction window where `percent` is null but tokens flow
  again).
- `_contextTint(colors, fraction)` — pressure tint with the SAME 70/90
  thresholds as the chat-header meter: accent @ 0.05 alpha below 70%,
  warning @ 0.08 at 70–90%, error @ 0.10 at ≥ 90%. Low alphas keep it
  a background hint, never competing with the selected-tile highlight.
- `_ContextFill` — `AnimatedFractionallySizedBox` wedge behind the row
  content (400ms ease-out-cubic), full tile height, anchored left past
  the 3px selection border, soft rounded right edge.

## Steps

1. Wrap the tile's content `Padding` in a `Stack`; insert the fill as
   `Positioned.fill(left: 3)` when `contextUsage` yields a fraction.
2. Render the model subtitle via `_modelLabel` (max-tokens suffix).
3. Widget tests (`app/test/ui/home/session_tile_test.dart`):
   - bar present with `contextUsage`, absent without it;
   - `widthFactor` equals the reported fraction;
   - model line shows the `· 200k` suffix when the window is known.

### Acceptance criteria

- Online sessions with usage show a wedge whose width tracks
  `percent`; a tile at 80% renders visibly wider than one at 20%.
- Tint shifts warning-ward at ≥ 70% and error-ward at ≥ 90%.
- Rooms without usage (fresh session, keeper mirror, offline cache)
  render exactly as before — no bar, no suffix.
- `flutter analyze` clean; `flutter test test/ui/home` green.

## DoD

- [x] Tile renders context fill + model max-tokens suffix
- [x] Widget tests pin fraction mapping, 0..1 clamping, tint bands,
      suffix rendering, sub-1k guard, and coexistence with the
      selected-tile highlight
- [x] analyze + home test suite green
- [x] Changelog entries (app asset + root)
- [ ] User review on device

## Review round (2026-10-23)

- The left-bar width `3` was duplicated in three places → extracted
  `SessionTile._leftBarWidth`.
- Tint switches instantly between pressure bands (no color tween) —
  deliberate: bands are discrete states like the chat pill; the width
  animation carries the continuous signal.
- Sub-1k context windows would render `· 0k` → suffix now requires
  `contextWindow >= 1000`.
- `app/assets/CHANGELOG.md` turned out fully double-encoded since the
  1.4.1 backfill (e4ae5690): every em dash/symbol showed as mojibake in
  the in-app viewer. Repaired via a verified cp1252→UTF-8 round-trip
  (58 runs); shipped APKs unaffected.

## Next plans

- None yet — if the wedge reads too subtle on the light theme, tune
  `_contextTint` alphas there first.
