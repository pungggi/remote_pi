# Android host (Termux): setup and spike notes

Companion to [`plan/173-android-host-sessions.md`](../../plan/173-android-host-sessions.md).
This page collects what the Step 0 spikes prove on a real phone, so the
implementation and the later `remote-pi phone-setup` command can build on it.

**Status (2026-11-25):** all three Step 0 spikes passed on a Galaxy Z Fold 4
(Android 16, One UI 8). S1: the phone works as a host. S2: the relay builds
and runs in Termux. S3: AGY installs, signs in and completes a task inside
proot-distro.

**Status (2026-11-26):** stage A3 is built: `remote-pi install` writes a
Termux:Boot script, `remote-pi guard` keeps the supervisor alive,
`remote-pi phone-setup` replaces the manual steps, sessions from the app run
in tmux, and `remote-pi doctor` starts with six Android rows. All of it is
unit-tested on a PC and not yet run on the owner's phone; the checks are
listed under A3 in the plan.

## What works today

With the steps below, a phone behaves like a second PC:

- **Supervisor and device daemon run in Termux** and connect to the PC's relay.
- **A visible `pi` session on the phone** shows up in the Piper app, and chat
  from the app is answered on the phone.
- **The mesh reaches across.** The phone's session lists the PC's agents as
  peers ("Local mesh: connected as "demo" (6 peers)").
- **The app's Projects screen lists the phone's repositories** (`~/source`),
  served by the device daemon over the PC's relay.
- **The relay itself builds and runs in Termux** (see below), and a Pi on the
  phone authenticates against it over loopback.
- **AGY runs inside a proot-distro Debian on the phone.** It is signed in
  with the owner's Google account and completed its first task in 16 s.

## Requirements discovered

- **Termux 0.119.0-beta.3 or newer on Android 16 / One UI 8.** The stable
  0.118.3 build crashes at launch with `bindService() failed`. The system log
  shows why: `Unable to start service ... TermuxService: not found`. These are
  the upstream issues termux-app #5032 and #4781. Update from the F-Droid
  version list. Why it matters first: nothing else can be tested until Termux
  opens.
- **The F-Droid build is not debuggable.** `adb shell run-as com.termux` is
  refused, and `RunCommandService` cannot be reached from `adb shell`. The
  first setup therefore needs **one command typed inside Termux** (or the user
  running `remote-pi phone-setup` there). Later automation can run through an
  exchange directory, see below.
- **Storage permission is required for adb-pushed files.** Termux targets
  SDK 28 and uses legacy storage. Without `READ/WRITE_EXTERNAL_STORAGE` it
  cannot read files that `adb push` wrote. Grant it with `pm grant`, or let
  the user run `termux-setup-storage`.
- **Termux:Boot 0.8.1 (F-Droid) is the version that works.** Install it,
  then open it once: that is what arms it. The streamed `adb install` was
  refused with `INSTALL_FAILED_VERIFICATION_FAILURE`; `adb install
  --no-streaming -r` succeeded.
- **Let Termux create the exchange directory.** Files that `adb shell` creates
  under `Android/data/com.termux/files/` belong to the shell user and are
  **not readable by Termux** (permission denied). Create the directory from
  inside Termux (`mkdir -p /sdcard/rp`), then push into it. Reads and writes
  then work in both directions.
- **The clipboard bridge is broken on F-Droid.** The Termux:API app (0.53.0)
  and the `termux-api` command line package (0.60.0) do not match, so
  `termux-clipboard-set` does nothing. Hand pairing codes over another way,
  for example as a chat message the user copies.
- **Background survival needs three settings.** Run them once over adb:
  `dumpsys deviceidle whitelist +com.termux`, `cmd appops set com.termux
  RUN_IN_BACKGROUND allow` (plus `RUN_ANY_IN_BACKGROUND` and
  `SYSTEM_ALERT_WINDOW`), and hold `termux-wake-lock` from Termux. The
  phantom-process killer was left at its default during S1; the soak result
  is pending below.

## Setup with `remote-pi phone-setup`

One command inside Termux replaces the manual steps below (plan/173, stage
A3):

```bash
remote-pi phone-setup --relay http://<pc-lan-ip>:3000
```

It refuses to run outside Termux, so a PC keeps `remote-pi install`. Flags:
`--relay <url>` is probed and then saved (the phone cannot reach the PC's
loopback address, and an address that does not answer must not replace a
working one), `--yes` answers both prompts for scripts, `--ttl <seconds>`
bounds the pairing link (default and maximum: 10 minutes).

What it does, in order:

1. **Environment.** Termux, node, `pi --version`, tmux (it offers
   `pkg install -y tmux`), the Termux:Boot app, `allow-external-apps`, the
   relay (`/health` must answer), and remote-pi in Pi's `packages`. Anything
   that would make the pairing link useless stops the run with the fix in the
   line.
2. **Setup.** `remote-pi install` writes `~/.termux/boot/start-piper.sh`, the
   command takes the wake lock, runs that very script, and waits for the
   supervisor, the guard and the device daemon's relay room. Each wait is a
   stopping point. A phone without a guard has nothing that restarts the
   supervisor, so since 0.10.1 a guard that does not come up ends the run
   with exit 1 and the last `guard.log` lines.
3. **Pairing.** The device daemon mints the link. It is printed, and copied
   with `termux-clipboard-set` when that works.
4. **Host check.** The six Android rows of `remote-pi doctor`, as a closing
   report. Exit code 0 means the phone is a working host.

Why the link is printed and not only copied: the F-Droid clipboard bridge is
broken (see below). Why the device daemon mints it: a pairing token only
exists in the process that will consume the app's `pair_request`, and the
device daemon is the one session that is always up on the phone.

**Before the first run:**

- Termux from F-Droid, 0.119.0-beta.3 or newer.
- Termux:Boot from the same source, opened once. That is what arms it.
- `pkg install nodejs git`, then Pi and this extension (manual steps 3 to 5
  below).
- The one-time adb settings under "Background survival needs three settings".

**To stop on purpose:** `remote-pi guard stop && remote-pi daemon stop`. The
guard brings a stopped device daemon back within 30 s, so stop it first.

**Coming from the interim setup:** if the phone already has a
`~/.termux/boot/start-piper.sh` that this version did not write, the command
prints the diff and asks before replacing it, and keeps a dated copy under
`~/.pi/piper/boot-backups/`. On its own, `remote-pi install` refuses to touch such a file: only
`phone-setup` passes the permission to replace it, and only after that
question. The interim guard (`~/.pi/piper/piper-guard.sh`) is retired by
`remote-pi guard run` when the boot script starts it: stopped by its pid,
script renamed. The output says whether both happened.

## What keeps it alive

Android has no service manager. On a PC systemd, launchd or the Task
Scheduler restarts the supervisor. In Termux several layers share that job,
each owning one failure shape. Knowing which layer owns what saves an hour of
log reading.

| Layer | Heals | Runs | Where to look |
|---|---|---|---|
| Child crash backoff | a daemon that exited (1 s, 5 s, 30 s, 5 min; never gives up) | supervisor | `remote-pi daemon status`, `~/.pi/piper/daemons/<id>.log` |
| Child ping loop (plan/168) | a daemon that is alive but wedged (2 missed pings, about 60 s) | supervisor | `~/.pi/piper/supervisord.log` |
| App-triggered restart (plan/168) | a wedged device daemon while relay and supervisor live | Piper app, via the room keeper | Projects screen, "Restarting device daemon" |
| **`remote-pi guard`** | the supervisor itself: gone, alive but silent, or older than 24 h | a separate Termux process | `~/.pi/piper/guard.log` |
| **Termux:Boot** | everything after a reboot | Android, `~/.termux/boot/start-piper.sh` | the script's comments |
| Termux app gone | nothing inside Termux can restart it | not built: plan/173 A7 | research and spike |

**termux-exec, or why the device daemon died after every reboot.** npm links
`pi` to a script whose shebang is `#!/usr/bin/env node`. Android has no
`/usr/bin/env`. In a Termux shell that still works, because the app preloads
`libtermux-exec.so`, which rewrites such a shebang when a program is started.
Termux:Boot runs the boot script without that preload. Before 0.10.2 the
script did not set it, so after each boot the supervisor and the guard came up
and the device daemon crashed within ten seconds: `spawn pi ENOENT` in
`~/.pi/piper/supervisord.log`, "device daemon: crashed" in `guard.log`. On
2026-11-26 that left the phone off the mesh from 20:14 until a restart by
hand the next morning. Since 0.10.2 two things hold:

- **The boot script exports `LD_PRELOAD`** when it is unset and
  `$PREFIX/lib/libtermux-exec.so` exists. Everything the script starts
  inherits it, the tmux server and the sessions inside included.
- **The supervisor starts the device daemon as `node <pi's cli.js>`**, not
  through the shebang. That path needs no preload at all, so a supervisor
  started from a shell without it still brings the device daemon up.

**The guard.** The boot script starts `remote-pi guard run`; `remote-pi guard
start`, `status`, `stop` and `once` manage it. Every 30 s it asks the
supervisor for a real `{"op":"status"}` round trip on the control socket (a
listening socket proves nothing: the 2026-11-22 wedge answered connects for
hours). The owner's rules of 2026-11-26, every number a setting:

- **No process, no reply:** start the supervisor.
- **Process there, silent for two checks:** kill it (SIGTERM, grace, then
  SIGKILL) and start a new one.
- **Older than 24 h:** one graceful restart (SIGINT, grace, SIGKILL fallback,
  start), so a long-running supervisor is recycled once a day.
- **Device daemon row `stopped`:** ask the supervisor to start it, at most
  once a minute and three times in ten minutes.

It only LOGS the other states (crashed, starting, missing row), once per
transition. Why: a crash loop belongs to the supervisor's backoff, and a guard
that restarted on every tick would make that loop hot. The guard is a
separate light process with its own entry path, so a broken runtime or SDK
after an update cannot take the watchdog down with it. `run` and `start`
refuse outside Termux: one start path per machine, the same rule the Windows
watchdog follows.

**Restart-rate limit.** At most 3 supervisor starts in 10 minutes, on top of
the backoff between starts of one outage (15 s, 30 s, 1 min, 2 min, 5 min,
10 min, forgiven after 10 stable minutes). A start the limit or the backoff
would refuse simply waits, and the guard says so once per wait, with the
time the start is allowed: `restart postponed by the start limit (3 per
10 min) until …` or `start postponed by the start backoff until …`. Why the
second line matters: a wait on the backoff alone used to be silent, and 27
minutes without a line on the owner's phone (2026-11-27) read as a dead
guard. A wedged supervisor is not killed before its replacement may
start: a frozen supervisor is no worse than none. The limit holds for any
values, also for a backoff shorter than the window.

**Settings.** Defaults, then `~/.pi/piper/guard.conf` (`KEY=VALUE`, a
`# comment` allowed behind the value, as in a shell; the file the interim
shell guard already used), then `REMOTE_PI_GUARD_<KEY>`. The
environment wins on purpose: an override given for one test run must not be
silently undone by a forgotten line in a file. Unknown names and unusable
values are logged and ignored, and the effective settings are the first line
of every guard start (`remote-pi guard status` shows them too).

| Setting | Default | Meaning |
|---|---|---|
| `INTERVAL_S` | 30 | seconds between health checks |
| `FAILS_BEFORE_RESTART` | 2 | silent checks of a PRESENT supervisor before it is restarted |
| `MAX_AGE_S` | 86400 | graceful restart above this uptime; 0 turns it off |
| `RESTART_RATE_MAX` / `RESTART_RATE_WINDOW_S` | 3 / 600 | starts per window; 0 = no limit |
| `START_BACKOFF_S` | 15,30,60,120,300,600 | wait after the k-th start of an outage |
| `STOP_GRACE_S` | 10 | SIGINT/SIGTERM to SIGKILL |

**The file is the interim guard's.** The phone's `~/.pi/piper/guard.conf` was
written for the shell guard, so its names are read as aliases:
`CHECK_INTERVAL_S` → `INTERVAL_S`, `RESTART_GRACE_S` → `STOP_GRACE_S`,
`RATE_MAX_RESTARTS` → `RESTART_RATE_MAX`, `RATE_WINDOW_S` →
`RESTART_RATE_WINDOW_S`. When a file holds both names the canonical one wins;
the environment wins over both. `RATE_BACKOFF_S` has no counterpart (the
backoff ladder between starts replaced it) and is reported once with that
hint.

**Stop safety.** A restart sequence (stop old, start new) is marked in
`~/.pi/piper/guard.restarting`. `remote-pi guard stop` waits while the marker
exists instead of sending SIGKILL into the middle of it, and the loop itself
finishes the tick before it stops. A TERM during a restart never leaves the
phone without a supervisor.

**Process hygiene.** The supervisor is recognised only when `argv[0]` is node
AND the script argument is the supervisor entry (read from
`/proc/<pid>/cmdline`). An editor, a `grep`, a tmux command line or a
`bash -c "node …"` launcher that merely mentions the name never matches. The
interim shell guard learned this the hard way: `pgrep -f pi-supervisord`
also found the launcher shell, and `pkill -f` matched its own command text.

**Coming from the interim guard.** Before this release the phone ran
`~/.pi/piper/piper-guard.sh` (a bash loop with the same `guard.pid`,
`guard.conf` and `guard.log`). `remote-pi guard run` retires it first: it
stops the process the pid file names when that is the interim script, and
renames the script to `piper-guard.sh.replaced-<timestamp>`, so exactly one
guard implementation remains. `guard.conf` stays: settings with a matching
name carry over, others are reported as ignored. `remote-pi phone-setup`
shows the diff between the interim boot script and the generated one, asks
before replacing a script it did not write, and keeps a dated copy under
`~/.pi/piper/boot-backups/` (`start-piper.sh.bak-<timestamp>`).

**Nothing but the live script belongs in `~/.termux/boot`.** Termux:Boot
runs every file of that directory at each boot, in a job order nobody
controls, and it sets the executable bit itself when it is missing
(termux-boot 0.8.1, `BootReceiver`). An old script there runs at every boot
with full effect. The reboot test of 2026-11-27 showed it: two dated copies
that `install` up to 0.10.2 left next to the script ran as well. One looked
for a wrapper that no longer existed, one started a second supervisor that
had to refuse. That is harmless only while the old lines lose against the
live ones. Since 0.10.3 `remote-pi install` keeps the dated copy under
`~/.pi/piper/boot-backups/`, and `remote-pi doctor` warns while old copies
sit in the boot directory. To move them by hand:

```bash
mkdir -p ~/.pi/piper/boot-backups && mv ~/.termux/boot/start-piper.sh.bak-* ~/.pi/piper/boot-backups/
```

**Outage of 2026-11-25, and what would have caught it.** `pi-supervisord`
received SIGINT and SIGTERM at 21:10 and the phone booted at about 22:00.
Nothing restarted Termux until the owner opened it at 11:18. Termux:Boot was
not installed, so the reboot left the phone dark: the boot script plus
Termux:Boot is the fix for that half. Had Termux stayed up and only the
supervisor died, the guard would have restarted it within 30 to 60 s.

## Sessions from the app run in tmux

"Start session" and "Open terminal" on the phone start `pi` inside a
detached tmux session named after the relay room
(`tmux new-session -d -s <room> -c <folder> '…'`). Why tmux: Termux's
`RUN_COMMAND` intent failed in the spike, and tmux gives a terminal that no
window has to be attached to. Attach on the phone with `tmux attach -t
<room>`. The session ends when `pi` exits, like a terminal tab whose program
returns. A folder outside `projects.roots` is refused exactly as on a PC.

The device daemon that launches tmux carries its own identity
(`REMOTE_PI_DIRECT_CONFIG`, room `device`). The launcher removes both from the
environment and from the command, because the tmux server keeps the
environment of whichever client started it. Without that, a new `pi` would
join the phone-filtered `device` room and never appear as a tile.

## Manual steps (fallback for `phone-setup`)

Kept for a phone where the command refuses to run, and as the record of
what the spike actually did. `remote-pi phone-setup` performs steps 4, 7 and
8 on its own: `--relay` is step 4, the boot script replaces the manual
supervisor start of step 7, and the pairing link comes from the device daemon
instead of a throwaway RPC session (step 8).

1. **adb over WLAN.** `adb pair <ip>:<pair-port> <code>`, then
   `adb connect <ip>:<debug-port>`. Pairing over a Tailscale address failed
   twice with `protocol fault` and succeeded on the third try.
2. **Termux.** Install or update from F-Droid (0.119.0-beta.3), then
   `pm grant com.termux android.permission.POST_NOTIFICATIONS`.
3. **Packages in Termux.** `pkg install nodejs git`, then
   `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`. For the
   current extension build, run `npm pack --ignore-scripts` on the PC, push
   the tarball, and `npm install -g <tarball>`.
4. **Relay.** `remote-pi set-relay http://<pc-lan-ip>:3000`. Check with
   `remote-pi doctor`: the relay line must say healthy.
5. **Pi settings.** Add the extension to `packages` in
   `~/.pi/agent/settings.json`, set `defaultProvider` and `defaultModel`.
   Copying `auth.json` and `models-store.json` from the PC reuses its logins
   (ask the owner first; the keys then live on the phone).
6. **Project folder.** `mkdir -p ~/source/<name>` with a git repo and a
   `.pi/remote-pi/config.json` containing
   `{ "agent_name": "<name>", "auto_start_relay": true }`.
7. **Supervisor** (replaced by `remote-pi install` + the boot script).
   `nohup pi-supervisord > ~/.pi/piper/supervisord.out 2>&1 &` brings up the
   room keeper and the device daemon. Termux:Boot is not installed yet, so
   this is a manual start.
8. **Pairing without a terminal UI** (replaced by `remote-pi phone-setup`).
   Keep an RPC session alive and feed it the pair command:

   ```bash
   : > ~/pair.in
   nohup bash -c 'tail -f ~/pair.in | pi --mode rpc > ~/pair.out 2> ~/pair.err' &
   echo '{"id":"p1","type":"prompt","message":"/remote-pi pair --ttl 600"}' >> ~/pair.in
   grep -o 'remotepi://pair[^"\\ ]*' ~/pair.out   # details.uri of the pair-code message
   ```

   The process must stay alive until the app has paired. Stop it before
   starting the real session in the same folder, because the folder lock
   would give the real session a `#2` name and a different room.
9. **Session.** `cd ~/source/<name> && pi` in Termux. The app lists it and
   chat works.

## Relay on Android (S2)

- **Build on device, no NDK.** `pkg install rust binutils clang openssl
  pkg-config make`, unpack `git archive HEAD relay`, then
  `OPENSSL_NO_VENDOR=1 OPENSSL_DIR=$PREFIX cargo build --release -j 3`.
  Why `OPENSSL_NO_VENDOR`: the crate's vendored build compiles OpenSSL from
  source; the Termux package is enough and avoids perl and a long build.
- **Result:** release build in 11 min 46 s, binary 11.8 MB.
- **Run:** `REMOTEPI_RELAY_PORT=3001 REMOTEPI_MESH_DB_PATH=~/.pi/piper/relay/mesh.db
  ./relay`. The bind address is hardcoded to `0.0.0.0`, so the relay is
  reachable from the WLAN. Stage B adds a bind option so the phone can keep
  it on loopback.
- **Verified:** `/health` answers `OK` on the phone's loopback and from the PC
  over the WLAN. A Pi started with `REMOTE_PI_RELAY=http://127.0.0.1:3001`
  authenticated (relay log: `authenticated peer=… room=… addr=127.0.0.1`).
- **Footprint while idle:** about 10 MB RSS, 5 threads, a few hundredths of a
  second of CPU in half a minute.

## AGY on Android (S3)

- **No built-in Linux Terminal on the Z Fold 4:** `ro.virtualization.supported`
  is empty. The only route is Termux with proot-distro.
- **Install:** `pkg install proot-distro`, `proot-distro install debian`
  (Debian 13), then inside the distro `apt install curl ca-certificates` and
  `curl -fsSL https://antigravity.google/cli/install.sh | bash`. The binary
  lands in `/root/.local/bin/agy`, version 1.5.16.
- **Start time:** `agy --version` takes about 1.9 s under proot.
- **Run it in tmux, not in the interactive session.** The phone's visible
  Termux session already hosts the Pi session, and Termux's own command intent
  did not work (see Observations). A detached tmux session gives AGY the real
  terminal it needs, and `tmux capture-pane -p` returns its screen as text:

  ```bash
  pkg install tmux
  tmux new-session -d -s agy -x 210 -y 50 '~/agy'
  tmux capture-pane -p -t agy      # read the screen, tmux send-keys to type
  ```

  The wrapper `~/agy` binds the Termux home as `/root/termux-home`, exports
  `SSH_CONNECTION` (so the CLI prints the sign-in URL instead of opening a
  browser that proot does not have), and execs `agy` in the project folder.
- **Sign-in is an OAuth code flow.** Google redirects to
  `antigravity.google/oauth-callback`, which shows an authorization code. Any
  browser works, the PC's included. The code goes into the CLI prompt. Why
  this matters: the callback is not on localhost, so the owner can sign in on
  whichever device is handy.
- **Onboarding asks three things:** the color scheme, consent to interaction
  data collection (the owner's decision, not ours), and trust for the project
  folder.
- **Result:** signed in with the owner's Google AI Pro account, model
  "Gemini 4 Neon (High)", auto mode. The first task (create `hello.txt`)
  was done in 16 s. The `agy` process uses about 290 MB RSS.

## Observations

- **First contact looks like an outage.** When the app switched to the phone
  for the first time, the Projects screen reported the device daemon as
  offline and ran its self-repair restart (plan/168), although the daemon's
  relay connection had been up since it started. The daemon was back after
  about 11 s and the project list loaded. Stage A should check whether this
  is a false alarm on first contact with a new device.
- **No phantom-process kill so far** in the first half hour with the killer at
  its default: supervisor, device daemon and the visible session all
  survived, including a restart that the app requested. The killer was then
  disabled for the heavy builds (`device_config put activity_manager
  max_phantom_processes 2147483647`, `settings put global
  settings_enable_monitor_phantom_procs false`, `device_config
  set_sync_disabled_for_tests persistent`).
- **The phone keeps working while locked.** With the wake lock held and the
  device-idle whitelist set, a mesh message sent from the PC was processed by
  the phone's Pi session while the phone was locked and dozing.
- **`RUN_COMMAND` from inside Termux failed** in this test. Calling
  `am startservice -n com.termux/.app.RunCommandService -a
  com.termux.RUN_COMMAND …` from a Termux shell reaches the service (the
  system log shows it starting), but Termux logs "Processing plugin execution
  error" and runs nothing, with and without `allow-external-apps = true`,
  foreground and background. The exact refusal was never captured; plan/173
  A7 lists the candidates (`termux.properties` is only read when the Termux
  app starts, the command path must be inside the Termux home or prefix, the
  `am` extra types must match) and how to capture it. Stage A3 does not rely
  on `RUN_COMMAND`: phone sessions run in tmux.
- **Nothing outside Termux can kill a stuck Termux process.** `adb shell` runs
  as another user. Give every unattended command a hard limit
  (`timeout -k 5 30 …`). In this session the PC agent asked the phone's agent
  over the mesh to kill a hung `agy` process, which worked.
- **Eight hours overnight, unplugged.** Supervisor, device daemon, the visible
  Pi session and the test relay all survived with the screen off. No
  phantom-process kill after the settings above were applied. The battery
  dropped by about 2 % per hour with everything idle. Why this matters: an
  always-on phone host has a real idle cost, so Stage A needs an easy way to
  stop idle sessions, and the relay fallback (Stage B) should not keep extra
  processes alive.

## Measured

- Termux packages: node v26.4.0, npm 11.21.1, git 2.56.0. Pi 1.6.0.
- The extension (worktree build) installs in about 18 s.
- The identity falls back to `~/.pi/piper/identity.json`, as designed when no
  keyring is available.
- Footprint after a night: relay 6 MB RSS, `agy` about 290 MB while busy.
- Soak with the phantom-process killer at its default: 35 min without a kill
  (light load), then the settings were applied before the heavy builds.
- **Interim guard, 2026-11-26** (the shell loop that ran on the phone before
  `remote-pi guard` existed). Wedged supervisor (SIGSTOP): miss 1 at +25 s,
  miss 2 at +68 s, SIGINT ignored by the frozen process, 10 s grace, SIGKILL,
  detached start, device daemon back on the relay after 97 s. A graceful stop
  of a healthy supervisor via SIGINT takes under 1 s. Age restart with a 5 s
  override: exactly one restart.
- Termux on the owner's phone: tmux 3.8, nodejs 26.4.0, openssh, termux-api
  0.60.0, proot-distro. No cron package and no termux-services (no runit):
  nothing but a detached loop can restart the supervisor.

## Still open

- **Stage A3 on the device.** Every piece is built; the six checks listed
  under A3 in the plan have not been run on the phone.
- **The Termux app itself.** Nothing inside Termux can restart it after a
  kill or a swipe-away. Plan/173 A7 has the research, one recommendation and
  the spike to run before any app code.
- **Termux:Boot from inside Termux.** `pm list packages` is best-effort
  (Android may refuse it), and whether the app was OPENED ONCE cannot be
  read at all. The setup command asks the user to confirm.
- The exact message `open_terminal` returns on Android when tmux is missing
  (expected: `tmux is not installed on this phone`).
- **Attaching from the app.** The tmux session exists; the "Open in Termux"
  button of stage A5 brings Termux to the front and attaches.
- **AGY with the mesh plugin inside proot** (`remote-pi agy` needs Node and the
  extension in the distro), which is Stage C.
- **Idle battery cost** of an always-on phone host (about 2 % per hour here).
- **Why `RUN_COMMAND` failed** from inside Termux: the exact refusal was
  never captured. Plan/173 A7 lists the candidates and how to capture it.
- **Relay bind address** (Stage B) and the relay preference logic.
