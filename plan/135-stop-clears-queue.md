# Plan 135 — A Stop that actually stops (`clear_queue` + abort)

## Context

Pi 0.84.4 added RPC `clear_queue` ([#8432](https://github.com/earendil-works/pi/issues/8432)):
retrieves and clears queued steering/follow-up messages. The RPC docs now state the
trap explicitly: **"abort continues queued messages when they remain in the session."**

Our phone Stop (`cancel` client message → `_abortCurrentTurn`, `pi-extension/src/index.ts`
~4460/4420) only aborts. A steer the user just sent via `deliverAs:"steer"` (plans 43/127)
sits in pi's in-flight queue and fires a **fresh run right after Stop** — the classic
"I stopped it and it started again" papercut.

Verified in the installed SDK (0.84.4):

- `AgentSession.clearQueue(): { steering: string[]; followUp: string[] }` — in-process
  (`dist/core/agent-session.d.ts`), plus `pendingMessageCount` and read-only steering
  getters.
- `ExtensionContext.hasPendingMessages(): boolean` — exposed to extensions.
- `ExtensionAPI` — **no** `clearQueue` (gap; see Task 3).

Scope note: pi's in-flight queue is *different* from our offline queue
(`queued_message_state`, plans 47/127). This plan is about the pi-side queue.

## Expected structure

### Task 1 — Cockpit: Stop clears the queue first (no upstream dependency)

Cockpit is an RPC host (`--mode rpc`, `cockpit/lib/app/core/env.dart`). RPC `clear_queue`
is available today.

- Stop button: send `clear_queue`, then `abort` (the documented interactive pattern).
- Offer the returned texts for restore (composer prefill or toast with "restore"),
  matching pi's own Esc behavior.

**Acceptance:** with a queued steer present, cockpit Stop ends the run and **no** new
run starts; the cleared text is offered back. Test in the cockpit RPC client suite.

### Task 2 — Extension: report queue depth so the app can ask before stopping

- On `cancel` handling and in `room_meta`, expose whether pi has pending messages:
  `ctx.hasPendingMessages()` from the live event ctx (`_liveCtx()`), surfaced as
  `pending_pi_queue: boolean` (or count) in room meta / session_sync snapshot.
- App: when the user taps Stop while `pending_pi_queue` is true, show a confirm sheet —
  "Also discard N queued messages?" (default yes) — then send
  `cancel { discard_queue: true }`.

**Acceptance:** vitest — `cancel` without the flag behaves exactly as today; with the
flag and pending messages present, the queue is cleared before abort. App test for the
confirm sheet gating.

### Task 3 — Get `clearQueue()` into extension reach

Preferred: **upstream PR** to earendil-works/pi exposing `clearQueue()` (and ideally
`pendingMessageCount()`) on `ExtensionAPI`/`ExtensionContext` — natural follow-up to
#8432, trivially reviewable. Until it lands:

- Feature-detect: if the bound `ext.pi` exposes `clearQueue`, use it; otherwise reply
  to `cancel { discard_queue: true }` with `error code: unsupported` and the app hides
  the option (capability handshake via `session_sync`).
- No undocumented internal reaching into the session object — if the method isn't
  public, the feature simply waits for the PR.

**Acceptance:** upstream PR opened (link it here); local code path gated on
feature-detection with tests for both branches.

### Task 4 — Reconcile extension mirrors after a clear

Clearing pi's queue must also fix our mirrors, or the app shows ghosts:

- Drop the matching `_pendingSteers` entries: pi's queue stores **text only**, so match
  by normalized text exactly like `_consumePendingSteerForStartedUser`
  (`pi-extension/src/index.ts` ~672). Unmatched entries stay (they belong to drained
  offline-queue items, not pi's queue).
- Broadcast a new `steer_cancelled { id }` server message per dropped entry (sibling of
  `steer_consumed`) so every owner's "steering…" label clears; app removes the label on
  either frame.
- Re-broadcast `queued_message_state` (unchanged content, but keeps owners consistent).

**Acceptance:** vitest — cleared texts remove the right `_pendingSteers` entries only;
`steer_cancelled` broadcast per entry; app test clears steering labels.

### Task 5 (optional, v2) — Swipe-to-retract a queued steer

`clear_queue` returns all texts; a retract-one flow is clear-all → re-inject the
others via `sendUserMessage({deliverAs:"steer"})`. Only worth it after Task 3 ships
natively; document the round-trip cost (steers re-queue at the back).

## DoD

- Stop from cockpit and (post Task 3) from the phone ends the run with **no** surprise
  re-run when steers were queued; discarded text is recoverable in cockpit.
- No behavior change for plain Stop when nothing is queued.
- All suites green; upstream PR linked.

## Next plans

- 134 shares the status-pill work; after both land, consider a unified
  `state: idle|working|waiting_input|stopping` room-meta field (migration note for the
  relay's typed `RoomMeta`).
