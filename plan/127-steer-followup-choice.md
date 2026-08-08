# 127 — Steer vs follow-up choice while working

## Context

Plan 43 shipped **steering only**: while a room is working, typing + send
delivers the text as `streaming_behavior: "steer"` → SDK `deliverAs: "steer"`,
injecting it into the active turn. Idle sends are fresh turns. Steer bubbles
show a `steering…` label.

Plan 43's own *Future work* says: *"Add `followUp` mode and a user-visible
choice if product testing shows both are useful."* This plan is that follow-up.

The Pi SDK confirms a clean second delivery mode —
`ExtensionAPI.sendUserMessage(content, { deliverAs })` accepts exactly:

- `"steer"` — inject into the active streaming turn.
- `"followUp"` — queue the message; the agent processes it as the **next**
  turn after the current one ends.

(`"nextTurn"` also exists on `sendCustomMessage`, out of scope here.)

Product decision (captured from the user):

- **Choose UX** — a segmented **[Steer | Follow-up]** toggle above the
  composer, shown only while working.
- **Default** — **Steer** (current behavior). Follow-up is the explicit,
  gentler alternative; the toggle resets to Steer at the start of each
  working turn.
- **Display** — **distinct icon + subtle tint** per type: Steer a
  route/redirect glyph in accent tint, Follow-up a clock/queue glyph in
  muted tint.

## Goal

While a room is working, the composer offers an explicit **Steer ↔ Follow-up**
choice. Sending delivers the message in the chosen mode, and every owner
renders the bubble with the matching type marker. Steer still injects into the
running turn; Follow-up queues behind it and starts a fresh turn when the
current one ends, attributed correctly to the follow-up message id.

## Non-goals

- Do not remove or change the existing **queued-message** feature
  (`queued_message_set` / preview card). It coexists; see *Future work* for
  possible later consolidation.
- Do not add `"nextTurn"` support.
- Do not change relay behavior (the `streaming_behavior` field is opaque to it).
- Do not change Stop/cancel semantics. Stop still targets the active turn.
- Do not support follow-up **image** attachments in the first slice (steer
  images are already deferred; follow-up images follow the same path later).

## Proposed wire contract

Extend `streaming_behavior` with `"followUp"`:

```json
{
  "type": "user_message",
  "id": "cli_...",
  "text": "Then also run the tests",
  "streaming_behavior": "followUp"
}
```

Rules:

- `StreamingBehavior` becomes `"steer" | "followUp"` (TS) and the Dart enum
  gains `followUp`.
- Omit `streaming_behavior` for idle sends (unchanged).
- The Pi echoes the accepted `user_message` to all owners with the same
  `streaming_behavior`, exactly as it does for `steer` today.
- The echoed follow-up is a **user-history row** (a committed bubble), not a
  preview card and not a new assistant reply target until its own turn starts.

## How turn attribution works (the crux)

`ext.currentTurnId` is a single slot: `agent_chunk`/`agent_done` carry
`in_reply_to: ext.currentTurnId`, and it is cleared on `message_end`
(line ~1928). While a turn streams, the slot belongs to that turn.

A follow-up sent while busy therefore **cannot** take the slot immediately
(the running turn owns it). The challenge is ensuring
`ext.currentTurnId == followUpId` when the follow-up's turn eventually
streams, so chunks attribute to the right bubble.

The app side needs **no** special handling: when the running turn emits
`agent_done`, the app clears its streaming buffer + working flag; when the
follow-up's turn then emits `agent_chunk(in_reply_to=followUpId)`, the
existing `AgentChunk` handler (`SyncService` ~line 503) seeds a fresh
streaming buffer for that id and flips working back on. Verified by reading
the handler — it sets `_chunkReplyTo`/`_setWorking(replyTo:)` for any
`in_reply_to`, and the flush path (~line 1211) creates a new buffer when the
id differs.

So the work is entirely on the **extension**: drive the slot correctly.

### Chosen approach — extension-side drain (mirrors queued messages)

The existing queued-message machinery already solves this precisely:

- `_maybeDrainQueuedItem()` runs on `turn_end`; when not busy it shifts one
  item, sets `ext.currentTurnId = item.id`, wakes the agent, echoes.
  (index.ts ~line 617.)

A follow-up reuses this pattern with its **own** pending queue so it never
collides with the preview-card queue:

1. On a `followUp` `user_message` arriving while busy: do **not** touch
   `currentTurnId`; push `{ id, text }` onto `ext.pendingFollowUps`; wake with
   `{ deliverAs: "followUp" }` (so the SDK also queues it); echo as
   `streaming_behavior: "followUp"`.
2. On `turn_end` (the SDK's queue would auto-start the follow-up's turn): the
   extension sets `ext.currentTurnId` to `pendingFollowUps[0].id` **before**
   the first chunk of the new turn arrives, so attribution is correct.

> **Open impl note (leave to the pi-extension persona):** decide whether to
> (a) let the SDK own the queue (`deliverAs: "followUp"`) and reconcile the
> slot on `turn_start`/`message_start` via FIFO + text-confirm (parallel to
> `_consumePendingSteerForStartedUser`), or (b) hold follow-ups in
> `ext.pendingFollowUps` and drain them ourselves on `turn_end` (does not
> pass `deliverAs`, identical user-visible result, simplest attribution).
> Prefer (b) unless testing shows the SDK's own queue ordering matters; it
> reuses the proven `_maybeDrainQueuedItem` shape.

### Why not infer steer for follow-up?

Today (index.ts ~line 3713):

```ts
const requestedSteer = msg.streaming_behavior === "steer";
const inferredBusySteer = !requestedSteer && ext.myRoomMeta?.working === true;
const shouldSteer = requestedSteer || inferredBusySteer;
```

A `followUp` message must **not** be inferred as steer. Add an explicit
`isFollowUp` branch so a busy-room follow-up is queued, not injected.

## Behavior

### Pi-extension (`pi-extension/src/index.ts`, `src/protocol/types.ts`)

1. `StreamingBehavior` type → `"steer" | "followUp"`.
2. `user_message` route:
   - `streaming_behavior === "followUp"` → not steer, not inferred-steer.
   - Echo includes `streaming_behavior: "followUp"` (`_echoUserMessage`).
   - While busy: queue per the chosen attribution approach; do **not** replace
     `currentTurnId`; do **not** `_trackPendingSteer`.
   - While idle: treat as a normal turn (set `currentTurnId = msg.id`, wake,
     echo) — a follow-up while idle is just the next message.
3. `_wakeAgent` already forwards any `deliverAs` value verbatim, so no change
   needed there beyond passing `"followUp"` when approach (a) is used.
4. Keep all existing steer behavior byte-identical.

### App protocol (`app/lib/protocol/protocol.dart`)

1. `UserMessageStreamingBehavior` enum gains `followUp` (`fromWire` +
   `wireValue`).
2. `UserMessage.toJson()` / `UserInput.fromJson()` already thread the enum —
   no shape change, just the new value.

### App data layer (`app/lib/data/...`)

1. Replace the `bool steering` flag on `MessageRecord` + `UserMsg` with a
   small enum, e.g. `UserMsgDelivery { normal, steer, followUp }`
   (`message_record.dart`, `domain/session_state.dart`). Backward-compat:
   `fromJson` reads the legacy `steering: true` as `steer`.
2. `SyncService.sendMessage(..., streamingBehavior:)`:
   - `followUp` writes an optimistic user row marked `followUp` and sends the
     wire with `streaming_behavior: "followUp"`.
   - Like steer, it must **not** replace `_streaming` / `_workingReplyTo` /
     seed a new cursor — the running turn still owns them.
   - On `UserInput` echo with `followUp`: confirm the row only; do **not**
     start a cursor or change `_workingReplyTo` (same guard as steer today,
     ~line 638).
3. `ChatViewModel.sendMessage` gains a `delivery`/`behavior` param (or the
   InputBar passes it) instead of always deriving `steer` from `isWorking`.

### App UI (`app/lib/ui/chat/...`)

1. `InputBar`: while `streaming == true`, render a segmented
   **[Steer | Follow-up]** toggle above the field. Selection is local state,
   defaults to **Steer**, resets to Steer when a working turn ends. The send
   button + hardware Enter deliver in the selected mode (idle sends are always
   `normal`; the toggle is hidden then).
2. `onSend` threads the chosen `UserMsgDelivery` to `ChatViewModel.sendMessage`.
3. `UserBubble` (`message_bubble.dart`): render a type marker per the chosen
   display language:
   - **Steer** — a route/redirect icon (e.g. `LucideIcons.route` /
     `cornerDownRight`) in accent tint + subtle accent bubble tint; pending
     label stays `steering…`.
   - **Follow-up** — a clock/queue icon (e.g. `LucideIcons.clock` /
     `listTodo`) in muted tint + subtle muted bubble tint; pending label
     `queued · next turn`, becoming a normal confirmed bubble once its turn
     streams.
   - **Normal** — unchanged.
4. Keep offline/disabled behavior unchanged.

## Steps

### Wave 0 — Protocol tests

Projects: `app/`, `pi-extension/`

Files:

- `app/lib/protocol/protocol.dart`, `app/test/protocol_test.dart`
- `pi-extension/src/protocol/types.ts`, `pi-extension/src/protocol/codec.test.ts`

Prove:

- Dart `UserMessage(..., streamingBehavior: followUp).toJson()` emits
  `streaming_behavior: "followUp"`.
- Dart `UserInput.fromJson(...)` parses an echoed follow-up.
- TS fixtures accept `user_message` + echo with `streaming_behavior: "followUp"`.
- Existing `steer` / no-field fixtures unchanged.

Acceptance: new tests fail before impl, pass after.

### Wave 1 — Pi-extension follow-up delivery

Project: `pi-extension/`

Files: `src/index.ts`, `src/extension.test.ts`, `src/protocol/types.ts`

Prove:

- A busy-room `followUp` is **queued**, not injected: `currentTurnId` is
  unchanged; the running turn's later `agent_chunk` still uses the original id.
- When the follow-up's turn streams, `agent_chunk` carries
  `in_reply_to = followUpId`.
- Echo includes `streaming_behavior: "followUp"`.
- An idle-room `followUp` behaves like a normal send (starts a turn, owns the slot).
- Existing steer tests unchanged.

Acceptance:

- `cd pi-extension && corepack pnpm test -- src/extension.test.ts`
- `cd pi-extension && corepack pnpm typecheck`

### Wave 2 — App data layer

Project: `app/`

Files: `lib/data/local/records/message_record.dart`, `lib/domain/session_state.dart`,
`lib/data/sync/sync_service.dart`, `lib/ui/chat/viewmodels/chat_viewmodel.dart`,
`test/data/local/records_test.dart`, `test/data/sync/sync_service_test.dart`,
`test/ui/chat/chat_viewmodel_test.dart`, `test/protocol_test.dart`

Prove:

- `followUp` send writes an optimistic `followUp` row and emits the wire value.
- Follow-up echo confirms the row without replacing the active streaming
  buffer or cancel target.
- When the follow-up's turn streams, the existing `AgentChunk` path seeds its
  own bubble (regression: no special-casing added).
- Legacy `steering: true` rows still parse as `steer`.

Acceptance:

- `cd app && flutter test test/data/local/records_test.dart test/data/sync/sync_service_test.dart test/ui/chat/chat_viewmodel_test.dart test/protocol_test.dart`

### Wave 3 — Composer UI + bubble display

Project: `app/`

Files: `lib/ui/chat/widgets/input_bar.dart`, `lib/ui/chat/chat_page.dart`,
`lib/ui/chat/widgets/message_bubble.dart`, `test/ui/chat/input_bar_test.dart`,
`test/ui/chat/message_bubble_test.dart`

Prove:

- While working, the segmented **[Steer | Follow-up]** toggle is visible;
  hidden while idle.
- Toggle defaults to Steer and resets to Steer when the working turn ends.
- Sending while working delivers in the selected mode (Steer injects,
  Follow-up queues).
- Steer and Follow-up bubbles render their distinct icon + tint; Normal is
  unchanged.
- Stop remains reachable (existing inline-stop behavior preserved).

Acceptance:

- `cd app && flutter test test/ui/chat/input_bar_test.dart test/ui/chat/message_bubble_test.dart`
- Plus the Wave 2 command as regression.

### Wave 4 — Manual smoke

1. Install the debug app on Android.
2. Start a long-running Pi turn.
3. While `Working…`, switch the toggle to **Follow-up**, type, send.
   - Expected: a follow-up bubble (clock icon, muted tint, `queued · next turn`)
     appears; the running turn's bubble is untouched; Stop still cancels it.
4. Let the turn finish. The follow-up's turn starts and streams, attributed to
   the follow-up bubble; it then renders as a normal confirmed bubble.
5. Repeat with **Steer** to confirm unchanged behavior.
6. Confirm a second paired device renders the same type markers from the echo.

## Definition of Done

- [ ] Wire `streaming_behavior` supports `"followUp"` on both sides.
- [ ] Pi-extension queues a busy-room follow-up (not inject), attributes the
      follow-up's turn to the right id, and echoes `followUp`.
- [ ] Idle follow-up behaves as a normal turn.
- [ ] App data layer: follow-up optimistic row + echo confirmation preserve the
      active streaming bubble/cancel target; the follow-up's later turn streams
      into its own bubble.
- [ ] Composer shows the **[Steer | Follow-up]** toggle only while working,
      defaulting to Steer and resetting on turn end.
- [ ] Steer and Follow-up bubbles show distinct icon + tint; Normal unchanged.
- [ ] Stop remains available during working turns.
- [ ] Relevant pi-extension tests + typecheck pass.
- [ ] Relevant Flutter protocol/data/viewmodel/input/bubble/records tests pass.
- [ ] Android smoke verifies steer + follow-up during a real working turn, on
      two paired devices for echo consistency.

## Risks

1. **Turn attribution races** — the extension must set `currentTurnId` to the
   follow-up id before the first chunk of its turn. The queued-message drain
   already does this reliably; reusing that shape is the mitigation. If the
   SDK's own `deliverAs: "followUp"` queue races the extension's slot update,
   fall back to extension-side drain (approach (b)).
2. **Multiple follow-ups** — if the user queues several, they must drain in
   FIFO order, one turn each. Spec the queue as FIFO and test two-in-a-row.
3. **Steer + follow-up interleaving** — a steer arriving after a queued
   follow-up must still inject into the *current* turn, not jump the queue.
   Keep steer on its existing path; only follow-ups go through the drain queue.
4. **`steering` → enum migration** — on-disk rows carry `steering: true`.
   `fromJson` must map legacy `true` → `steer`; test a persisted row.
5. **Crowded composer** — the toggle sits above the field, not in the row, to
   avoid competing with quick-actions/attach/mic/model-send/inline-stop.
6. **Echo on other owners** — all owners must render the same marker from the
   echoed `streaming_behavior`; verify in the two-device smoke.

## Future work

- Consolidate follow-up with the queued-message preview feature if product
  testing shows users want one concept, not two (a committed bubble vs an
  editable draft-for-after).
- Add `"nextTurn"` delivery if a third mode proves useful.
- Persist the user's last chosen mode per session if stickiness is requested.
