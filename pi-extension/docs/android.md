# Android host (Termux): setup and spike notes

Companion to [`plan/172-android-host-sessions.md`](../../plan/172-android-host-sessions.md).
This page collects what the Step 0 spikes prove on a real phone, so the
implementation and the later `remote-pi phone-setup` command can build on it.

**Status (2026-11-25):** all three Step 0 spikes passed on a Galaxy Z Fold 4
(Android 16, One UI 8). S1: the phone works as a host. S2: the relay builds
and runs in Termux. S3: AGY installs, signs in and completes a task inside
proot-distro.

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

## Setup steps that worked (S1)

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
7. **Supervisor.** `nohup pi-supervisord > ~/.pi/piper/supervisord.out 2>&1 &`
   brings up the room keeper and the device daemon. Termux:Boot is not
   installed yet, so this is a manual start.
8. **Pairing without a terminal UI.** Keep an RPC session alive and feed it
   the pair command:

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
  foreground and background. Stage A must find the cause before relying on
  it for "open terminal on the phone".
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

- The exact message `open_terminal` returns on Android today (expected:
  unsupported).
- **AGY with the mesh plugin inside proot** (`remote-pi agy` needs Node and the
  extension in the distro), which is Stage C.
- **tmux as the container for phone sessions.** Since `RUN_COMMAND` fails,
  "open a terminal on the phone" is best built on tmux sessions started by the
  device daemon and attached from Termux on demand.
- **Idle battery cost** of an always-on phone host (about 2 % per hour here).
- **Why `RUN_COMMAND` fails** from inside Termux (see above).
- **Relay bind address** (Stage B) and the relay preference logic.
- **Termux:Boot** for autostart, and the app-side start flow of Stage A.
