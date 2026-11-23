# 170 — Pending-ask fanout via the device room

## Problem

Reported (2026-11-23): *"the user tool does not work and does block the chat."*
When an agent in an interactive Pi session calls `ask_user` (pi-ask), the phone
app frequently never shows the clarification sheet, and the chat wedges until
the user answers at the desktop terminal.

Forensic evidence (pi-context-engine session, 2026-11-22/23):

- 00:37 ask → answered in **64 s** (phone was in that chat — live path works)
- 01:19 ask → answered at **07:20** (**6 h wedge** — recovered only via full
  app relaunch + re-pair + chat open)

## Root cause

The app holds ONE connection and switches rooms (`_conn.switchRoom(...)`).
`SyncService.requestSync()` syncs only `_activeRoomId`. So a pending
`extension_ui_request` in a room the phone is not currently attached to has
**no delivery path at all**:

- **Live frame** — only reaches the open chat's room.
- **Resume re-sync** (main.dart, 2026-08-21) — re-syncs the open chat only.
- **Relaunch replay** (plan/129) — works, but requires a full relaunch AND
  opening that exact chat. That is why the 01:19 ask surfaced only at 07:20.

Plan/129 fixed the app-side persistence of the request for the *open chat*
case; it cannot help when the ask fires in a different session than the one
on screen. Plan/134's waiting-for-input notifications have the same room
scoping.

## Decision (closed with the user, 2026-11-23)

**Device-room fanout.** The phone keeps an always-on home-base channel on the
`device` room (Home/Projects views). When an ask flow opens in ANY
interactive session, the PC pushes a tiny notice into the `device` room; the
app raises a notification; tapping it opens that chat, where the existing
plan/100/129 replay machinery shows the sheet.

Rejected alternatives:

- **All-rooms attach** (phone subscribes every paired room): most immediate
  UX, but multiplies background sockets/traffic per session — plan/125
  battery territory.
- **Resume-sync all paired rooms**: cheapest, but still silent while the
  phone is locked or the user is elsewhere in the app.

## Architecture

```
ask flow opens (pi-ask :started)
  → extension_ui_bridge hook fires with flow details
  → session extension sends $rp_control {op: "ask_notice"} to the `device`
    peer via the UDS mesh (plan/161 envelope, peer.request)
  → device daemon's _handleControlEnvelope branch broadcasts a
    `pending_ask` ServerMessage into the device room via _broadcastToActive
    (journaled by the plan/145 ledger → report_seq replays it to a phone
    that re-attaches later)
  → phone (home-base channel) shows a notification + Home badge
  → tap → open chat (plan/132 _openFromCompletionTap pattern) → attach →
    session_sync → pendingRequests replay → sheet
```

Flow closed (answered/cancelled/disposed/TTL) → `ask_notice {open: false}`
→ `pending_ask` clear frame → phone dismisses badge/notification.

Why the daemon and not a second relay connection from the session: the
device daemon already owns the `device` room (its broadcasts ride the
ledger/journal machinery), the mesh `$rp_control` path is already trusted
same-machine IPC (plan/161), and no new relay trust boundary is opened.

## Wire

New `$rp_control` op (pi-extension `protocol/types.ts`):

```
RpControlOp += "ask_notice"
$rp_control: {
  op: "ask_notice";
  open: boolean;          // true = flow opened, false = cleared
  room_id: string;        // the session's App↔Pi room (announcement room)
  flow_id: string;
  title?: string;
  question_count?: number;
}
```

New ServerMessage (device room only):

```
pending_ask {
  type: "pending_ask";
  room_id: string;        // which session is asking
  flow_id: string;
  open: boolean;
  title?: string;
  question_count?: number;
  ts: number;
}
```

Idempotent by `(room_id, flow_id)`; ordering by the ledger's (epoch, seq)
means a replayed clear wins over an older open. PROTOCOL.md gains both.

## Implementation map

pi-extension:

- `protocol/types.ts` — op + ServerMessage + docs.
- `extension_ui_bridge.ts` — as-built: per-flow lifecycle hook
  (`onFlowLifecycle(ev: FlowLifecycleEvent)` with `phase`
  open/close/dispose, `flowId`, `toolCallId`, `title`, `questionCount`).
  Dispose fires a close PER flow (snapshot-before-clear), not a clear-all
  snapshot. The boolean `waiting_for_input` transition is kept as-is.
- `main.ts` — `_recreateExtensionUiBridge` wiring: the lifecycle events
  drive `ask_notice` opens/closes directly (no snapshot diffing); sent to
  the mesh peer `device` via `peer.request` with a short timeout,
  log-only failures (the ask itself must never depend on the fanout).
  Daemon side: `_handleControlEnvelope` branch for `ask_notice` →
  `_broadcastToActive(pending_ask)` (device-room guard + kill-switch +
  field validation; as-built r2: receiving-side room validation is
  intentionally NOT added — the UDS mesh is machine-local and peers past
  it already hold stronger `session_control` ops).
- Tests: bridge lifecycle hook (open/close/dispose-per-flow), envelope
  handler broadcast, op validation (mirror `delivery_ledger.test.ts`
  fakes).

app:

- `protocol/protocol.dart` — `PendingAsk` ServerMessage + fromJson +
  `PendingAskEvent` (peer-attributed).
- `connection_manager.dart` — `pendingAskStream`: frames are attributed to
  the channel's peer in `_watchChannel` (the only place that knows it) and
  ONLY forwarded while the channel is parked in the `device` room
  (as-built r2 guard, review #117).
- New `PendingAskNotifications` (data/notifications) — subscribes to
  `ConnectionManager.pendingAskStream`; keeps
  `Map<<stdB64(epk)>:<roomId>, Set<flow_id>>` badges; persists to the
  runtime box (relaunch keeps badges until cleared); events observed
  before the persisted load finishes are buffered and replayed (as-built
  r2, review #117). Exposes `isAsking` + a broadcast `changes` stream.
- Notification via `LocalNotifications` (stable FNV-1a id per canonical
  key — replaces, never stacks; cancelled on clear). Payload reuses the
  plan/132 canonical key `<stdB64(epk)>:<roomId>` VERBATIM, so the
  existing completion-banner tap routing opens the chat with zero new
  plumbing (no separate `_openFromCompletionTap` mirror needed).
- `main.dart` — attach + the stale-badge self-heal wiring
  (`SyncService.onSyncSettledWithoutAsk` → `clearRoom`).
- Home session tile: amber slot color via `isAsking` (the plan/149 slot
  owns the status color now — the old dot is gone).
- Self-heal: when a chat attaches and `session_sync` returns NO pending
  `extension_ui_request` for a room the badge says is asking, clear the
  badge (stale-notice recovery without waiting for a clear frame).
  As-built: armed on every newest-page eos with a 1.5 s grace that
  re-checks room + pending request under the timer.
- `flutter analyze` 0 errors; new tests for the service
  (open/clear/replay-dedup/persistence/start-window-buffer/self-heal)
  following plan/129's test style, plus a ConnectionManager guard test
  (device-room-only forwarding).

## Limitations (accepted)

- **Device daemon dark** → no fanout (mesh peer gone). The phone already
  shows the plan/168 "device daemon offline" self-repair affordance; fixing
  that path is plan/168 + watchdog territory, not this plan's.
- **Keeper-held device room**: control-only presence does not broadcast
  notices (it cannot know about flows). Same limitation as above.
- The notice is a *hint*, never the source of truth: the sheet still comes
  from the session room's own `session_sync` replay.

## Acceptance (DoD)

1. Ask fires in session X while the phone sits on Home with the app
   backgrounded → notification appears within seconds; badge on X's tile.
2. Tap → chat X opens → sheet appears (existing replay) → answer → chat
   unblocks; badge + notification cleared (clear frame or self-heal).
3. Ask answered at the desktop instead → clear frame cancels the
   notification and badge on the phone without opening the chat.
4. Frames missed while the phone was attached to another chat are replayed
   on re-attach to the device room (ledger report_seq) without duplicate
   notifications (dedupe by `(room_id, flow_id)`).
5. No pi-ask installed → nothing fires anywhere (bridge inert, plan/100
   invariant preserved). No daemon/keeper → no crash, log-only.
6. `flutter analyze` 0 issues; extension vitest suite green; PROTOCOL.md
   updated.
