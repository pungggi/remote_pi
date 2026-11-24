# Android host (Termux): setup and spike notes

Companion to [`plan/172-android-host-sessions.md`](../../plan/172-android-host-sessions.md).
This page collects what the Step 0 spikes prove on a real phone, so the
implementation and the later `remote-pi phone-setup` command can build on it.

**Status (2026-11-25):** spike S1 passed on a Galaxy Z Fold 4 (Android 16,
One UI 8). S2 (relay on Android) and S3 (AGY on Android) are still open.

## What works today

With the steps below, a phone behaves like a second PC:

- **Supervisor and device daemon run in Termux** and connect to the PC's relay.
- **A visible `pi` session on the phone** shows up in the Piper app, and chat
  from the app is answered on the phone.
- **The mesh reaches across.** The phone's session lists the PC's agents as
  peers ("Local mesh: connected as "demo" (6 peers)").
- **The app's Projects screen lists the phone's repositories** (`~/source`),
  served by the device daemon over the PC's relay.

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

## Observations

- **First contact looks like an outage.** When the app switched to the phone
  for the first time, the Projects screen reported the device daemon as
  offline and ran its self-repair restart (plan/168), although the daemon's
  relay connection had been up since it started. The daemon was back after
  about 11 s and the project list loaded. Stage A should check whether this
  is a false alarm on first contact with a new device.
- **No phantom-process kill so far** in the first half hour with the killer at
  its default: supervisor, device daemon and the visible session all
  survived, including a restart that the app requested.

## Measured

- Termux packages: node v26.4.0, npm 11.21.1, git 2.56.0. Pi 1.6.0.
- The extension (worktree build) installs in about 18 s.
- The identity falls back to `~/.pi/piper/identity.json`, as designed when no
  keyring is available.
- Soak with the phantom-process killer at its default: pending.

## Still open

- The exact message `open_terminal` returns on Android today (expected:
  unsupported).
- **Soak result** and whether the phantom-process settings are needed.
- **S2:** the relay has not been built or run on Android yet.
- **S3:** `ro.virtualization.supported` is empty on the Z Fold 4, so there is
  no built-in Linux Terminal. AGY can only be tried through Termux with
  proot-distro.
- **Termux:Boot** for autostart, and the app-side start flow of Stage A.
