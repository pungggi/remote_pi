# Plan 156 — Model subscription usage in the grouped Home

## Context

The user pays for coding-plan subscriptions (z.ai GLM Coding Plan today)
that meter usage in rolling windows. That pressure is invisible in Piper:
the only way to check quota is the z.ai web dashboard. The Home list
already groups sessions **by model**, and every online session's Pi has
the provider credential on disk — so the group header is the natural
place to surface the account's quota state at a glance.

User decisions (2026-11-01):

- **All windows**: render every quota window the provider reports
  (z.ai: 5h prompts, weekly tokens, monthly MCP credits). Not every
  provider supports every quota — the UI renders whatever arrives.
- **Text + hairline bar**: mono text per window plus a subtle
  full-width fill wedge behind the header, same visual language as the
  plan/147 context gauge.
- **Online gating**: the header shows usage only when at least one
  session in the group is **online** — offline caches would show stale
  quota as if it were live.
- **z.ai first**, behind a provider-probe registry so later providers
  (kimi-coding, …) slot in without protocol changes.

## Data source (validated live with the user's key)

`GET https://api.z.ai/api/monitor/usage/quota/limit`

- **Auth**: `authorization: Bearer <key>`; key from
  `~/.pi/agent/auth.json` → `zai.key` (shape `{type:"api", key}`),
  env `ZAI_API_KEY` / `Z_AI_API_KEY` as fallback. The key never leaves
  the PC: only the normalized usage blob rides `room_meta`.
- **Response**: `data.limits[]` with `type` (`TIME_LIMIT` /
  `TOKENS_LIMIT` / `CREDIT_LIMIT`), `percentage`, `nextResetTime`
  (epoch ms), optional `usage`/`currentValue`/`remaining`, and
  `data.level` / `data.planName` (plan label, e.g. `max`).
- **Window decode** (matches CodexBar's battle-tested mapping):
  `unit` ∈ {1: days, 3: hours, 5: minutes, 6: weeks} × `number`;
  `TIME_LIMIT` with `unit=5 number=1` is the **monthly MCP marker**
  (43200 min). Known shapes get stable labels: `5h`, `wk`, `mo`.
- **Percent override**: when `usage > 0` with `remaining`/
  `currentValue`, counts beat the API's `percentage` (clamped 0–100).
- **Reset plausibility guard**: a reset further out than the window
  length + 1 min clock skew is dropped (the 5h window sometimes reports
  far-future resets; rendering them would be a lie).

## Expected structure

### pi-extension

- New `src/plan-usage.ts`:
  - `PlanUsage` wire type — `{provider, plan, fetchedAt, windows[]}`,
    each window `{kind: "tokens"|"time", label, percent, minutes,
    resetAt, used, limit}`.
  - `zaiPlanUsageProbe(key)` — fetch + decode per the rules above.
  - `readProviderApiKey(providerId)` — env first, then `auth.json`.
  - Probe registry keyed by provider id (v1: `zai` only).
- `main.ts` wiring:
  - Track the current model's **provider id** (`ext.currentProvider`)
    from `model_select` / live `getModel()` / the default-provider seed.
  - `_maybePublishPlanUsage()` — eligible when provider has a probe,
    key resolves, and the relay room is up. Throttled to 5 min; deduped
    against the last published blob; failures silent (quota is
    best-effort decoration, never worth a red state).
  - Triggers: room announce, `session_start`, `agent_end` (turn
    boundary), `model_select`, and a 10-min refresh timer.
  - Publish as opaque `room_meta.plan_usage` (same pipe as
    `context_usage`).
  - **Tombstone semantics differ from context_usage**: plan usage is
    account-scoped, so a model switch *within* the same provider keeps
    it; only a **provider change** clears (`plan_usage: null`).

### App

- `protocol.dart`: `PlanUsage` / `PlanUsageWindow` models;
  `RoomInfo.planUsage` (parse, serialize, copyWith sentinel); the
  both-places read on `RoomAnnounced`; the has-flag patch on
  `RoomMetaUpdated`.
- `connection_manager.dart`: merge `plan_usage` with the has-flag
  convention; a model-only update preserves it (account-scoped), a
  `plan_usage: null` clears it. Rooms-snapshot path: keep local
  `planUsage` only while the model is unchanged (same staleness rule
  as context_usage).
- `home_state.dart`: `planUsageForGroup(group, isOnline)` — first
  **online** item's `room.planUsage`; `null` when none (drives the
  online gating).
- `SessionGroupHeader`: optional `usage` — mono text
  `5h 3% · wk 4%` (windows sorted shortest-first) plus reset countdown
  of the nearest plausible reset, count badge unchanged. A 2px hairline
  bar under the row fills by `maxPercent`; tint escalates
  muted → warning ≥50% → error ≥80%.
- `home_page.dart`: pass the usage only when `groupBy == model`.

### Relay

No changes — `room_meta` values are opaque pass-through.

## Steps

1. Extension probe module + unit tests (decode fixtures from the live
   response, percent override, reset guard, key resolution order).
2. Extension wiring (provider tracking, publish/tombstone, timers) +
   a `_setCurrentModel` tombstone test (provider change clears,
   same-provider switch keeps).
3. App protocol + connection-manager merge + tests.
4. Group-header UI + `planUsageForGroup` + widget tests (renders with
   usage, hidden without / all-offline, bar fraction, tint bands).
5. `pnpm typecheck` + `vitest` green; `flutter analyze` +
   `flutter test` green; changelog entries (root + app asset).

### Acceptance criteria

- Home grouped by model with an online z.ai session shows the plan
  windows + bar in that group's header; the same model group with all
  sessions offline shows nothing.
- A provider switch (z.ai → other) clears the header; a model switch
  within z.ai does not.
- No provider key material ever appears in logs, room_meta, or tests.
- Suites green; no relay change.

## DoD

- [x] Extension probe + publish + tombstone with tests
- [x] App parse/merge/group-header with tests
- [x] analyze/typecheck/test green on both sides
- [x] Changelog entries
- [ ] User review on device

## Next plans

- Additional providers in the probe registry (kimi-coding is the
  natural next: same auth.json slot pattern).
- Cockpit parity if a session list grouping lands there.
