# 157 — Agent Finding Notifications

> Fork plan. Implementation targets: **`pi-extension/`**, **`relay/`**, and
> **`app/`** (additive protocol change, all three sides).
> Branch: `feat/agent-findings`.
> Concrete driver: the external WhatsApp-monitor project (scheduled agent
> runs classify incoming messages; only actionable ones should alert the
> user's phone). The mechanism is deliberately generic — any agent run,
> interactive or scheduled, may publish a finding.

## Context

Piper already notifies the phone about **run lifecycle** events:

- **Plan/132** — `run_done` room_meta marker → local notification
  "Task finished — tap to open" (per-session opt-in, background gate,
  dedup, permission).
- **Plan/36 / waiting-input** — notifications when a run blocks on input.
- **Plan/153** — UnifiedPush wake so a killed app still learns a run
  finished, reconnects, and syncs.

What does **not** exist is an agent-authored signal:

- `run_done` fires on **every** agent run. A scheduled monitor that runs
  every 15 minutes produces a notification every 15 minutes — pure noise
  for "nothing to report" runs.
- The completion banner is deliberately **content-free** (plan/36 §3
  discipline). The user must open the app to learn what happened.

The missing piece: an explicit, bounded, opt-in "this is worth your
attention **right now**" event that an agent (or a scheduled prompt run)
publishes only when it actually has something to report.

### User decisions for this plan

- **Tool name:** `phone_notify` (action-oriented, matches `show_file` /
  `show_image` naming in this extension).
- **Wake payload policy:** finding wakes carry **IDs only** — no title, no
  body (plan/36 discipline holds; see D2 for the alternatives considered).
- **Default state:** feature ships dark. Per-session toggle, default off.

## Goals

1. New extension tool **`phone_notify({title, body?, severity?})`**,
   callable by the agent — including from scheduled runs — that publishes
   a `finding` event.
2. `finding` is delivered over both existing channels:
   - **Live:** `room_meta_update` broadcast to connected apps (mirrors
     `run_done`).
   - **Wake:** UnifiedPush event for sleeping/killed apps (mirrors the
     `run_done` wake in `relay/src/push/events.rs`).
3. App-side local notification with the **short title** (and body line)
   when received live; a generic "New finding" banner when received via
   wake-only.
4. Gates identical in structure to plan/132: notification permission,
   per-session opt-in, dedup by finding id, background-only.
5. Abuse hardening in the extension: strict payload caps and rate limits
   (the tool input is model-controlled text and therefore a
   prompt-injection surface).
6. Honest tool feedback: the tool result states whether any app was
   connected (same honesty as `show_file`'s "no paired device" result).

## Non-goals

- No in-app findings inbox or history UI in v1 — the notification plus the
  room transcript is the surface. (Follow-up candidate.)
- No notification content in push payloads beyond IDs (see D2).
- No replay/journal persistence of findings on the relay — `finding` is
  broadcast-only exactly like `run_done`.
- No iOS background architecture.
- No email/SMS/WhatsApp-send channels — outbound remains out of scope.
- No read receipts or delivery acknowledgment protocol.

## Design overview

### 1. Extension: the `phone_notify` tool (`pi-extension/src/session/tools.ts`)

Registered alongside the existing agent tools:

```
phone_notify({
  title:    string,  ≤ 120 chars, non-empty, plain text
  body:     string?, ≤ 280 chars, plain text
  severity: "info" | "action"   (default "action")
})
```

Behavior:

- Validates and **clamps** all inputs (never errors on overlong text —
  truncates; errors only on missing title).
- Rate limits, enforced in extension state, reset per agent run:
  **max 5 findings per run, max 20 per hour**. Excess calls return a
  polite failure result instead of publishing.
- Publishes exactly one `room_meta_update` per call (see protocol below)
  and returns `{status: "sent" | "no_device", finding_id}`. `no_device`
  when no app is currently connected — **not** an error; the run continues.
- Strips control characters; plain text only (no markdown rendering
  promises on the notification surface).

### 2. Protocol: the `finding` blob (broadcast-only)

Mirror of `_publishRunDone` in `main.ts`:

```jsonc
// room_meta_update.meta.finding
{
  "id":          "<uuid>",        // client-generated, dedup key
  "turn_id":     "<string|null>", // ext.currentTurnId when available
  "title":       "<≤120 chars>",
  "body":        "<≤280 chars|null>",
  "severity":    "info" | "action",
  "occurred_at": 1699999999999
}
```

- **Broadcast-only.** The relay never persists it (same exception as
  `run_done` in `relay/src/peers/registry.rs`).
- Ephemeral by design: if no app was connected and no distributor wakes
  one, the finding is visible only in the room transcript. This is the
  accepted honesty trade-off of v1 (matches `run_done` semantics).

### 3. Relay (Rust): additive field + wake fan-out

- `relay/src/rooms.rs` — `RoomMetaPatch` gains `pub finding:
  Option<serde_json::Value>` with the **same broadcast-only treatment**
  as `run_done` in `relay/src/peers/registry.rs` and
  `relay/src/handlers/peer.rs`.
- `relay/src/push/events.rs` — new `pub fn finding(peer, room, event_id,
  occurred_at)` mirroring `run_done(...)`: sends the UnifiedPush wake to
  registered endpoints of subscribed peers. Payload contains **IDs only**
  (`v`, `event: "finding"`, `event_id`, `peer`, `room`, `occurred_at`) —
  no title/body ever enters the push path.
- Verify serde tolerance on old peers: unknown meta fields must be
  ignored, `PushEventType.fromWire` on an old app returns null for
  `"finding"` and drops it gracefully.

### 4. App (Dart): `FindingNotifications` facade

New facade in `app/lib/data/notifications/finding_notifications.dart`,
structurally a sibling of `SessionCompletionNotifications` (plan/132):

| Gate | Behavior |
|---|---|
| Permission | Notification permission granted (requested on first toggle-on) |
| Opt-in | Per-session toggle, own Hive key `finding_prefs` (default **off**) |
| Background | Fires only while backgrounded (foreground: the open room already shows the agent message; a banner would be noise) |
| Dedup | By `finding.id` (volatile map — broadcast is never replayed) |
| Channel | New `findings` notification channel, configurable sound |

Delivery paths:

- **Live** (WebSocket connected): full notification —
  `<session title>: <title>` + body line. Tap → session (existing deep
  link).
- **Wake** (UnifiedPush woke a killed app): reconnect + sync per plan/153
  discipline, generic notification `"<session>: New finding — tap to
  open"`. Content comes from the transcript after sync, never from push.

`PushPayload` (`app/lib/data/push/push_payload.dart`): add
`PushEventType.finding('finding')`. The `_wakeKeys` whitelist stays as-is
— the finding wake uses only already-permitted keys.

### 5. Abuse hardening (why the caps matter)

`phone_notify` input is model-generated text. A scraped message (e.g.
WhatsApp content ingested by a monitor run) could contain
prompt-injection attempting to spam the phone. The extension therefore:

- Enforces the rate limits **before** publishing (section 1).
- Caps lengths at the tool boundary, not the UI.
- Allows no URLs/actions in the notification beyond tap-to-open-session.
- Keeps severity a closed enum (no "critical" escalation semantics in v1).

## Test plan

- **Extension (vitest, patterns `extension.test.ts` / `show_file.test.ts`):**
  tool schema validation; truncation at caps; rate-limit behavior (5th
  ok, 6th rejected within one run); `no_device` result shape; published
  frame matches the blob spec; control-char stripping.
- **Relay (Rust, patterns around `handlers/peer.rs` / `push/events.rs`):**
  `finding` patch is broadcast and **not** persisted; wake fan-out to
  registered endpoints; old-peer tolerance of the unknown field.
- **App (patterns from the plan/132 facade tests):** gate matrix
  (permission × toggle × background × dedup); live payload rendering;
  wake-only generic banner; `PushEventType.fromWire('finding')` parse.
- **E2E manual (the driver):** WhatsApp-monitor scheduled run →
  `phone_notify` on an actionable finding only → verify notification in
  all three app states (foreground-suppressed, background-live,
  killed+UnifiedPush).

## Rollout

1. Merge relay change first (additive, harmless when unused).
2. Extension change next (tool exists, publishes; old relays drop the
   unknown field — verify serde default).
3. App change last; toggle appears as a per-session "Findings" switch
   next to the completion bell.
4. Flip the WhatsApp monitor's job prompt from `show_file`-only to
   `phone_notify` (+ keep the markdown report as the on-open artifact).

## Open questions

- **D1 — tool name.** `phone_notify` chosen; alternative was
  `notify_finding`. Reversible cheaply (tool rename before any external
  caller depends on it).
- **D2 — wake payload policy.** Options: (a) IDs-only (chosen — privacy
  discipline, zero push-content risk), (b) bounded encrypted title in
  push, (c) seq-journal replay of findings after wake. (c) is the
  follow-up if "generic banner on wake" feels too lossy in practice.
- **D3 — toggle UX.** Separate `Findings` switch vs. merged "Session
  alerts" section (completion + findings behind one bell). Kept separate
  in v1 for independent opt-in; merge is a UI-only follow-up.
- **D4 — rate-limit defaults.** 5/run · 20/h proposed; needs a feel test
  with the real monitor cadence (15-minute runs) before hardening.

## Suggested implementation order

1. Relay: `RoomMetaPatch.finding` + `push::events::finding` + tests.
2. Extension: `phone_notify` tool + publish + tests.
3. App: `PushEventType.finding` + `FindingNotifications` facade + tests.
4. Toggle UI (per-session, default off).
5. E2E with the WhatsApp monitor; tune D4 defaults from real usage.
