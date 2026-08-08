# 43 — App steering while Pi is working

## Context

Plan 42 fixed generic Android Stop/cancel plumbing. The verified case happened
to be `ask_user`, but the behavior is generic: Stop aborts the current Pi turn
when a real abort context exists.

The next missing mobile behavior is steering: while the app shows `Working...`,
the user should be able to type a correction/instruction and send it to the
active Pi turn instead of being limited to Stop.

Pi already exposes this concept in the SDK/RPC layer:

- `sendUserMessage(content, { deliverAs: "steer" })` in extension API types.
- RPC `prompt` supports `streamingBehavior: "steer" | "followUp"`.

For this plan, the chosen first slice is **steer**, not queued `followUp` and not
a full choose-between-both UI.

## Goal

When the app is connected to a room that is currently working, typing and sending
from the chat composer should deliver the message as `steer` to the active Pi
turn, without clearing the existing streaming bubble and without changing the Stop
cancel target.

## Non-goals

- Do not implement `followUp` UI yet.
- Do not implement full `ask_user` prompt cards.
- Do not change relay behavior.
- Do not remove generic Stop/cancel.
- Do not support steering image attachments in the first slice unless tests show
  the existing attachment path remains trivial to preserve.

## Proposed wire contract

Extend `user_message` with an optional field:

```json
{
  "type": "user_message",
  "id": "cli_...",
  "text": "Use the other file instead",
  "streaming_behavior": "steer"
}
```

Rules:

- Omit `streaming_behavior` for normal idle sends.
- The only value in this slice is `"steer"`; keep the type open enough to add
  `"followUp"` later if needed.
- Pi echoes the accepted `user_message` to all active owners with the same
  `streaming_behavior` so every app can confirm/render the same steering bubble.
- The echoed steering message is a user-history row, not a new assistant reply
  target.

## App behavior

Current app behavior locks the composer while working:

- `InputBar` disables the `TextField` when `streaming == true`.
- The action button becomes Stop before it considers whether text exists.
- `SyncService.sendMessage` always seeds a new streaming cursor and sets the
  working reply target to the new user message id.

Required behavior:

1. While working, keep the composer text field enabled.
2. If text is empty while working, the main action remains Stop.
3. If text is non-empty while working, the main action sends the text as steer.
4. Stop remains reachable while text is non-empty, preferably via a small secondary
   Stop button beside the send button. If layout gets too large, the acceptable
   first fallback is: clearing the text reveals the existing Stop button again.
5. `ChatViewModel.sendMessage` decides whether the send is normal or steer using
   its room-level `isWorking` getter.
6. `SyncService.sendMessage(..., behavior: steer)` writes an optimistic user row
   and sends `UserMessage(streamingBehavior: steer)`, but it must not:
   - replace `_streaming`;
   - change `_workingReplyTo`;
   - seed a new empty streaming cursor;
   - clear or finalize current assistant text.
7. When an echoed `UserInput/UserMessage` has `streaming_behavior: steer`, confirm
   the pending row but do not start a new cursor or change `_workingReplyTo`.

## Pi-extension behavior

Current extension behavior accepts every app `user_message` as a fresh turn:

- Echoes it to all owners.
- Sets `_currentTurnId = msg.id`.
- Calls `_pi.sendUserMessage(content)`.

Required behavior:

1. Extend the protocol type with optional `streaming_behavior?: "steer"`.
2. Echo the optional field back to owners.
3. `_wakeAgent` accepts an optional delivery mode and calls:

```ts
_pi.sendUserMessage(content, { deliverAs: "steer" })
```

   for steering messages.
4. Do not replace `_currentTurnId` for steering messages while a turn is active;
   subsequent `agent_chunk` / `agent_done` must still use the original active turn
   id. This protects the current streaming bubble and Stop target on all phones.
5. Always include `{ deliverAs: "steer" }` on app-originated SDK handoff. The
   SDK ignores it while idle, but requires it if a turn is already running; this
   avoids races where Remote Pi's mirror has not yet seen the active turn.
6. If a reconnecting app sends `streaming_behavior: "steer"` while the extension
   has no mirrored turn id, seed a fallback turn id so chunks/done have a target.
   Also infer steering echo semantics for a plain app `user_message` that arrives
   while the room is already working.
7. For idle messages or normal app messages, keep echo/app behavior unchanged.

## Steps

### Wave 0 — Protocol tests

Projects: `app/`, `pi-extension/`

Files:

- `app/lib/protocol/protocol.dart`
- `app/test/protocol_test.dart`
- `pi-extension/src/protocol/types.ts`
- `pi-extension/src/protocol/codec.test.ts`

Add tests that prove:

- Dart `UserMessage(..., streamingBehavior: steer).toJson()` emits
  `streaming_behavior: "steer"`.
- Dart `UserInput.fromJson(...)` parses echoed steering messages.
- TS protocol fixtures accept app `user_message` with `streaming_behavior: "steer"`.
- Normal `user_message` fixtures without the field remain unchanged.

Acceptance:

- The new tests fail before implementation and pass after protocol changes.

### Wave 1 — Pi-extension steering delivery

Project: `pi-extension/`

Files:

- `src/index.ts`
- `src/extension.test.ts`
- possibly `src/protocol/types.ts`

Add regression tests that prove:

- Idle app `user_message` still calls `sendUserMessage(content)` with no options
  and sets the active turn id to that message.
- Steering app `user_message` calls `sendUserMessage(content, { deliverAs: "steer" })`.
- Steering echo includes `streaming_behavior: "steer"`.
- Steering does not replace the current `_currentTurnId`; a later `agent_chunk`
  remains `in_reply_to` the original active turn id.

Implementation notes:

- Add a small `StreamingBehavior` / delivery-mode helper rather than duplicating
  string checks in the route handler.
- If `sendUserMessage` throws for invalid busy-state delivery, send a correlated
  `error` to the sender and do not claim success.

Acceptance:

- `cd pi-extension && corepack pnpm test -- src/extension.test.ts`
- `cd pi-extension && corepack pnpm typecheck`

### Wave 2 — App data-layer steering

Project: `app/`

Files:

- `lib/protocol/protocol.dart`
- `lib/data/sync/sync_service.dart`
- `lib/ui/chat/viewmodels/chat_viewmodel.dart`
- `test/data/sync/sync_service_test.dart`
- `test/ui/chat/chat_viewmodel_test.dart`

Add tests that prove:

- Sending while `ChatViewModel.isWorking == true` calls `SyncService.sendMessage`
  with steering behavior.
- `SyncService` sends a `UserMessage` with `streaming_behavior: "steer"` for a
  working send.
- Steering optimistic rows are confirmed by echo.
- Steering echo does not replace the active streaming buffer or cancel target.
- Normal idle sends still seed the empty streaming cursor as before.

Implementation notes:

- Add a Dart enum, e.g. `StreamingBehavior { steer }`, mapped to/from wire.
- `ChatViewModel.sendMessage` should pass `StreamingBehavior.steer` when its
  `isWorking` getter is true; otherwise omit it.
- In `SyncService.sendMessage`, branch on behavior before mutating turn state.
- In `UserInput` handling, only call `_setWorking` / `_emitStreaming` for normal
  user input. Steering echo should only confirm/upsert the user row and update
  preview.

Acceptance:

- `cd app && flutter test test/data/sync/sync_service_test.dart test/ui/chat/chat_viewmodel_test.dart test/protocol_test.dart`

### Wave 3 — Composer UI

Project: `app/`

Files:

- `lib/ui/chat/widgets/input_bar.dart`
- `lib/ui/chat/chat_page.dart`
- `test/ui/chat/input_bar_test.dart`

Add tests that prove:

- While working, the text field is enabled.
- While working and text is empty, the existing action is Stop.
- While working and text is non-empty, submitting sends text instead of Stop.
- Hardware Enter while working submits steering text.
- Stop is still reachable while text is non-empty, or clearing text reveals Stop
  if the first implementation keeps a single action button.

Implementation notes:

- Prefer a small secondary Stop button while working + text is non-empty.
- Change the hint from `Waiting for response…` to something like
  `Steer current response…`.
- Keep offline/disabled behavior unchanged.

Acceptance:

- `cd app && flutter test test/ui/chat/input_bar_test.dart`
- Include the Wave 2 app test command as a regression pass.

### Wave 4 — Manual smoke

1. Install the debug app on Android.
2. Start a long-running Pi turn from the app.
3. While `Working...`, type a correction and send it.
4. Expected:
   - the message appears as a user bubble;
   - the current assistant streaming bubble is not reset;
   - the agent incorporates the steering instruction when the SDK can deliver it;
   - Stop still cancels the active turn;
   - no owner sees duplicate/reordered user bubbles.

## Definition of Done

- [x] Mobile protocol supports `streaming_behavior: "steer"` on `user_message`.
- [x] Pi-extension passes steering messages to `sendUserMessage(..., { deliverAs: "steer" })`.
- [x] Pi-extension includes `{ deliverAs: "steer" }` on all app-originated SDK
      handoffs, because the SDK ignores it while idle but requires it if busy.
      It also defensively infers steering echo semantics for plain app messages
      while the room is already working.
- [x] Steering does not overwrite the active turn id used for chunks/done.
- [x] App composer can send text while working.
- [x] App data layer preserves the current streaming bubble/cancel target when a
      steering message is sent or echoed.
- [x] Stop remains available during working turns (empty composer shows Stop;
      clearing typed steering text reveals Stop again).
- [x] Relevant pi-extension tests and typecheck pass.
- [x] Relevant Flutter protocol/data/viewmodel/input tests pass.
- [x] Android smoke verifies steering from the app during a real working turn.
      User verified Android steering works after the installed host package was
      patched and the paired Pi process was restarted. Checklist/results in
      `review/plan43-manual-smoke.md`; debug APK built at
      `app/build/app/outputs/flutter-apk/app-debug.apk`.

## Risks

1. **SDK semantics**: `deliverAs: "steer"` timing depends on Pi internals; Remote
   Pi should only guarantee it passes the mode correctly and keeps UI state sane.
2. **Turn id coupling**: `_currentTurnId` is currently global. Steering must not
   change it until Pi actually starts a new answer target.
3. **Multi-owner UI consistency**: all owners receive steering echoes. App logic
   must treat them as user history rows, not new active replies.
4. **Crowded composer**: keeping both Send and Stop visible on mobile may need a
   small layout adjustment; avoid large redesigns in this slice.

## Future work

- ~~Add `followUp` mode and a user-visible choice if product testing shows both are
  useful.~~ **Done in [plan/127](127-steer-followup-choice.md)** — a segmented
  [Steer | Follow-up] toggle now ships, with an extension-side drain (mirroring
  the queued-message machinery) so a follow-up's turn is attributed to its own
  bubble, plus distinct route/clock markers across owners.
- Add full mobile `ask_user` prompt cards using `extension_ui_request` /
  `extension_ui_response`.
