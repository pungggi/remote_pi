# 132 — Session-completion notifications (local, over the live relay link)

## Context

User request (2026-08-27): the app should notify when a long-running task
completes, so the user gets the update **even when the app is not open**, with
an **optional per-peered-session switch**.

Why this is achievable without touching closed decisions:

- **Firebase-free stands** (`00-decisions.md`, plan 103/125 section). This plan
  is a **local notification fired over the existing live relay WebSocket** — no
  FCM/APNs, no central push service, no new Google dependency. Plan 36 (FCM via
  publisher-operated central) remains deferred/not adopted; nothing here
  conflicts with it.
- **The process already survives backgrounding** (plan 103 `KeepAliveService` +
  plan 125 cadence): while backgrounded, the Dart root isolate keeps
  `ConnectionManager`/`WsTransport` running, so control frames keep arriving.
  A local notification on that path gives us "app not open → still notified"
  within Android's honest limits.

Facts on the ground (scout 2026-08-27):

- The extension broadcasts `agent_done` on `agent_end`
  (`pi-extension/src/index.ts:2464`) — but the app **drops data payloads for
  non-active rooms** (`ws_transport.dart:140` room demux). Hooking `agent_done`
  alone would only ever notify the session that was open when the app was
  backgrounded.
- **Control frames bypass that demux**: `room_meta_update` (ext → relay) is
  re-broadcast as `room_meta_updated` (relay → app) for **every room of the
  peer**. The app parses it (`protocol.dart:392 RoomMetaUpdated`) with a
  presence-flag convention (`hasModel`/`hasThinking`/`hasGit`/`hasContextUsage`)
  and `connection_manager.dart:902` already keeps per-room `working` state for
  the Home tiles this way.
- The relay **whitelists meta keys** (`relay/src/handlers/peer.rs:366-395`);
  `git` and `context_usage` are established **opaque passthrough** keys — the
  template for one more.
- The app has **no `flutter_local_notifications` yet**; Cockpit pins
  `^22.2.0` and already ships exactly this feature shape
  (`cockpit/.../local_notifier.dart` → `agentFinished(agentName, workspace)`).
- `MainActivity` already has notification-permission method-channel plumbing
  (plan 103). Lifecycle backgrounding is already tracked
  (`keep_alive_controller.dart` `setBackgrounded`, fed from `main.dart`).

## Decisões fechadas (entrevista 2026-08-27)

| # | Decisão |
|---|---|
| 1 | **Coverage: any toggled session of the connected peer** — not just the open one. The completion marker rides the `room_meta_updated` control path (reaches every room). Small change in all three components. |
| 2 | **Trigger: every completion** — the per-session switch is the only gate. No duration threshold (opt-in per session makes noise the user's choice). |
| 3 | **Switch UI: tile long-press menu** (`_showSessionMenu`, `home_page.dart:420`) gains "Notify when finished"; the tile shows a small bell badge when on. |
| 4 | **Local notification only** — derived from the Firebase-free decision; honest limits declared below, not solved here. |

## Non-goals / honest limits (declare, don't hide)

- **Not push.** If Android killed/froze the process — keep-alive off, or
  `whenCharging` (default) while discharging, past the Android-15 `dataSync`
  6h budget, or deep Doze — nothing fires; the user sees the result on next
  open (existing sync). The toggle UI must hint at this ("requires background
  connection") when the current keep-alive mode wouldn't deliver.
- **Only sessions of the currently connected peer** (one peer connection at a
  time in `ConnectionManager`). Toggles on other paired PCs' sessions persist
  and arm whenever that peer becomes the connected one.
- **No notification while the app is foregrounded** (tiles already show
  working→idle).
- **No content in the notification** — title = session display name, body =
  generic "Task finished — tap to open". Same payload discipline as plan 36 §3.
- **`ask_user` / "agent needs you" notification** is a follow-up plan (same
  plumbing, different trigger) — out of scope here.

## Design — one new meta key: `run_done`

`agent_end` fires **once per agent run** (not per LLM call — that's
`turn_end`; plan 36 §C rationale). `working` already flickers per call; the
new key is the run-level "it's your move" signal, so it is named `run_done`,
not `turn_done`, to make that distinction obvious on the wire.

### Wire

```jsonc
// extension → relay (control frame, on agent_end)
{ "type": "room_meta_update", "room_id": "<room>",
  "meta": { "run_done": { "turn_id": "<turn-id|null>", "ended_at": 1735689600000 } } }

// relay → subscribed apps (broadcast; same frame type as today)
{ "type": "room_meta_updated", "peer": "<epk>", "room_id": "<room>",
  "meta": { "run_done": { "turn_id": "<turn-id|null>", "ended_at": 1735689600000 } } }
```

- `turn_id` is **null when the run wasn't app-seeded** (started from the Pi
  terminal / RPC). It still notifies — that's the "kicked off a long task on
  the PC, walked away" case, which pure `agent_done` hooking can never cover.
- **Relay treats `run_done` as opaque, broadcast-only passthrough** (like
  `git`): added to `RoomMetaPatch`, forwarded into the `room_meta_updated`
  broadcast, **not persisted** in `RoomMeta` and **not included** in
  `room_announced` — so reconnects/announce replays can never re-fire a stale
  marker. The unique `ended_at` per run defeats the relay's identical-frame
  dedup (`registry.rs:842`) naturally.
- **App dedup** anyway: volatile in-memory `last (peer, room) → ended_at`
  guard in the notifier (cheap, belt-and-suspenders against re-broadcasts).

## Components & mudanças

### A. Relay (`relay/`) — smallest change

- `src/rooms.rs`: `RoomMetaPatch` gains `run_done: Option<serde_json::Value>`
  (opaque, mirroring `git`).
- `src/handlers/peer.rs` (`room_meta_update` arm, ~:366): parse
  `meta.run_done` into the patch.
- `src/peers/registry.rs` `update_room_meta`: when the patch carries
  `run_done`, include it in the outgoing `room_meta_updated` broadcast JSON;
  **do not store it** on `RoomMeta`.

*Aceite*: unit test — patch with `run_done` produces a broadcast frame
carrying it; identical meta without `run_done` still dedups; stored `RoomMeta`
is unchanged. `cargo test` verde.

### B. Extension (`pi-extension/`)

- In `pi.on("agent_end")` (`index.ts:2464`), right after `_flushAgentChunks()`:
  ```ts
  ext.relay?.sendControl({
    type: "room_meta_update",
    room_id: ext.myRoomId,
    meta: { run_done: { turn_id: ext.currentTurnId ?? null, ended_at: Date.now() } },
  });
  ```
- **Not gated** on `_anyPeerActive()` or `currentTurnId` (terminal-initiated
  runs notify too). One frame per run: queued follow-up drains start a new run
  → its own `agent_end` → its own marker.

*Aceite*: `extension.test.ts` — app-seeded run emits the frame with
`turn_id`; terminal run emits with `turn_id: null`; no frame per intermediate
LLM call; `pnpm test` verde.

### C. App (`app/`) — most of the work

1. **Dependency**: `flutter_local_notifications: ^22.2.0` (same pin as
   cockpit). Android-only paths matter; keep the plugin init defensive.
2. **`NotificationPrefs`** — small durable Hive box (`rp_v2` namespace) keyed
   `<epk>:<roomId>` → `bool`, default off. (Dedicated box, NOT a field on
   `SessionIndexRecord` — the index is derived data; this is user intent.)
3. **Toggle UI**: `_showSessionMenu` (`home_page.dart:420`) gains a
   `SwitchListTile` "Notify when finished"; `session_tile.dart` shows a small
   bell glyph when on. On enable: request `POST_NOTIFICATIONS` (Android 13+)
   via the plugin; if the current keep-alive mode wouldn't deliver in
   background (mode `off`, or `whenCharging` while discharging), show a
   one-line hint linking to the reliability page (same target as the existing
   >60 s banner, `home_page.dart:868`).
4. **`CompletionNotifier`** (new, `app/lib/data/notifications/`): subscribes to
   a new `ConnectionManager` broadcast stream (e.g. `runDoneStream`) — the
   notification logic does NOT live inside `ConnectionManager` (keeps it
   platform-agnostic; mirrors the one-way `KeepAliveController` wiring). Gates,
   in order: toggle on → app backgrounded (lifecycle source already feeding
   `KeepAliveController.setBackgrounded`; expose a tiny shared lifecycle
   signal) → permission granted → dedup. Then `flutter_local_notifications`
   `show`: channel `session-completion` (default importance, sound), title =
   session `displayName` (resolve via ConnectionManager rooms map), body =
   "Task finished — tap to open", payload `<epk>|<roomId>`.
5. **Tap routing**: notification select (cold + warm) → open Home → open that
   session's chat (same path as tile tap).

*Aceite por sub-passo* em "Passos".

### D. Docs

- `PROTOCOL.md`: document `meta.run_done` in the `room_meta_update` section —
  semantics (once per agent run), broadcast-only / never persisted / never in
  `room_announced`, null-`turn_id` meaning.
- App docs (README or in-app changelog, plan 123): honest limits section —
  keep-alive dependency (charging default), 6h `dataSync` cap, Doze, one
  connected peer, old-relay degradation.

## Passos (com critério de aceite)

1. **Relay — `run_done` passthrough** (A). *Aceite*: broadcast carries the
   marker; not stored; dedup intact; `cargo test` verde.
2. **Extension — emit marker on `agent_end`** (B). *Aceite*: testes cobrindo
   app-seeded, terminal-initiated e ausência de marker por LLM call;
   `pnpm test` verde.
3. **App — prefs + menu switch + bell badge** (C.1–C.3). *Aceite*: toggle
   persists across restarts; badge reflects state; permission requested on
   first enable; hint shown when keep-alive mode can't deliver.
4. **App — `CompletionNotifier`** (C.4). *Aceite*: app backgrounded + session
   toggled + run ends ⇒ banner appears with session name; foregrounded ⇒
   nothing; untoggled session ⇒ nothing; duplicate broadcast ⇒ single
   notification; run started from the PC terminal also notifies.
5. **App — tap-to-open** (C.5). *Aceite*: tap opens the right session from
   both cold start and warm background.
6. **Docs + decisions** (D). *Aceite*: PROTOCOL.md updated;
   `00-decisions.md` gains a row in the Background/keep-alive section —
   "completion notifications = local, over live link (plan 132); push/plan 36
   remains deferred" — and this plan referenced.

## DoD

- [ ] 1 — Relay: `run_done` opaque broadcast-only passthrough + tests
- [ ] 2 — Extension: `run_done` on every `agent_end` (null turn_id for terminal runs) + tests
- [ ] 3 — App: `NotificationPrefs` box + long-press switch + tile bell badge + permission flow
- [ ] 4 — App: `CompletionNotifier` (gates + dedup + channel) firing only when backgrounded
- [ ] 5 — App: notification tap routes to the session (cold + warm)
- [ ] 6 — PROTOCOL.md + app docs + `00-decisions.md` row

## Riscos & próximos

- **Relay version skew**: an old relay silently drops the unknown meta key →
  no notifications, everything else works. Graceful; documented. No compat
  negotiation (per YAGNI decision on protocol versioning).
- **`agent_end` on error runs still notifies** ("finished" is truthful — the
  run ended and it's your move). If Pi later exposes run outcome, `run_done`
  gains an additive field; app can then differentiate the copy.
- **Multiple devices on the same owner key** (plan 23 broadcast): each device
  keeps its own `NotificationPrefs` — independent toggles, each notified. Fine.
- **Doze / 6h `dataSync` cap**: unchanged ceiling from plan 125 — documented
  in the toggle hint, not solved here.
- **Future push (plan 36)**: purely additive — a central push path would reuse
  `agent_end` as the trigger and the same per-session toggle; nothing in this
  plan blocks or commits to it.

## Próximos planos

- "Agent needs you" notification (`ask_user` arrival while backgrounded) —
  same plumbing, different trigger (`ask`-shaped inbound frames), same toggle
  or a second one.
- Unread badges on tiles (plan 36 step-6 territory) — separate, derived
  app-side from `lastMessageAt` vs `last_read`.
