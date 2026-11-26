# Daemon mode — troubleshooting

Companion to the README's [Daemon mode](../README.md#daemon-mode) section.
Each scenario starts with the symptom you'd actually observe, followed by
likely causes and how to fix.

---

## 0. `remote-pi doctor` — run this first

One command walks the whole failure chain (plan/159): registry sanity,
home-cwd conflicts, supervisor + fleet state (crashed / crash-looped rows),
relay `/health`, the `pi` binary, and path-based remote-pi worktree
packages in pi's global settings. Inside Termux (Android) the report starts
with six host rows instead: the boot script, the Termux:Boot app, the wake
lock, `allow-external-apps`, tmux and the guard (plan/173, see
[`android.md`](./android.md)).

```bash
remote-pi doctor
# ✓ registry: 1 daemon(s) registered
# ✓ home conflict: home cwd left to the device daemon
# ✓ supervisor: running, 2 daemon(s), none crashed
# ✓ relay: http://127.0.0.1:3000 healthy
# ✓ pi binary: node /path/cli.js pi 1.5.0
# ✓ pi settings: no remote-pi worktree packages in global settings
```

Exit code is non-zero when any check fails, so scripts and watchdogs can
gate on it. Inside Pi, `/remote-pi doctor` prints the same report.

**Per-daemon logs (plan/159):** every child's stderr is persisted to
`~/.pi/piper/daemons/<id>.log` (timestamped, capped at 5 MB) no matter how
the supervisor was launched. When a daemon crashes, read that file FIRST —
it survives launcher configurations that discard the supervisor's own
output.

**Crash-loop marker:** when a daemon exhausts the restart backoff and is
retrying at the max cadence, `daemon status` shows `DEAD(<timestamp>)` and
`~/.pi/piper/daemons/<id>.dead` records the last exit. The marker lifts on
the next spawn.

---

## 1. `remote-pi install` fails

### "supervisor script not found"

```
[remote-pi] install failed: Error: supervisor script not found at
/Users/x/dist/bin/supervisord.js. Run `pnpm build` (dev) or
`npm install -g remote-pi` (prod) first.
```

You're running `remote-pi install` from a dev clone where `dist/` doesn't
exist yet, or from a partial install.

```bash
# Dev clone:
cd pi-extension && pnpm build

# Production install:
npm install -g remote-pi      # or pnpm install -g remote-pi
which pi-supervisord          # confirm bin is on PATH
remote-pi install
```

### "launchctl: bootstrap … already running"

A previous install left a stale entry. The fix is built into `install` —
re-run it and the supervisor unloads the old entry before bootstrapping
the new one. If it still fails:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/ch.pungitore.piper.supervisord.plist
launchctl unload ~/Library/LaunchAgents/ch.pungitore.piper.supervisord.plist 2>/dev/null
rm ~/Library/LaunchAgents/ch.pungitore.piper.supervisord.plist
remote-pi install
```

### "systemctl --user … No such file or directory"

Linux without a logged-in graphical session (headless server). On most
distros `systemctl --user` requires `loginctl enable-linger <user>` so
the unit survives logout:

```bash
loginctl enable-linger $USER
systemctl --user daemon-reload
remote-pi install
```

### Android (Termux): there is no service manager

Termux has no systemd, launchd or Task Scheduler. `remote-pi install`
writes `~/.termux/boot/start-piper.sh` instead, and nothing is started by
install itself: the Termux:Boot app runs that script after each reboot, and
`remote-pi phone-setup` runs it once to start everything now. Run the setup
command rather than install on its own:

```bash
remote-pi phone-setup --relay http://<pc-lan-ip>:3000
```

`uninstall` signals the guard and the supervisor and removes the script. The
full picture, including what restarts what on a phone, is in
[`android.md`](./android.md).

---

## 2. Supervisor doesn't start at login

### Check the service status

```bash
# Linux
systemctl --user status remote-pi-supervisord
journalctl --user -u remote-pi-supervisord -n 50

# macOS
launchctl list | grep remotepi
tail -100 ~/.pi/remote/supervisord.log
```

### Common failures

- **`pi: command not found`** in the log — Pi's binary isn't on the
  PATH that the unit inherited. `remote-pi install` captures
  `process.env.PATH` at install time; if you installed Pi *after*
  running install, re-run `remote-pi install` to refresh.
- **`Cannot find module …`** — the path baked into the unit doesn't
  match where `dist/bin/supervisord.js` actually lives. Happens if you
  uninstalled then reinstalled the package to a different location.
  Fix: `remote-pi uninstall && remote-pi install`.
- **Permission denied on UDS** — `~/.pi/remote/` exists with wrong
  perms (rare; only happens if you ran `pi` as `sudo` once). Delete
  the dir and let it re-create: `rm -rf ~/.pi/remote && remote-pi install`.
- **`ExecStart=$'\r'` or "command not found" in the journal** — the unit
  file contains CR characters. Units written by an extension older than the
  LF fix, from a tarball packed on a Windows checkout, have them. Update
  remote-pi and re-run `remote-pi install`; new units are always LF.

### Run the supervisor in the foreground for debugging

Bypass systemd/launchd and run it directly so you can see startup
errors live:

```bash
pi-supervisord
# or: node /path/to/remote-pi/dist/bin/supervisord.js
```

Ctrl-C to stop. If that works but the service doesn't, the problem is
in the unit/plist environment (PATH, HOME) — re-run `remote-pi install`.

### Android (Termux): nothing starts after a reboot

The boot script runs only when the Termux:Boot app is installed AND was
opened once (that is what arms it). `remote-pi doctor` reports both as best
it can. Check in this order:

1. `remote-pi doctor` → the `termux:boot app` row.
2. The script exists and is executable: `ls -l ~/.termux/boot/start-piper.sh`.
   A missing executable bit is the most common failure; `remote-pi install`
   writes it with `chmod 755`.
3. Run it by hand and read the two logs:

   ```bash
   sh ~/.termux/boot/start-piper.sh
   tail -50 ~/.pi/piper/supervisord.log ~/.pi/piper/guard.log
   ```

4. `remote-pi guard status`: guard, supervisor and device daemon in three
   lines.

---

## 3. A specific daemon stays `crashed`

`remote-pi daemon status` shows one row with `state=crashed` and a
restart count near 4 (the supervisor gives up after exponential
backoff: 1s, 5s, 30s, 5min).

### Step 1 — read the daemon's stderr

The supervisor forwards each daemon's stderr with a `[<cwd>]` prefix:

```bash
# Linux
journalctl --user -u remote-pi-supervisord -f | grep '\[/Users/x/Movies\]'

# macOS
tail -f ~/.pi/remote/supervisord.log | grep '\[/Users/x/Movies\]'
```

### Step 2 — run that daemon manually

Reproduce the failure with full visibility:

```bash
cd /Users/x/Movies
REMOTE_PI_DAEMON=1 pi --mode rpc -e $(npm root -g)/remote-pi/dist/index.js
```

Common reasons a daemon won't start:

- **Local config missing.** `cd` into the daemon's folder and check
  `.pi/remote-pi/config.json` exists with `auto_start_relay: true`.
  Recreate via `remote-pi create <cwd>` (it provisions a default config
  when missing).
- **Pi extension config drift.** Pi's own settings (model, API keys)
  reset → daemon fails to authenticate to the provider. Run
  `cd <cwd> && pi` interactively to fix.
- **Port/UDS collision.** Another Pi process is already running in
  that cwd. The cwd-lock should reject the second one, but stale UDS
  sockets sometimes linger; check `lsof ~/.pi/remote/locks/<roomId>.sock`.

### Step 3 — force a re-spawn

After fixing the underlying problem, kick the daemon. Since plan/159,
`daemon start` (and `start all`) covers **crashed** rows — including the
built-in device daemon — by cancelling the backoff and respawning:

```bash
remote-pi daemon start <id>   # respawn one (also works for id "device")
remote-pi daemon start        # respawn every non-running daemon
remote-pi daemon restart      # bounces every daemon
```

Note: `start` deliberately does NOT spawn a second child into a cwd that
another daemon already owns (one child per folder, ever — see the home
cwd rule under `doctor`).

**Windows single-launcher rule:** keep exactly ONE thing starting the
supervisor (the shipped `scripts/piper-watchdog.ps1`, started from the
Startup folder, is the recommended one — it also tees the supervisor's
output to `supervisord.log`). If a `RemotePiSupervisor` scheduled task
exists from an older install, disable it from an elevated shell:

```powershell
schtasks /change /tn RemotePiSupervisor /disable
```

The supervisor's single-instance guard makes races harmless, but two
launchers double the noise and can mask which path actually started it.

---

## 3b. Daemon wedged (hung event loop) — self-healing (plan/168)

A daemon can wedge with its process alive but the pi event loop stuck
(2026-11-22 incident: the relay dropped the peer; the daemon never
noticed; 5.5 h outage). All control verbs run inside the target's pi
process, so a wedged loop processed none of them — the phone had no
repair path. Three layers now detect and repair this without human
action:

1. **Supervisor ping loop** (no relay needed): every 30 s the supervisor
   pipe-pings each running RPC child; 2 consecutive misses (≈60 s) →
   kill + respawn (`--continue` keeps the conversation). Fastest layer;
   works even when the relay is down.
2. **App-triggered restart** (`daemon_control restart` via relay): the
   room keeper now claims room `device` control-only while the daemon is
   dark (no `roomMeta`, invisible as a session, yields to the real
   daemon), so the phone can ask the SUPERVISOR to bounce the child. A
   live daemon answers the verb itself (ack, then exit 1 → crash-respawn).
   The Projects screen auto-fires this once after a 10 s grace, then
   offers a Retry restart button. Kill-switch
   `allow_remote_session_control:false` refuses.
3. **Watchdog** (`piper-watchdog.ps1`): probes the supervisor with a real
   `{"op":"status"}` pipe round-trip (a wedged supervisor fails 3× → kill
   + restart; a plain connect probe false-OKs a wedged loop). Stale
   `rooms.json` `device.lastSeenAt` (>5 min — fed by the daemon's 60 s
   heartbeat tick) bounces ONLY the device child (10 min cooldown), never
   the whole supervisor and never the plan/159 crash-backoff state.
4. **Guard** (`remote-pi guard`, Termux only — plan/173): the Android
   stand-in for the service manager and the watchdog in one light process.
   Same real `status` round-trip every 30 s; a missing supervisor is
   started, a silent one is killed after two checks and restarted, a
   supervisor older than 24 h gets one graceful restart, with a restart-rate
   limit (3 starts per 10 min) plus backoff and one log line per transition.
   Every number is a setting (`~/.pi/piper/guard.conf` or
   `REMOTE_PI_GUARD_<KEY>`; `remote-pi guard status` shows the effective
   values). It leaves crashed and wedged CHILDREN to layers 1 and 2 and
   restarts a `stopped` device daemon. No `lastSeenAt` bounce here: on a
   phone the relay is remote, so a stale heartbeat usually means "PC off",
   not "daemon wedged". `guard stop` waits for a restart in progress
   (`guard.restarting` marker). Log: `~/.pi/piper/guard.log`.

Net effect: this incident class shrinks from hours of manual surgery to
minutes of automatic recovery. Measured replays: ping bounce ≈41 s,
watchdog wedged-supervisor restart ≈105 s, dark room → Projects list
rendering again well under the 90 s budget.

---

## 4. `daemon send` says "daemon not running"

The supervisor has the registry entry but no live child for that id.
Most common cause: the daemon never started OR it crashed past the
retry budget.

```bash
remote-pi daemon status       # is state running?
remote-pi daemon start        # spawn any that aren't running
# Then retry send.
```

If `daemon start` shows `started=0, already_running=N`, the supervisor
isn't actually spawning. Possible reasons:
- Registry empty: `remote-pi daemons` to verify.
- Child crashes faster than the status check: `daemon status` immediately
  after start may still show `running` for a few seconds before the
  exit event marks it crashed. Re-check 2-3 seconds later.

---

## 5. Mobile app doesn't connect to a daemon

The daemon is up but the app doesn't see it.

### Confirm the daemon is paired

`pair_request` must have happened **before** the folder became a daemon
(daemons don't show QRs themselves):

```bash
cd <daemon-cwd>
pi
> /remote-pi devices         # confirm the device is listed
> /remote-pi stop            # stop interactive session — daemon takes over
remote-pi daemon restart
```

### Confirm the relay URL matches

The daemon uses the cwd's local config (`<cwd>/.pi/remote-pi/config.json`
agent_name + `~/.pi/remote/config.json` relay). Verify with:

```bash
cd <daemon-cwd>
pi
> /remote-pi status
```

The relay line should match what the mobile app is connecting to. If
not, update the relay URL and bounce the daemon:

```bash
remote-pi set-relay https://relay.example.tld
remote-pi daemon restart
```

---

## 6. Registry corrupted / partial

Symptom: `remote-pi daemons` errors out or shows nothing despite
having created entries.

```bash
cat ~/.pi/remote/daemons.json    # inspect
```

The file should be:

```json
{
  "daemons": [
    { "cwd": "/Users/x/Movies" },
    { "cwd": "/Users/x/Projects/backend" }
  ]
}
```

Fix manually if needed (it's a JSON list of `{cwd}` entries), or wipe
and re-create:

```bash
rm ~/.pi/remote/daemons.json
remote-pi create ~/Movies --name "Video Editor"
remote-pi create ~/Projects/backend --name "Backend"
remote-pi daemon restart
```

---

## 7. Uninstall cleanly + re-install from scratch

When you suspect everything is misconfigured:

```bash
remote-pi uninstall              # removes service, keeps registry
rm -rf ~/.pi/remote               # nukes registry + paired devices + keys
npm uninstall -g remote-pi
npm install -g remote-pi
remote-pi install
# Then re-pair + re-create daemons from scratch.
```

This is the "nuke everything" path. After this, the only state left is
each cwd's `<cwd>/.pi/remote-pi/config.json` — which you can either
keep (re-create restores the daemon) or delete (full reset).

---

## 8. Diagnostic commands cheat-sheet

```bash
# Where is the supervisor's UDS?
ls -la ~/.pi/remote/supervisor.sock

# Talk to the supervisor manually (raw JSONL):
echo '{"op":"list"}' | nc -U ~/.pi/remote/supervisor.sock

# Where are the daemon configs?
find ~/Projects -name "config.json" -path "*/.pi/remote-pi/*" 2>/dev/null

# Where are the cwd locks?
ls ~/.pi/remote/locks/

# Where are the paired devices?
cat ~/.pi/remote/peers.json

# What Pi binary is the supervisor about to spawn?
remote-pi install --dry-run      # (not implemented; check ~/Library/LaunchAgents or systemd unit manually)

# Quick liveness check
remote-pi daemon status

# Termux only: the guard (Android's stand-in for the service manager)
remote-pi guard status
tail -50 ~/.pi/piper/guard.log
```

If after walking the list you're still stuck, file an issue with the
output of `remote-pi daemon status`, the recent supervisor log, and
the contents of `~/.pi/remote/daemons.json`.
