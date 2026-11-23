# Plan 168 — Device daemon: self-healing + app-triggered repair

## Context

Incident of 2026-11-22 (host `CHICO`, 17:38→23:11 local): the device daemon
(`pi --mode rpc --name device`) wedged. The relay dropped its peer, the daemon
never processed the close (no `relay-closed`, TCP stayed ESTABLISHED), and the
registry's `device` `lastSeenAt` froze at 17:38. The phone's Projects screen
showed "Device unreachable / offline" for 5.5 hours while chat and every live
session kept working. Manual fix: kill the pid → supervisor respawned in ~1 s.

Four gaps let this happen and made it unrepairable from the phone:

- **No listener in a dark `device` room**: the keeper explicitly skips
  `DEVICE_ROOM` (`room_keeper.ts`, registry filter `e.roomId !== DEVICE_ROOM`).
  When the daemon dies, the room is empty — nothing answers the app.
- **No wire path that reaches a wedged daemon**: `session_shutdown` and every
  other control verb run *inside* the target's pi process. A wedged event loop
  never processes them. Only an external kill works.
- **Supervisor detects death, not wedging**: RpcChild restart fires on exit;
  a hung-but-alive child is invisible.
- **Watchdog checks existence, not health**: `Test-DeviceDaemon` matches the
  process (2026-11-16 addition) — `device=OK` all night while the room was
  dark. The app's own error conflates "phone offline" with "daemon dead".

The repair vehicle already exists: the RoomKeeper (plan/140A) runs inside the
supervisor, opens lightweight relay connections for dark rooms, receives
client messages, and yields via the `RoomAlreadyOpen`/`dropRoom` handoff when
a real session claims the room.

Decisions (user, 2026-11-23): **full stack** (all layers below) and app UX
**auto-repair once, then button**.

## Expected structure

```
pi-extension/src/protocol/types.ts        ClientMessage + daemon_control;
                                          reply reuses action_ok/action_error
pi-extension/src/session/room_keeper.ts   claim DEVICE_ROOM control-only;
                                          serve daemon_control via supervisor
                                          callback; never publish room_meta
pi-extension/src/daemon/supervisor.ts     onDaemonControl callback (kill by
                                          pid + force respawn, plan/159 kill
                                          path); rpc-child ping loop
pi-extension/src/daemon/control_protocol.ts  child_ping / health ops (extend
                                          plan/159 step-1 surface)
pi-extension/src/main.ts                  daemon extension: refresh registry
                                          lastSeenAt on the periodic tick
pi-extension/scripts/watchdog*            shipped watchdog (plan/159 step 7):
                                          supervisor health probe + device
                                          lastSeenAt staleness → bounce
app/lib/protocol/*                        daemon_control encode + reply parse
app/lib/data/actions/actions_repository.dart  restartDeviceDaemon() +
                                          deviceStatus()
app/lib/ui/projects/projects_viewmodel.dart   repair state machine (auto
                                          once → button fallback)
app/lib/ui/projects/projects_page.dart    diagnosis line + repairing note +
                                          Retry restart button
PROTOCOL.md / docs/daemon.md / CHANGELOG.md (root + app)
```

Relay: **no changes** — multi-peer room broadcast already fans the op out to
keeper + daemon, and opaque-passthrough stays intact.

## Design notes

- **Keeper in `device` is control-only.** It holds the dark room so the
  supervisor is reachable, announces no `room_meta`, serves nothing except
  `daemon_control`. A live daemon claiming the room triggers the existing
  keeper yield — zero conflict with plan/120/124 semantics, and plan/120's
  Home filter already hides the room from the session list.
- **`daemon_control {id, op: "restart" | "status", daemon?: "device"}`**
  replies `action_ok {id, result}` / `action_error {id, message}` — the same
  id-matched reply shapes plan/166 uses for control envelopes, so the app's
  existing dispatch matches replies without new plumbing.
  - `restart`: supervisor kills the fleet child by pid (stale-wedge kill,
    same as plan/159 "force spawn"), cancels backoff, respawns. Ack lands
    after the new child is spawned, *before* its relay hello — the app's
    retry of `list_projects` therefore tolerates one timeout and retries
    once more (documented behavior, not a bug).
  - `status`: fleet row (pid, state, uptime, lastSeenAt age). Feeds the app's
    diagnosis line when the room is dark but the supervisor is alive.
- **Trust model unchanged**: `daemon_control` rides the same paired-peer relay
  auth as every other client message and honors the existing
  `allow_remote_session_control:false` kill-switch (2026-11-08 ungated
  decision + switch; would only reopen explicitly).
- **Ping loop targets the loop, not the room**: supervisor pings each rpc
  child over its pipe every 30 s (a busy turn keeps the node loop alive, so
  pings answer during long runs). Two consecutive misses → kill + respawn +
  log transition. This is the only layer that catches a wedged child with the
  relay fully down.
- **`lastSeenAt` becomes a real heartbeat**: today it only moves on (re)connect
  (a healthy daemon connected for hours reads as "stale"). The daemon
  extension therefore refreshes it on its existing periodic tick (piggyback
  the git-poll 60 s cycle, no new timer). Only then does staleness mean
  "daemon↔relay path dead", which is exactly what the watchdog checks.
- **Layer order**: supervisor ping (fastest, no relay needed) → app
  `daemon_control` (works whenever relay + supervisor live, daemon wedged) →
  watchdog (catches a *wedged supervisor* via pipe `health` probe, and
  end-to-end path death via `lastSeenAt`).

## Steps

1. **Wire type** (`types.ts`): `daemon_control` ClientMessage + result bag on
   `action_ok`; update the control-verb docs comment.
   - AC: tsc exhaustive switches point at every place to extend; app path
     compiles untouched (additive).

2. **Keeper control presence** (`room_keeper.ts` + `supervisor.ts`):
   - Remove the `DEVICE_ROOM` skip; claim it with `controlOnly: true` —
     connect with **no** `roomMeta`, no registry write from the keeper side.
   - `_onClientMessage`: case `daemon_control` → `onDaemonControl(op)` callback
     (injected by Supervisor); wrap in try/catch → `action_error` on throw;
     unknown op → typed error reply. Non-device rooms keep the read-only
     `session_sync`-only contract.
   - AC (unit): keeper claims device when dark; serves restart (asserts
     callback invoked + `action_ok` reply); refuses when kill-switch set;
     ignores `daemon_control` on session rooms; yields room on real-session
     hello (existing tests extended).

3. **Supervisor restart + ping loop** (`supervisor.ts`, `control_protocol.ts`):
   - `onDaemonControl("restart")` → force path: kill child pid, cancel backoff,
     spawn; log `[supervisord] daemon_control restart (via relay)` with before/
     after pids. Reuse plan/159 step-1 kill machinery.
   - Ping loop: every 30 s, per running child, `child_ping` over the pipe;
     2 misses → bounce + transition log (mirror watchdog log style). Skip
     while a spawn is in flight.
   - AC (unit, fake timers): wedged child (no ping reply) bounced after ~60 s;
     healthy child untouched across N cycles; restart op respawns exactly one
     child; two rapid restart ops coalesce (second is a no-op while spawning).

4. **Registry heartbeat** (`main.ts`): daemon extension refreshes
   `lastSeenAt` for its room on the periodic tick (share the 60 s git-poll
   timer; registry write helper already exists via `_registerRoomForKeeper`).
   - AC (unit): tick calls registry refresh; write failure swallowed (best
     effort, never fatal).

5. **Watchdog** (`scripts/` shipped watchdog per plan/159 step 7; sync the
   host's out-of-repo `piper-watchdog.ps1` manually in the same change):
   - New checks: supervisor pipe `health` op probe (wedged supervisor →
     restart it); `rooms.json` `device` `lastSeenAt` older than 5 min →
     bounce the device child (supervisor respawns). Log both transitions.
   - AC: manual replay of the 2026-11-22 incident (kill nothing, SIGSTOP the
     daemon process) produces one `stale lastSeen → bounced` line within one
     cycle; relay/supervisor green stays log-clean.

6. **App transport + actions**: `daemon_control` encode (protocol), reply
   parse; `restartDeviceDaemon()` / `deviceStatus()` in `ActionsRepository`
   via `_dispatch` (15 s default timeout).
   - AC (unit): request builds with id; `action_ok` result parses;
     `action_error` surfaces message; unknown-op reply → typed failure.

7. **App repair UX** (`projects_viewmodel.dart`, `projects_page.dart`):
   - Error states gain diagnosis: phone offline (`_conn.status` not online) →
     "No connection to relay", no repair; room dark → "Device daemon
     offline on <peer>", repair available.
   - Auto-repair ONCE: on entering the daemon-dark error, start a 10 s grace;
     if still dark, fire `restartDeviceDaemon()`, show "Restarting device
     daemon…"; on ack → wait ≤10 s for room live → retry `list_projects`
     (single retry). On timeout/failure → fall back to a `Retry restart`
     button (manual re-fire, same flow). Never auto-fires twice per screen
     visit; disposed VM cancels everything.
   - AC (widget/viewmodel tests): dark room → auto-fire once (assert single
     daemon_control); ack → retry → `ProjectsReady`; ack-but-still-dark →
     second timeout → button state; phone-offline error → no fire; button tap
     re-fires; VM dispose cancels timers/streams.

8. **Docs**: PROTOCOL.md (`daemon_control` ops, reply shapes, keeper
   control-presence note, kill-switch); docs/daemon.md (ping loop, restart
   via relay, watchdog checks); root + app CHANGELOG `[Unreleased]`.
   - AC: docs state the trust model and that a live daemon always wins the
     room (keeper is control-only, never publishes meta).

## DoD

- [x] Replay: SIGSTOP the device daemon on the PC. Without touching the
      phone, supervisor ping bounce recovers the room ≤ ~90 s; with the
      Projects screen open, app auto-repair recovers ≤ ~30 s and the list
      renders without a manual tap.
      (2026-11-23 live replay: NtSuspendProcess on the daemon → ping miss
      1/2 → 2/2 → kill + respawn, room re-announced ≈41 s; keeper released
      the claim on the daemon's hello. App-side flow verified by the
      viewmodel/widget tests — 10 s grace → single restart → re-announce
      wait → single list retry — not by a live phone replay.)
- [x] Wedged-supervisor replay: watchdog `health` probe restarts it; the
      relay never needs manual surgery.
      (live replay: suspended supervisor → probe FAIL 1/3, 2/3, 3/3 over
      ≈98 s → kill + restart ≈105 s; the old daemon followed via stdio-EOF,
      new supervisor spawned a clean daemon, relay untouched.)
- [x] `list_projects` still served exclusively by the real daemon; keeper
      never appears as a session (Home unchanged, plan/120 filter intact).
      (keeper unit tests: control-only claim sends no `roomMeta`; non-device
      rooms keep the read-only `session_sync` contract.)
- [x] Kill-switch `allow_remote_session_control:false` refuses
      `daemon_control` too.
      (unit tests on all three serving paths: live daemon, keeper, and the
      app-side surfaces the refusal as `ActionFailure`.)
- [x] `pnpm test` + `pnpm typecheck` green (pi-ext); `flutter test` +
      `flutter analyze` green (app; no new infos). New tests per steps 2–7.
      (pi-ext: suites green, 7 known pre-existing env-sensitive flakes
      exonerated vs main; app: +1122 tests, analyze shows only the 4
      pre-existing infos; new: 8 protocol + 3 repository + 7 viewmodel +
      2 widget tests.)
- [x] Outage window for the incident class: hours → minutes, documented in
      docs/daemon.md. (section 3b; measured replays ≈41 s / ≈105 s.)

## Next plans

- Generalize `daemon_control` to fleet daemons (project daemons beyond
  `device`) once the device path is proven — the keeper callback already
  takes a daemon id.
- Relay presence introspection endpoint (authenticated) so the app can show
  relay-side room rosters instead of inferring from snapshots.
- plan/159 remaining steps (per-daemon logs, `doctor`) fold the ping-loop
  transitions into `doctor` output.
