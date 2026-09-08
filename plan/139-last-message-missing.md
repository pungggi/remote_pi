# Plan 139 — "Newest agent reply missing in the app"

## Context

Reported symptom (2026-09-05): on the phone, the chat shows the agent's older
replies but the **newest reply is missing** — for several turns in a row.
Everything else works (messages reach the Pi, older history renders).

### Evidence gathered live (2026-09-05 … 2026-09-08 debug sessions)

| # | Finding | Source |
|---|---|---|
| 1 | Durable transcript is **complete and current** (all turns incl. the "missing" replies) | tail of `~/.pi/agent/sessions/--C--…--/2026-09-05T13-24-04-…jsonl` |
| 2 | App **does** heal on reconnect: `requestSync()` on every `_onlineActivated` (sync_service.dart:736), durable merge dedups (plan 128); sync retries every ~30 s while pending | code + relay drop cadence |
| 3 | **09-05:** both ext daemons logged `disconnected` at the **same millisecond** (15:37:40) and stayed off the relay **16 min** despite the 30 s-capped reconnect backoff — the *wedge*: process alive, relay socket dead, no reconnect. Turn tails broadcast into the void | `relay.log` |
| 4 | **09-08 (post-reboot, boot 04:22):** the phone's reopen test (04:24–04:25) raced this session's daemon being **6:44 min late** (auth 04:31:39). Every `session_sync` in the window: `dest not found, dropping` | `relay.log` 02:24:37Z |
| 5 | **The phone's ACTIVE chat is a different session:** room `Agq7sYHlSb_l` = cwd **`C:\Users\Alessandro\source`**. Its holder authed at boot 04:23:30, **died 04:30:02, never returned**. The phone retried `session_sync` into that dark room every ~30 s for 30+ min — all silently dropped | `relay.log` + `scripts/map-rooms2.js` |
| 6 | `room=main` in every phone auth is **by design** (`ws_transport.dart:257` hardcodes the hello room; routing is per-envelope room-scoped, not per-socket) — ruled out as a cause | code |
| 7 | `agent_done.text` tail-heal exists but is conservative: only heals a strict prefix-extension **when chunks were seen in-process**; frames lost while the socket was dead are left to `session_sync` | `_reconcileTurnText` (sync_service.dart:1750+) |
| 8 | The relay **silently drops** undeliverable data frames (`dest not found`). Plan 137 already added app-side `route_error` handling (⚠ "Not delivered — Pi unreachable") — but the relay never *sends* `route_error` on this path | `handlers/peer.rs` vs plan 137 |
| 9 | Supervisor/self-healing works: killing the wedged daemon + supervisor → watchdog restarts both in ≤ 60 s | verified live 09-08 05:23 (`watchdog.log`) |

### Causal chain (confirmed)

```
pi session dies / relay socket wedges (no reconnect)
  → its room goes dark; the app's session_sync retries are silently dropped
  → newest replies arrive neither live NOR via sync
  → app shows a frozen chat ("letzte Nachricht fehlt"), app restart doesn't help
```

Three gaps keep this class alive:
- **G1 (ext):** a wedged relay socket isn't detected/reconnected (16 min
  absence on 09-05; dead-at-04:30 room on 09-08) and nothing explains it —
  no daemon-side connect/close logs.
- **G2 (app):** `run_done` (room_meta control frame, bypasses room demux)
  for a room whose turn never delivered `agent_done` triggers nothing. That
  combination is a certain missed-tail marker and should force a sync.
- **G3 (relay):** undeliverable data frames vanish silently. A `route_error`
  reply would let the app show "Pi unreachable" instead of a frozen chat
  (plan 137's app-side handler already parses it).

## Steps

1. **DONE (user triage 09-08):** reopen did **not** heal — because the reopen
   window raced a late daemon AND the phone's active chat targets a dead
   session (findings 4–5). Healing requires the target pi session to be
   running and relay-connected; then the phone's ~30 s sync retry heals the
   chat with no app-side change.
2. **App: `run_done` without `agent_done` ⇒ `requestSync()`** (G2 — closes
   the class regardless of *why* data frames were lost). In
   `ConnectionManager`/`SyncService`: on `RoomMetaUpdated` carrying
   `run_done` for a room that had a working turn with no matching
   `agent_done`, fire a debounced `requestSync()`. Unit-test with an injected
   `RoomMetaUpdated`.
3. **Relay: `route_error` instead of silent drop** (G3). On an undeliverable
   data frame (dest not found), reply `route_error` to the sender (rate-
   limited per (peer, room), e.g. 1/min) so the app can surface "Pi
   unreachable" — the plan-137 app handler already renders it. Include the
   WS close code in the `disconnected` log line while there.
4. **Ext: relay-socket liveness + observability** (G1). Verify the 70 s
   inbound watchdog actually covers the relay WS (force-kill the socket in a
   test and confirm reconnect ≤ 30 s backoff). Log every relay connect/
   disconnect/reject with reason to `~/.pi/piper/ext-<room>.log`. Explain the
   09-05 simultaneous double-daemon drop + 16-min absence.
5. **Boot-order:** daemon reconnect after reboot took 6:44 min for this
   session — check the supervisor's startup sequencing (lazy backoff? waiting
   on something?) so post-reboot windows don't shadow the phone's first sync.

Helper scripts already in `scripts/`: `inspect-session-tail.ps1`,
`inspect-relay-now.ps1`, `phone-room-history.ps1`, `map-rooms.js`,
`map-rooms2.js`, `check-relay-alive.ps1`, `check-paths2.ps1`.

## Acceptance criteria

- [ ] Reopen test: the missing reply appears after an app restart.
- [ ] Kill the ext↔relay socket mid-turn (e.g. `schtasks /End /TN "Piper
  Relay"` for 5 s while a turn runs) → after both sides reconnect, the app
  shows the full final reply **without manual reload** (run_done → sync).
- [ ] Daemon-side relay log exists and explains connect/disconnect timing.
- [ ] `dart analyze lib test` clean; new unit test green; relay rebuilt.

## DoD

The "newest reply missing" class is closed on both ends: the app self-heals
from any lost turn tail (run_done trigger), and ext/relay logs make the next
socket incident explainable within minutes.

## Next

- Plan 115c endpoint badge + `scripts/check-piper-stack.ps1` (plan 138) —
  visibility so a dead serve mapping or flapping socket is *seen*, not inferred.
- Consider a manual "refresh" affordance in chat (triggers `requestSync()`),
  the cheap escape hatch while G1/G2 land.
