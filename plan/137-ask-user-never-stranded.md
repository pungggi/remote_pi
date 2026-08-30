# Plan 137 — ask_user must never strand the phone

## Context

Recurring report: *"there are still instances where the ask user is not
rendered on the app and the chat is frozen or waiting for input; even a
steering message doesn't have an effect."*

Incident 2026-08-30 20:50 (screenshot, room `rcmoto_pi`) + live repro on the
`rein` session (`ask:payload` pending with no tool result for hours):

- The agent calls `ask_user` (pi-ask `ctx.ui.custom`). The TUI dialog opens on
  the desktop; pi-ask emits `@eko24ive/pi-ask:started` **once**; the bridge
  broadcasts `extension_ui_request` to the owners attached **at that instant**.
- If the phone misses that one frame (app backgrounded/killed, WS flap, zombie
  socket, relay reconnect window), the only recovery is the `session_sync`
  replay of `pendingRequests()` — and that dies after **`FLOW_TTL_MS = 10 min`**
  while the desktop dialog can legitimately wait far longer. After the TTL the
  phone shows the ask_user tool call spinning forever with **no sheet and no
  way to answer or cancel**.
- While the turn is blocked inside the tool, the SDK **queues** steering
  (`deliverAs:"steer"`) until the tool returns — by design it cannot take
  effect. The app shows an unbounded `steering…` label with no hint that the
  real unblock is answering/cancelling the question.
- If the destination room is actually gone (pi dead / cross-PC route down),
  the relay **silently drops** the envelope (`dest (peer, room) not found,
  dropping` — log only). The phone keeps `steering…` forever; the 20 s no-echo
  backstop reaps the optimistic bubble but nothing tells the user *why*.
- Sessions started before a `dist/` rebuild keep running the **old extension
  code** (extensions load once per session) — pre-plan/134 builds never publish
  `waiting_for_input`, so the pill says `working…` instead of
  `Waiting for your answer…` (observed on `rein`, started 09:15, dist rebuilt
  10:35).

Verified in the installed SDK (0.84.4): `ui.custom` **is** wrapped by
`withUIPrompt("custom", …)` → `ui_prompt_start/end` fire for pi-ask. The gap
is old extension builds / old pis, not the SDK.

## Goal

Four independent hardenings so that any single failure still leaves the phone
an answer/cancel path, and dead routes stop black-holing:

1. **Bridge reliability** (pi-extension): flows stay replayable for as long as
   the desktop dialog can realistically be open; every owner (re)attach
   re-replays them; a cancel for a forgotten flow still reaches pi-ask (which
   NACKs `flow_not_found` → warning → the stale sheet closes instead of
   hanging).
2. **`waiting_for_input` fallback** (pi-extension): publish the flag from the
   ask bridge itself (OR of SDK-prompt signal and active-flow signal) so pis
   without `ui_prompt_*` events still flip the pill.
3. **Route feedback** (relay + app): the relay NACKs unroutable envelopes with
   a rate-limited `route_error` control frame; the app clears `steering…`,
   marks the room offline and surfaces "Not delivered".
4. **Recovery card** (app): an in-flight `ask_user` tool call with no open
   sheet renders a card with **Retry** (re-`session_sync` → replay → sheet)
   and **Cancel question** (existing `cancel` → abort → unblocks the turn, so
   queued steering finally delivers).

## Expected structure

### Wave 1 — pi-extension (`extension_ui_bridge.ts`, `index.ts`)

- `FLOW_TTL_MS`: `10 * 60_000` → `4 * 60 * 60_000`. The TTL only guards
  abandoned flows; `completed` + bridge `dispose()` still purge promptly, so
  the extra retention costs one map entry + timer per open flow.
- `createExtensionUiBridge(pi, broadcast, hooks?)` — new optional
  `onActiveFlowsChanged?: (active: boolean) => void`, fired on every
  empty↔non-empty transition (started / completed / TTL expiry / dispose).
- `respond()` cancel path: when the bridge no longer knows the flow, still
  `emitSubmit(msg.id, flowId-from-id, { kind: "cancel" })` instead of dropping
  silently — pi-ask answers `submit-result { ok:false, flow_not_found }`,
  the bridge broadcasts the warning notify, and the app's stale sheet closes
  with feedback. (Cancel of a non-existent flow is a no-op server-side.)
- `_attachOwner` (after `_maybeResumeTurnForOwner`): replay
  `ext.extensionUiBridge?.pendingRequests()` to the **freshly attached**
  channel — same rationale as the session_sync replay, but covers the
  reconnect/attach gap without waiting for the app to re-sync.
- `_publishWaitingForUser` becomes the merged publisher of two flags
  (`sdkWaiting` from `ui_prompt_start/end`, `bridgeWaiting` from the new
  hook); publish `sdkWaiting || bridgeWaiting`. The plan/134 defensive clears
  (`agent_end`, `session_start`, `_goIdle`) reset both flags.

**Acceptance:** vitest — TTL constant change; `onActiveFlowsChanged` fires on
open/close; cancel-after-TTL emits submit (and the resulting submit-result
warning still broadcasts); attach replays pending requests; waiting publishes
true while a flow is active even with no `ui_prompt_*` events.

### Wave 2 — relay (`handlers/peer.rs`)

- On `registry.forward` miss, send the sender a control frame:
  `{ "type": "route_error", "peer": <dest_peer>, "room": <dest_room> }`.
- Rate-limit per `(conn_id, dest_peer, dest_room)` — one per
  `ROUTE_ERROR_TTL` (5 s), mirroring `control_reply_dedup_ttl` — so pi→app
  broadcast churn during app reconnects cannot spam the pi (the extension
  ignores unknown control types; only the app acts on it).
- `PROTOCOL.md`: document the frame + the dedup window.

**Acceptance:** cargo test — forward miss emits exactly one route_error per
5 s window per destination; a successful forward never emits one.

### Wave 3 — app (`protocol.dart`, `connection_manager.dart`, `sync_service.dart`, `chat_viewmodel.dart`, chat UI)

- Parse `route_error` as a control frame. ConnectionManager: mark that
  (peer, room) presence offline (reuse `_markActiveRoomOffline`-style state)
  and expose a `RouteErrorEvent(epk, roomId)` stream.
- SyncService: on `RouteErrorEvent` for the active room →
  `_clearSteeringLabels()` + a ⚠ assistant row "Not delivered — Pi
  unreachable. Reconnect or retry." (same rendering path as provider errors).
- ChatViewModel/`chat_page`: banner state (`routeError`) shown while the
  active room's last route_error is recent (auto-clears on next online edge /
  successful echo).
- **Recovery card** (`ChatReady.pendingUiRequest == null` + a `ToolEvent`
  with `tool == 'ask_user'` and `status == pending` + not offline): slim card
  above the composer — "Pi is waiting for your answer, but the question sheet
  didn't reach this device." Buttons: **Retry** → `_sync.requestSync()`;
  **Cancel question** → `vm.cancel(vm.cancelTargetId ?? 'working')`. A 3 s
  first-seen delay avoids flashing while the live request frame is in flight.

**Acceptance:** flutter tests — route_error parsing → steering label cleared
+ ⚠ row; recovery card appears for pending ask_user without sheet, hides when
the sheet arrives or the tool completes, Retry triggers a sync.

### Wave 4 — docs/ops

- PROTOCOL.md section for `route_error`.
- Ops note in this plan: after rebuilding `dist/`, long-lived TUI sessions must
  be restarted (or reloaded) to pick up the new extension — the 2026-08-30
  incident's `working…`-instead-of-`waiting…` was exactly that.

## DoD

- [x] Extension, relay, app suites green (`pnpm test`, `cargo test` + clippy,
      `flutter test`).
      - Implemented 2026-08-30: extension 991 pass (TTL 4h + attach replay +
        cancel-always-emits + merged waiting flags, 5 new tests); relay clippy
        clean + 148 pass (route_error NACK + rate-limit, 2 tests replacing the
        old drops-silently contract); app analyze 1 pre-existing info + 815
        pass (parse/event/state/UI: route_error chain + recovery card, 5 new
        tests). PROTOCOL.md documents `route_error` + the waiting fallback.
- [ ] Manual matrix: (a) ask with app closed > 10 min → reopen chat → sheet
      replays; (b) answer/cancel from phone after > 10 min; (c) kill the pi →
      steer → ⚠ within a second (not 20 s of silence); (d) pending ask_user
      with lost sheet → Retry opens it, Cancel unblocks the turn and the
      queued steering delivers.

### Ops note (the "still instances" that were NOT code)

Long-lived TUI sessions keep the extension code they loaded at startup —
`rein` (started 09:15, dist rebuilt 10:35) ran pre-134 code all day, which is
why its pill said `working…` instead of `Waiting for your answer…`. After
merging this into the main worktree and rebuilding `dist/`, restart the
long-lived sessions (or reload them) to pick up the new bridge.

## Next plans

- 135 (stop-clears-queue) shares the status-pill component with the recovery
  card's Cancel affordance.
- Generalize the recovery card to foreign prompts (`kind`/`title` from
  `ui_prompt_start`) once plan/134's follow-up lands.
