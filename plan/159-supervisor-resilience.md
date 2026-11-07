# Plan 159 — Supervisor resilience

## Context

Incident of 2026-11-07 (Windows host `CHICO`): the phone showed no live
sessions. Post-mortem walk found a chain of independent failures, each of
which the current stack absorbs silently:

- **Config conflict kills daemons**: global `settings.json` loaded a
  `remote_pi_*` worktree package while the daemon passes `-e <dist>`.
  Tool names collided, `pi` exited before the room registered, the
  supervisor retried into backoff and gave up. Nobody was notified.
- **`daemon start` / `daemon restart` refuse crashed entries**: both
  reported "0" while `daemon status` showed `crashed`. No force path.
- **Fresh-boot duplicate spawn**: a supervisor restart spawns the same
  registry entry twice (hash id + name id). The second child loses the
  room lock and stays as a plain agent process ("another live agent
  already owns …" in the log). Wasteful and confusing in status output.
- **Memory/disk drift**: the old supervisor held a zombie fleet row in
  memory while `daemons.json` was empty. Restarting it would lose state;
  nothing reconciles the two.
- **Diagnostics depend on launcher**: the watchdog started the supervisor
  hidden with no redirection, so child crash stderr went nowhere. The
  Task Scheduler launcher tees to a log; the watchdog path did not.
- **Watchdog checks liveness, not health**: "pipe exists" was OK for hours
  while the fleet was dead. It also respawned `relay.exe` every 30 s
  because the relay runs elevated (unreadable `Path`) even though
  `/health` was green.

Machine-local fixes already applied on `CHICO` (this plan is about making
them the product's behavior, not one host's scripts):

- removed the conflicting worktree package from global `settings.json`
- watchdog: health-first relay check, VBS-style `cmd /c … >> log`
  redirection for supervisor starts
- `RemotePiSupervisor` scheduled task still enabled (disable needs an
  elevated shell); the supervisor's single-instance guard covers the race

## Expected structure

All work in `pi-extension/src/` (plus watchdog script changes in
`scripts/` if we adopt a shipped watchdog):

- `daemon/supervisor.ts` — spawn/reconcile/force-start/log changes
- `daemon/control_protocol.ts` — new ops if needed (`health`, `respawn`)
- `daemon/fleet.ts` — CLI surface: `daemon start --force`, `doctor`
- per-daemon log files under `~/.pi/piper/daemons/<id>.log`
- tests in `daemon/supervisor.test.ts` + new `doctor.test.ts`

## Steps

1. **Force spawn**
   - `daemon start` treats `crashed` and `stopped` alike: kill any stale
     child, cancel backoff, spawn.
   - Acceptance: with a fleet row in `crashed`, `daemon start` reports
     `Started 1` and status flips to `running` (unit test with fake
     clock).

2. **Boot dedup by cwd**
   - On supervisor start, build the fleet keyed by cwd; drop the second
     row when one registry entry materializes two ids (hash vs name).
   - Acceptance: fresh supervisor over a one-entry registry spawns exactly
     one child; `daemon status` shows one row (regression test for the
     exact 2026-11-07 shape: entry has `name` field).

3. **Registry reconciliation**
   - Every 60 s (and after every registry write), diff in-memory children
     against `daemons.json`: adopt new entries, stop removed ones.
   - Acceptance: edit `daemons.json` while supervisor runs; within one
     cycle the fleet matches the file without a supervisor restart.

4. **Per-daemon logs**
   - Forward each child's stderr to `~/.pi/piper/daemons/<id>.log` with
     size cap, in addition to supervisor stdout.
   - Acceptance: kill a child with a crashing command line; the reason is
     readable from the per-daemon log even when the supervisor runs with
     stdout discarded.

5. **`remote-pi doctor`**
   - Checks: relay `/health` reachable, supervisor pipe responds,
     registry vs supervisor fleet consistent, `pi --version` spawns in
     each daemon cwd with the same env, no conflicting `remote_pi_*`
     entries between settings and `-e`.
   - Acceptance: on the 2026-11-07 broken state (reproduced in tests),
     `doctor` names the settings conflict as the root cause; exits
     non-zero on any failure.

6. **Crash-storm marker**
   - When a child exhausts backoff, write `~/.pi/piper/daemons/<id>.dead`
     (content: last exit code + timestamp); remove on successful spawn.
   - Acceptance: `daemon status` shows `dead` rows distinctly; watchdog
     (step 8) can alert on them.

7. **Watchdog v2 (shipped, not hand-rolled)**
   - Move `piper-watchdog.ps1` into `pi-extension/scripts/` with: health
     -first relay check (never spawn while `/health` is OK), supervisor
     fleet health via control protocol (alert when any row sits `crashed`
     past N minutes), log redirection on every start path.
   - Acceptance: watchdog log stays clean while relay runs elevated;
     killing the fleet daemon for 5 min produces one alert line, not
     silence; one `RemotePiSupervisor` task (disabled or removed) so
     exactly one start path remains.

8. **Elevation follow-up (manual, host-specific)**
   - From an elevated shell: `schtasks /change /tn RemotePiSupervisor
     /disable`, then delete the Startup `.lnk` if the shipped watchdog
     replaces it.

## DoD

- Replaying the 2026-11-07 incident against the new build: `doctor` finds
  it, `daemon start --force` (or plain `start`) recovers it, the reason is
  in a per-daemon log, and the watchdog logs one alert line.
- All existing `pi-extension` tests green; new tests for steps 1-6.
- `docs/daemon.md` updated: doctor section, per-daemon logs, force start,
  single-launcher rule on Windows.

## Next plans

- plan/113 (pinned daemon fleet) builds on fleet status trustworthiness
- relay-side room roster reconciliation could reuse the same health ops
