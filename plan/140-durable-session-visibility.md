# Plan 140 — Durable session visibility (the general fix for "missing messages")

## Context

Plans 138/139 debugged two incidents down to root causes. The pattern behind
ALL of them — and behind the user's question *"gibt es keine allgemeine,
stabile Lösung?"* — is one architectural coupling:

> **The phone's chat history is only reachable while the target session's
> daemon is live in the right room.** Rooms are cwd-derived and go dark for
> many reasons (session closed, crash, socket wedge, PC reboot, session
> restarted from a different cwd — observed live on 2026-09-08: a restart
> moved a session from room `Agq7sYHlSb_l` to `9eop1AlMNpyu` and the phone
> chased the ghost). While a room is dark, syncs are **silently dropped**,
> the app freezes mid-chat, and no restart on either end explains anything.

Observed failure modes (all verified in `relay.log` / `watchdog.log`):

| Mode | Effect on phone |
|---|---|
| Session closed / not yet started after boot (6:44 min gap) | syncs dropped, chat frozen |
| Daemon relay-socket wedge (2026-09-05: 16 min dark) | turn tails lost, chat frozen |
| Session restarted in a different cwd | room id changes; old chat points at a ghost |
| App open while room dark | infinite invisible ~30 s retries, no error shown |

The durable truth is already on disk: `~/.pi/agent/sessions/<cwd>/*.jsonl`
(plan 128). Nothing reads it when the room is dark.

## Principle

**History is durable; presence is optional.** The phone can always read every
session's full history, and always *sees* whether a session is live — no
dependency on daemon uptime, room liveness, or restart luck.

## Design

### A — Supervisor as history authority ("room keeper") — the core

`pi-supervisord` is the one component that is ALWAYS up (watchdog-guarded,
verified: restarts in ≤ 60 s). It gains a **keeper** role:

- **Room registry:** every daemon registers `(room_id, cwd, session_started_at)`
  with the supervisor on start (UDS, already connected). Supervisor also
  derives rooms from `~/.pi/agent/sessions/*` (cold start, no daemons yet).
- **Keeper connections:** for every registered room that has NO live daemon,
  the supervisor holds one lightweight relay WS in that room (same PC pubkey).
  It answers exactly one client message: `session_sync` → served from the
  durable `.jsonl` via the SAME paging code the ext uses (`_pageHistory`,
  extracted to a shared module). Replies carry `offline: true` +
  `session_started_at` so the app can badge the chat.
- **Yield on live daemon:** keeper connect attempts that hit
  `RoomAlreadyOpenError` = the real daemon is back → keeper closes and marks
  the room live. The reverse handshake already exists (RoomAlreadyOpen).
- Result: `dest (peer, room) not found` becomes impossible for any room that
  ever existed on this machine. The relay stays stateless (00-decisions).

### B — Relay: `route_error` instead of silent drop

Undeliverable data frames (dest not found) get a rate-limited (per peer+room,
1/min) `route_error` reply to the sender. The app-side handler from **plan 137
already exists** (⚠ "Not delivered — Pi unreachable") — today the relay simply
never sends it on this path. Also log the WS close code on `disconnected`.

### C — App: honest session state (never a silently frozen chat)

- Session list = rooms presence + keeper-served rooms (offline badge,
  "Stand HH:MM"); a chat against a dark room shows a persistent
  **"Pi offline"** banner instead of invisible retries.
- `run_done` without matching `agent_done` → debounced `requestSync()`
  (plan 139 G2 — heals lost tails regardless of cause).
- **Room-adoption for the cwd-change case:** when a room disappears and a new
  room appears for the same peer with the same project name (room_meta),
  offer/auto-adopt it as the continuation of that chat (history merged from
  the durable store; the old room's keeper keeps serving its history).

### D — Ext daemon reliability (close the wedge class)

- Relay-socket liveness watchdog: no inbound frame for 70 s while "connected"
  → force-close + reconnect (mirrors the app's plan-114 watchdog). Test:
  kill the socket mid-turn → reconnect within ≤ 30 s backoff.
- Daemon-side connect/close/reject log with reasons →
  `~/.pi/piper/ext-<room>.log` (makes every future incident explainable).
- Boot ordering: supervisor brings keeper rooms up **before** daemons so the
  phone's first post-boot sync never races (the 6:44 min gap).

## Steps

1. Extract `_pageHistory` + file-index into a shared module (`src/session/`)
   usable by both ext daemon and supervisor. No behavior change; tests green.
2. Relay B (route_error + close-code logging) — small, ship first.
3. Supervisor keeper A (registry → keeper connections → sync handler →
   yield-on-live). Integration test: stop a daemon, phone sync still answers
   with full history + `offline:true`; restart daemon, keeper yields.
4. App C (offline badge, run_done→sync, room adoption).
5. Ext D (watchdog + logging + boot order).
6. Field test matrix: reboot PC mid-conversation; close session; restart in
   different cwd; wedge the socket — phone must always show full history and
   an honest live/offline state.

## Acceptance criteria

- [ ] Phone shows **full history** for a session whose pi is NOT running.
- [ ] Restarting a session in a different cwd keeps one continuous chat.
- [ ] No `dest not found` drops for known rooms in `relay.log` anymore.
- [ ] Wedged socket self-heals ≤ 30 s; every connect/close is logged.
- [ ] `cargo test`, `tsc --noEmit`, `dart analyze lib test` clean.

## DoD

"Letzte Nachricht fehlt" is structurally impossible: history never depends on
presence, and every unreachable state is visible on the phone within seconds.

## Next

- 115c endpoint badge merges into C (one visibility pass).
- 139's G1/G2/G3 are subsumed by D/C/B here.
