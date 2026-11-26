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
`--relay <url>` saves the relay first (the phone cannot reach the PC's
loopback address), `--yes` answers both prompts for scripts, `--ttl <seconds>`
bounds the pairing link (default and maximum: 10 minutes).

What it does, in order:

1. **Environment.** Termux, node, `pi --version`, tmux (it offers
   `pkg install -y tmux`), the Termux:Boot app, `allow-external-apps`, the
   relay (`/health` must answer), and remote-pi in Pi's `packages`. Anything
   that would make the pairing link useless stops the run with the fix in the
   line.
2. **Setup.** `remote-pi install` writes `~/.termux/boot/start-piper.sh`, the
   command takes the wake lock, runs that very script, and waits for the
   supervisor, the guard and the device daemon's relay room.
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
| **`remote-pi guard`** | the supervisor itself: gone, or alive but silent | a separate Termux process | `~/.pi/piper/guard.log` |
| **Termux:Boot** | everything after a reboot | Android, `~/.termux/boot/start-piper.sh` | the script's comments |
| Termux app gone | nothing inside Termux can restart it | not built: plan/173 A7 | research and spike |

**The guard.** The boot script starts `remote-pi guard run`; `remote-pi guard
start`, `status`, `stop` and `once` manage it. Every 30 s it asks the
supervisor for a real `{"op":"status"}` round trip on the control socket (a
listening socket proves nothing: the 2026-11-22 wedge answered connects for
hours). Three rules:

- **No process, no reply:** start the supervisor. Waits between starts grow
  0, 15 s, 30 s, 1 min, 2 min, 5 min, 10 min, and are forgiven after 10
  stable minutes.
- **Process there, silent for three probes:** kill it (SIGTERM, then SIGKILL)
  and start a new one.
- **Device daemon row `stopped`:** ask the supervisor to start it, at most
  once a minute and three times in ten minutes.

It only LOGS the other states (crashed, starting, missing row), once per
transition. Why: a crash loop belongs to the supervisor's backoff, and a guard
that restarted on every tick would make that loop hot. The guard is a
separate light process with its own entry path, so a broken runtime or SDK
after an update cannot take the watchdog down with it. `run` and `start`
refuse outside Termux: one start path per machine, the same rule the Windows
watchdog follows.

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
