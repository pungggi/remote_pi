# Plan 134 — "Waiting for your input" state (pi 0.84.4 `ui_prompt_start`/`ui_prompt_end`)

## Context

Pi 0.84.4 added two extension events ([#8355](https://github.com/earendil-works/pi/pull/8355)):

```ts
type UIPromptKind = "select" | "confirm" | "input" | "editor" | "custom";
interface UIPromptStartEvent { type: "ui_prompt_start"; reason: "ui_prompt"; kind: UIPromptKind; title?: string }
interface UIPromptEndEvent   { type: "ui_prompt_end";   reason: "ui_prompt"; kind: UIPromptKind; title?: string }
```

Fired when Pi starts/stops waiting on a **blocking user-facing `ctx.ui` prompt**. Verified present in the installed SDK (`dist/core/extensions/types.d.ts`, pi 0.84.4).

Today the app's only agent state is `room_meta.working` (plan/32). When a tool blocks on `ctx.ui` — pi-ask's `ask_user` *or any other extension's* `confirm`/`select`/`input` — the phone shows a spinner as if the agent were working, when it is actually **blocked waiting for the human**. Only pi-ask flows are bridged to the phone (plan/100 `extension_ui_bridge.ts`); every foreign prompt hangs silently. The user has no signal that walking to the terminal (or opening the app) is the unblocking action.

Goal: a third published state, `waiting_for_input`, visible on Home tiles, in the active chat, and as a push notification for backgrounded rooms — covering **every** blocking prompt, not just pi-ask.

## Expected structure

Three waves, mirroring plan/32's exact pattern (raw publish in the extension → typed field in the relay → debounced display + notification in the app), plus a cockpit-only shortcut that needs no relay change.

### Wave 1 — pi-extension: publish `waiting_for_input`

- `pi.on("ui_prompt_start")` → `_publishWaitingForUser(true, event.kind, event.title)`;
  `pi.on("ui_prompt_end")` → `_publishWaitingForUser(false)`.
- `_publishWaitingForUser` mirrors `_publishWorking` (`pi-extension/src/index.ts` ~335):
  updates `ext.myRoomMeta` and sends
  `sendControl({ type: "room_meta_update", room_id, meta: { waiting_for_input: true } })`.
  Raw, no debounce — the app debounces (same decision as plan/32 Q4).
- Interaction with `working`: the two flags are independent (`working` = in-flight turn,
  `waiting_for_input` = blocking prompt). During a prompt the turn is still "open" from
  `turn_start`'s perspective, so **do not** touch `working` here. The app derives the
  display tri-state: `waiting_for_input ? waiting : (working ? working : idle)`.
- Session teardown/rebind: clear the flag on `session_start` rebind and `_goIdle` so a
  stale `true` can't survive a prompt that died with the run (defensive: also publish
  `false` on `agent_end` if the SDK ever fails to pair an `end` — the SDK fires
  `ui_prompt_end` when no longer waiting, but abort paths are the risky ones).

**Acceptance:** vitest — a captured `ui_prompt_start` publishes
`meta.waiting_for_input:true` (with kind/title logged), `ui_prompt_end` publishes
`false`, non-prompt events don't touch it, flag resets on `_goIdle`.
`pnpm --dir pi-extension typecheck && pnpm --dir pi-extension test` green.

### Wave 2 — relay: carry the field

- `relay/src/rooms.rs`: `RoomMeta.waiting_for_input: bool` (always serialized, default
  `false`, doc comment referencing this plan) + `RoomMetaPatch.waiting_for_input:
  Option<bool>` (same single-`Option` semantics as `working`). Include in `is_empty()`.
- `relay/src/peer.rs`: extract `meta.waiting_for_input` in the `hello` path (~`:101-113`)
  and the `room_meta_update` handler (~`:261-268`), same as `working`; carried in
  `room_announced` + `room_meta_updated` forwards.

**Acceptance:** `cargo test` covering merge-patch of `waiting_for_input` (set true,
set false, absence leaves unchanged); clippy clean.

### Wave 3 — app: display + notify

- `protocol.dart`: parse `waiting_for_input` in `RoomMetaUpdated` (presence-flag
  convention like `hasWorking`); `connection_manager.dart` keeps per-room state next to
  `working` (~`:902`).
- Home tiles: tri-state status — "needs input" badge (distinct color from the working
  spinner) driven by the meta index with the same debounce policy as `working`.
- Active chat: composer hint + status pill switch from "working" to
  "Waiting for your answer…"; when the prompt is a pi-ask flow the answer sheet already
  opens (plan/100/101) — the pill must not duplicate it, only annotate.
- Notification: reuse the plan/132 control-path machinery (`_publishRunDone` pattern —
  control frames bypass the room demux so backgrounded rooms notify). Fire a local
  notification **only on the working→waiting transition** (not on app-open replays).
  **Dedupe rule:** suppress the generic notification when an `extension_ui_request`
  sheet is already open for that room (the sheet is itself the signal); the generic
  notification text is "Pi is waiting for input at the terminal" and is the only signal
  for foreign prompts (kind `confirm`/`input`/`editor` from any extension).
- `session_sync`: include the current `waiting_for_input` in the hello/meta snapshot so
  a freshly opened app renders the badge without waiting for a transition.

**Acceptance:** flutter tests — meta parsing, tri-state derivation, transition-only
notification with sheet-dedupe; manual pass: trigger `ctx.ui.confirm` from a scratch
extension → phone shows badge + notification; answer at terminal → badge clears.

### Wave 4 — cockpit (no relay involved)

Cockpit spawns pi `--mode rpc` (`cockpit/lib/app/core/env.dart` `spawnArgs`), and RPC
streams these events to the host. Subscribe to `ui_prompt_start`/`ui_prompt_end` in the
cockpit's RPC client and surface the same tri-state in the cockpit UI (tab badge /
status bar), independent of the relay waves — can ship first if desired.

**Acceptance:** cockpit shows/clears the waiting state around a blocking prompt.

## DoD

- [x] Phone + cockpit show "waiting for input" for **any** blocking `ctx.ui`
  prompt, with a transition notification that doesn't double-fire for pi-ask
  sheets.
- [x] `working` semantics unchanged (plan/32 regression suite stays green).
- [x] Extension, relay, app, cockpit suites green (`pnpm test`, `cargo test`,
  `flutter test`).
  - Implemented 2026-08-30: extension (SDK bump ^0.84.4 + `_publishWaitingForUser`
    + defensive clears + 6 tests), relay (field + patch + 3 registry tests + 1
    wire test, clippy clean), app (parse/propagate/`waitingForInputStream`,
    amber tri-state on tile + pill + composer hint,
    `WaitingInputNotifications` facade with sheet-dedupe, 16 new tests — full
    809 green), cockpit (`RpcUiPromptStart/End` mapping + tab badge, mapper
    tests). Cockpit full-suite has ~21 pre-existing failures (terminal/codex/db
    tests, verified failing on `main` without this change). PROTOCOL.md
    documents `meta.waiting_for_input`.
  - PR #58 review fixes (2026-08-30): (1) uncached-room duplicate rising edges
    killed by a volatile last-seen map (cleared on `room_ended`); (2)
    `isRoomWaitingForInput` + `isRoomWorking` gate on `_liveRoomIds` so a Pi
    dying mid-prompt/turn can't keep the badge/dot alive; (3) the RPC stream
    does NOT forward `ui_prompt_start/end` (ExtensionRunner vs AgentSession
    events — verified with a live `pi --mode rpc` probe), so the extension
    mirrors the transition as a `remote-pi:ui-prompt` custom message
    (relay-state channel) and the cockpit maps that; the direct event mapping
    stays as forward-compat.

## Next plans

- 135 (stop-clears-queue): while `waiting_for_input`, the Stop affordance is the wrong
  action — the two plans share the status-pill component.
- Follow-up candidate: render foreign prompts (kind/title) as an answerable card on the
  phone, generalizing the plan/100 bridge beyond pi-ask.
