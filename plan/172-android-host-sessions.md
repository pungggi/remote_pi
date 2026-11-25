# Plan 172 — Android as a session host: pick Pi or AGY, pick PC or phone

Status: planned 2026-11-24 (conversation with the owner). **Step 0 is done
(2026-11-25): all three spikes passed**, written up in
[`pi-extension/docs/android.md`](../pi-extension/docs/android.md).
Stages A/B/C below are the implementation plan; each stage ships on its own.

## Context

**User goal.** When starting a session from the Piper app, the user picks two
things independently:

- **Which agent**: Pi or AGY (Antigravity CLI).
- **Where it runs**: on a paired PC, or on the phone itself.

Phone-hosted sessions belong to the mesh like any other. The phone must also
work **with the PC switched off**.

**Decisions closed in conversation (2026-11-24)**

| Question | Decision |
|---|---|
| Scope | Pi on the phone + location choice. AGY selectable as an agent: on the phone (after a spike) and on the PC. **No** AGY chat in the app (own plan later). |
| How to work with a phone session | The app is the standard UI. A terminal on the phone can be opened on demand. |
| Purposes | Work on projects without the PC; work on phone-local things; phone as an extra agent in the mesh. |
| Without the PC | The phone becomes its own hub: it runs its own relay. |
| Phone | Samsung Galaxy Z Fold 4 (2022, Snapdragon 8+ Gen 1, 12 GB RAM, Android 16 / One UI 8 expected). |
| Model at start | Yes, for Pi and AGY (added after the first draft, same day). The start model applies to that one session; the saved default stays unchanged. |

These are also recorded in [`00-decisions.md`](00-decisions.md) (section
"Android as a session host").

**State of the code (verified 2026-11-24)**

- **The app starts sessions only on a PC, and only Pi.**
  `HomeViewModel.startSession` / `openTerminal` send typed actions to the
  device room; [`actions/start_session.ts`](../pi-extension/src/actions/start_session.ts)
  and [`actions/open_terminal.ts`](../pi-extension/src/actions/open_terminal.ts)
  launch `pi`. `openTerminalTab` is Windows-only: other platforms reply
  `ok:false unsupported`.
- **AGY is a mesh citizen but invisible to the app.** Plans 154/155 made `agy`
  a first-class mesh peer. The app has no `agy` reference and no mesh-peer
  list, so it can neither show nor start an AGY session, on any device.
- **No model choice at session start.** Sessions started from the app use
  Pi's saved default; the start requests carry no model. The only model sheet
  (`model_picker_sheet.dart`) belongs to Quick actions and is bound to a live
  Pi session: it asks that session (`list_models`) and switches it
  (`model_set`).
- **AGY can list its own models.** `agy models` prints `id<TAB>name` per line
  and works headless from a Node child process (measured 2026-11-24: 30
  models, exit 0 after about two seconds). `agy --model <id>` sets the model
  for a session; the effort is part of the id (`-low`, `-medium`, `-high`).
- **Pi officially runs on Android** through Termux (Pi's own
  `docs/termux.md`: `pkg install nodejs git`, then `npm install -g` Pi).
- **The extension can load in Termux.** Its only native module,
  `@napi-rs/keyring`, is lazily imported with a file-backed fallback
  ([`pairing/storage.ts`](../pi-extension/src/pairing/storage.ts)).
- **Pairing without a camera already exists.** The app's paste-QR sheet
  accepts the raw `remotepi://pair?...` URI
  ([`paste_qr_sheet.dart`](../app/lib/ui/pairing/widgets/paste_qr_sheet.dart));
  the URI is built by `buildQRUri` in
  [`pairing/qr.ts`](../pi-extension/src/pairing/qr.ts).
- **The relay is a separate Rust binary** binding `0.0.0.0:3000`
  ([`relay/src/main.rs`](../relay/src/main.rs)). On the owner's PC it is the
  release build, started by hand. There is no relay release workflow yet.
- **One relay per owner today.** The PC's relay is the single meeting point
  for the app, the PC's sessions and cross-PC mesh traffic. The decisions file
  lists "multi-relay / federation" as open. This plan does not federate.

**Risks**

1. **AGY on the phone is unproven.** AGY is a native glibc binary (glibc ≥
   2.28). Termux uses Android's bionic libc. Two candidate routes exist, both
   untested on a Z Fold 4 (see Step 0, spike S3).
2. **The relay has never run on Android.** It depends on `openssl` (vendored,
   only for web-push VAPID keys) and `rusqlite` (bundled SQLite). Cross
   compiling or building in Termux should work, but is untested (spike S2).
3. **Android kills background processes.** There is no systemd or launchd,
   the phantom-process killer terminates Termux child processes, and battery
   optimisation sleeps apps. Termux's wake lock plus one-time settings are the
   accepted mitigation (spike S1 measures it).
4. **Two relays, one app connection.** The app keeps exactly one live relay
   connection and treats that relay's room snapshot as the live set. The
   design below keeps that invariant instead of rewriting the transport.

Spikes 1 to 3 are answered, see the results under Step 0. Two points the
spikes added: the idle battery cost of an always-on host (about 2 % per hour
with everything running), and Termux's `RUN_COMMAND` intent failing from
inside Termux, which moves phone terminals into tmux.

## Design

### Topology: preferred hub, fallback hub

There is always **one active relay per owner**. The PC's relay stays the
preferred hub. The phone's own relay is the fallback hub and takes over
whenever the PC relay is unreachable.

```text
PC on                                  PC off
──────────────────────────────         ──────────────────────────────
app ──► PC relay ◄── PC sessions        app ──► phone relay ◄── phone sessions
          ▲                                   (loopback 127.0.0.1:3000)
          └── phone sessions                    │
              (preferred hub)                  └── phone agents mesh (UDS)
```

- **Rooms follow the active hub.** Every pi process on the phone connects to
  the PC relay while it is reachable, otherwise to the phone relay. Why: the
  app needs a single connection to see everything live, and the mesh is
  unified automatically when all agents share one relay.
- **Switching is a reconnect, not a new protocol.** Phone sessions drop and
  re-announce on the other relay. The app already recovers from relay drops
  (reconnect, chat-state recovery, false-offline self-heal).
- **No federation.** The two relays never talk to each other. This closes the
  open "multi-relay" item with the smallest possible change.

Trade-off accepted: switching the PC on or off bounces phone-hosted sessions
in the app for a few seconds. The alternative (two live relays with rooms
split across them) needs a multi-connection transport in the app and a
mesh-only second relay connection in the extension. That is deferred unless
the bounce proves annoying in practice.

### Device model in the app

- The phone appears as a **paired device**, exactly like a PC: one
  `PeerRecord` whose key is the phone's Pi-key, with a user-editable nickname
  (default "This phone").
- The device daemon answers a new `device_info` request:
  `{ host: { platform, label, terminal }, agents: [...] , version }`. The app
  uses it for the device picker, the agent picker and the "open terminal"
  action. Nothing is stored at pairing time, so it stays in sync.
- The **agent picker** only offers what the selected device reports. A PC
  without `agy` on `PATH` offers Pi only; the phone offers AGY only after
  Stage C found a working route.

### Session start flow (app)

1. The user taps "Start session", a project, or Quick actions → "New session".
2. **Device picker**: paired devices whose device room is live. Default is the
   last used device.
3. **Agent picker**: `device_info.agents` of that device. Default is Pi.
4. **Model row (optional)**: it reads "Standard" unless something was picked,
   so nothing changes for users who do not choose. Tapping it opens the
   existing model sheet, fed with the models of that device and agent.
5. The existing branch dialog and dispatch run unchanged, plus three new
   fields: `agent`, `provider`, `model_id`.
5. Result:
   - **Pi**: the tile goes live as today.
   - **AGY**: the app cannot show that chat (explicitly out of scope). It shows
     "AGY läuft auf <device>" with an **Open terminal** action. On the phone
     this switches to Termux; on a PC it says that the terminal is on the PC.

### Phone side (Termux)

| Piece | Role |
|---|---|
| Termux (F-Droid/GitHub build) + Termux:Boot | Linux environment and autostart at boot |
| `nodejs`, `git`, `pi`, `remote-pi` | The same stack as a PC |
| `relay` (Android build) | Fallback hub (Stage B) |
| `pi-supervisord` + device daemon | Always-on control channel, started by the boot script |
| `remote-pi phone-setup` | One guided command: checks, install, start, print pairing link |

- **Terminal sessions live in tmux.** The daemon starts each session as a
  detached tmux session, the phone equivalent of one terminal tab on the PC.
  "Open terminal" brings Termux to the front and attaches to it. Why: the
  spike showed Termux's `RUN_COMMAND` intent failing from inside Termux, while
  tmux worked for Pi and for AGY.
- **Projects live in the Termux home** (`~/source` by default, the same
  `projects.roots` default as on a PC). Shared storage is slow and permission
  bound, so it is not used for repositories.
- **Projects get onto the phone by `git clone`** in Termux. Cloning from the
  PC over the mesh is a follow-up.

### Protocol changes

- `open_terminal_request` and `start_session_request` gain
  `agent?: "pi" | "agy"` (default `pi`) plus the optional `provider` / `model_id`
  pair that `spawn_worktree` already carries. `spawn_worktree` (Pi tool,
  `$rp_control`, MCP) gains the same `agent` field.
- `list_models` gains `agent?: "agy"`. Without it, behaviour is unchanged
  (Pi's registry). With it, the reply lists AGY's models of that device.
- New `device_info_request` / `device_info_result` pair on the device room.
- An unknown agent value is an error, never a silent fallback to Pi. Why: the
  user asked for AGY, and starting Pi instead would look like success.
- **One wire shape for every agent.** A model is `{ provider, id, name }` on
  the wire, as today. For AGY, `id` is AGY's own model id (`gemini-3.8-flash-high`)
  and `provider` is a display grouping derived from the id (`claude-*` →
  `anthropic`, `gemini-*` → `google`, `gpt-*` → `openai`). Only `id` goes to
  the AGY command line. Why: the app renders one catalogue type, and the
  picker's provider tabs keep working.

## Expected structure

```text
pi-extension/
  docs/android.md                       # NEW: Termux setup, spikes' findings, limits
  src/actions/launch.ts                 # NEW: agent -> command, platform dispatch
  src/actions/device_info.ts            # NEW: device_info handler + agy probe
  src/actions/agent_models.ts           # NEW: `agy models` probe + parser
  src/actions/open_terminal.ts          # Termux launcher branch, agent param
  src/actions/start_session.ts          # agent param
  src/actions/termux.ts                 # NEW: tmux session launcher
  src/daemon/install.ts                 # "android" platform: Termux:Boot script
  src/transport/relay_client.ts         # Stage B: ordered relay list + promotion
  src/config.ts                         # relay_fallbacks, local_relay (Stage B)
  src/doctor.ts                         # Android checks
  src/main.ts                           # remote-pi phone-setup, agent plumbing
  src/protocol/{types,codec}.ts         # agent, device_info_*
relay/
  src/main.rs                           # REMOTEPI_RELAY_BIND (Stage B)
  .github/workflows/relay-android.yml   # Stage B: aarch64-linux-android artifact
app/
  lib/protocol/protocol.dart            # agent, device_info_*
  lib/data/actions/actions_repository.dart
  lib/ui/projects/                      # start sheet: device, agent, model
  lib/ui/home/...                       # start-session entry points, open-terminal
  lib/ui/chat/quick_actions/widgets/model_picker_sheet.dart  # reusable body
  lib/data/transport/relay_endpoint.dart # Stage B: EndpointKind.local
  lib/data/mesh/mesh_sync_service.dart  # Stage B: publish to every relay
```

## Step 0 — Spikes (done 2026-11-25)

All three ran on the owner's Z Fold 4 and are written up in
[`pi-extension/docs/android.md`](../pi-extension/docs/android.md). S1 and S2
decide Stage B, S3 decides Stage C.

**Results**

- **S1 passed.** Supervisor, device daemon and a visible Pi session run in
  Termux. The app pairs, lists the phone's projects and chats with the
  session, and survived eight hours overnight unplugged.
- **S2 passed.** The relay builds on the phone in 12 minutes and runs there.
  `/health` and a Pi login were verified over loopback and from the PC.
- **S3 passed.** AGY 1.5.16 runs inside proot-distro Debian 13, signed in, and
  finished its first task in 16 seconds.

Two findings change the design below. Termux must be 0.119.0-beta.3 or newer
on Android 16. And phone sessions are started inside tmux, because Termux's
`RUN_COMMAND` intent failed from inside Termux.

### S1 — Termux base run against the PC relay

1. Install Termux from GitHub or F-Droid and Termux:Boot.
2. `pkg update && pkg install nodejs git binutils`, then install `pi` and
   `remote-pi` globally.
3. Create `~/source/demo` (a git repo), start `pi` there and pair it with the
   app by pasting the `remotepi://pair` link. Use the PC relay's LAN URL.
4. Start `pi-supervisord` in a second Termux session. Expect the device room
   to appear and Projects to list the repo. `open_terminal` must answer
   `unsupported` today; record the exact message.
5. Soak for one hour with stock Android settings, then again after applying
   the phantom-process settings below. Count kills in `logcat`.
6. Record idle RAM and CPU of daemon + one pi session.

**Acceptance**
- A pi session started by hand in Termux is visible in the app and chat works
  through the PC relay.
- `list_projects` returns the Termux `~/source` repositories.
- The doc states whether the phantom-process settings are required and how
  often Android killed processes without them.

### S2 — Relay on Android

1. Build on device first: `pkg install rust binutils openssl clang`, then
   `OPENSSL_NO_VENDOR=1 OPENSSL_DIR=$PREFIX cargo build --release` in
   `relay/`. Cross compiling with `cargo-ndk` is the stretch goal.
2. Run it with a persistent data directory
   (`REMOTEPI_MESH_DB_PATH=~/.pi/piper/relay/mesh.db`).
3. Check `/health` from Termux and from the Piper app against
   `http://127.0.0.1:3000`. The app permits cleartext for every host
   (`network_security_config.xml`), so loopback needs no config change.
4. Run one hour with the Termux wake lock held.

**Acceptance**
- `/health` answers 200 over loopback from the app and from another device
  over LAN.
- Idle CPU and RAM are recorded, and the relay survives the hour.

### S3 — AGY on the Z Fold 4

1. Check Android version and `getprop ro.virtualization.supported`. Look for
   the Linux Terminal entry in Developer options.
2. **Route A (built-in Linux Terminal, a Debian VM)**, if present: install the
   AGY CLI inside it with Google's `install.sh`, sign in, run one small task.
   Record start time, RAM, and whether the VM's port 3000 is reachable from
   Android at `127.0.0.1`.
3. **Route B (Termux + proot-distro)**: `pkg install proot-distro`, install
   Debian, run the same AGY install inside it. Record the same numbers plus
   the proot overhead.
4. Write the verdict: route, or **no-go**.

**Acceptance**
- `docs/android.md` has an "AGY on Android" section with timings and a
  go/no-go. A no-go is a valid outcome and defers Stage C.

## Stage A — The phone is a host (with the PC on)

Depends on S1 only. Delivers: location choice, AGY selectable, Pi sessions on
the phone.

### A1 — Protocol: `agent` and `device_info`

- `protocol/types.ts`: add `agent?`, `provider?` and `model_id?` to both request
  types; add `agent?` to `list_models`; add `device_info_request { id }` and
  `device_info_result { in_reply_to, ok, host?, agents, version, message? }`.
- `protocol/codec.ts`: parse and validate all of them. Model tokens must match
  `SAFE_MODEL_TOKEN` (AGY ids such as `gemini-3.8-flash-high` already do).
- `app/lib/protocol/protocol.dart`: mirror types and codecs.

**Acceptance**
- Round-trip tests on both sides. An unknown agent value and a model token
  with forbidden characters fail validation with a clear error.

### A2 — Extension: agent-aware launcher

- New `actions/launch.ts`: `buildAgentCommand(agent, opts)` returns `pi`,
  `pi --continue`, `pi --session <id>` or `remote-pi agy`, each with the
  optional model flag: `--model <provider>/<id>` for Pi, `--model <id>` for
  AGY. Why the wrapper: `remote-pi agy` installs the mesh plugin and sets
  the env, so the session is a mesh peer from its first turn.
- `openTerminalTab` dispatches by platform: `win32` keeps today's `wt.exe`
  code, Termux gets `actions/termux.ts`, everything else stays unsupported
  with a clear message.
- `handleOpenTerminal`, `handleStartSession` and `_spawnWorktreeSession`
  (Pi tool and MCP) pass `agent` and the model through.
- `actions/device_info.ts` reports the host and probes `agy` once, cached for
  ten minutes.
- **AGY model list**: `list_models { agent: "agy" }` runs `agy models` on that
  device and parses it (`actions/agent_models.ts`). Cached for ten minutes.
- **Model validation at start**: the token must pass `SAFE_MODEL_TOKEN`. When
  the agent's model list is available, an id outside it is an error, because a
  terminal that dies on an unknown model would be invisible to the app. When
  the list is unavailable (offline), the id is passed through and AGY decides.
- **The start model applies to that one session.** It does not change Pi's
  saved default model. Why: a choice made for one session must not move every
  other session.

**Acceptance**
- Unit tests with a mocked launcher: `agent: "agy"` produces the AGY command
  on every surface; a model produces the right `--model` flag per agent.
- An unsupported platform answers `ok:false` with a message naming the
  platform.
- `device_info` reports `["pi", "agy"]` when the probe succeeds and `["pi"]`
  when it fails.
- `list_models { agent: "agy" }` returns the parsed catalogue. A failing `agy`
  call yields `ok:false` with AGY's stderr as the message, never a hang.
- An AGY id outside the list is refused with a clear error.

### A3 — Extension: Termux platform and `remote-pi phone-setup`

- `daemon/install.ts`: `detectPlatform()` returns `"android"` inside Termux.
  `install` writes `~/.termux/boot/start-piper.sh` (wake lock, supervisor,
  logs under `~/.pi/piper/`); `uninstall` removes it.
- `actions/termux.ts`: starts the command in a **detached tmux session** named
  after the room (`tmux new-session -d -s <room> '<command>'`). Why tmux: the
  `RUN_COMMAND` intent failed in the spike, and tmux gives AGY a real terminal
  too. The setup command installs tmux.
- `remote-pi phone-setup` (in `main.ts`): environment checks, `remote-pi
  install`, starts the supervisor, waits for the device room, prints the
  pairing link and copies it to the clipboard when `termux-clipboard-set`
  exists.
- `doctor.ts`: Android checks (boot script, `allow-external-apps`, wake lock).

**Acceptance**
- On the Z Fold 4, `remote-pi phone-setup` ends with a pairing link.
- Pasting it into the app lists the phone as a device with a phone icon.
- "Start session" on the phone starts `pi` in the chosen folder inside a tmux
  session, and the tile goes live in the app.
- `open_terminal` on the phone still honours `remoteCwdAllowed` (a folder
  outside `projects.roots` is refused).

### A4 — App: the start sheet (device, agent, model)

- `IActionsRepository.deviceInfo()`; the Projects and Home view models expose
  the reachable devices.
- One start sheet for Projects, "Start session" and Quick actions → "New
  session", with three rows:
  - **Device**: reachable devices only. An unreachable one is disabled with a
    hint. The last used device is the default.
  - **Agent**: `device_info.agents`. Pi is the default. The last choice is
    remembered per device.
  - **Model**: reads "Standard" unless something was picked. Tapping it opens
    the existing model sheet with the models of that device and agent.
- `IActionsRepository.listModels` gains an `agent` parameter and routes to the
  selected device's room, the way `listProjects` does. The per-session cache
  covers it.
- **Reuse the model sheet, not its wiring.** Today the sheet's body is private
  to `model_picker_sheet.dart` and bound to `QuickActionsViewModel`. Extract a
  reusable body that takes a loader and an `onPick` callback. The Quick
  actions sheet keeps its behaviour through the same widget.
- AGY result handling: snackbar with "Open terminal".

**Acceptance**
- Widget tests: one offline device is disabled; AGY is not offered on a device
  that does not report it; the chosen device receives the request.
- Starting without touching the model row sends no model fields, so the
  session starts exactly as before.
- Picking a model and starting sends `agent`, `provider` and `model_id`; a Pi
  tile reports that model once it is live.
- Starting AGY on the PC with a model opens a terminal window running
  `remote-pi agy --model <id>` there.
- The Quick actions "Choose a model" sheet still lists and switches the live
  session's model.

### A5 — App: "Open in Termux" for phone sessions

- Chat action for sessions whose device reports `platform: "android"`: launch
  Termux's main activity.

**Acceptance**
- Tapping it brings Termux to the front. Without Termux installed it shows an
  explanatory message instead of failing silently.

### A6 — Docs and changelogs

- `pi-extension/README.md`: "Android host" section. `PROTOCOL.md`: `agent`
  and `device_info` rows. `app/assets/CHANGELOG.md`, `pi-extension/CHANGELOG.md`.

## Stage B — Without the PC: the phone's own relay (detail: plan 173)

Depends on S2. Delivers: phone sessions and phone-only mesh with the PC off;
one mesh again as soon as the PC relay is back.

- **B1 Relay artifact.** `REMOTEPI_RELAY_BIND` (default `0.0.0.0`, phone uses
  `127.0.0.1`). A `relay-android.yml` workflow publishes
  `relay-<version>-aarch64-linux-android.tar.gz`. Optional cargo feature to
  drop `openssl` (web-push) from the Android build.
- **B2 Managed local relay.** The device daemon starts and watches the phone's
  relay (config `local_relay: { enabled, bin, port }`): `/health` probe,
  restart with backoff.
- **B3 Relay preference in the extension.** `relay` is the preferred hub,
  `relay_fallbacks` the ordered list behind it. `RelayClient` tries them in
  order and restarts from the top on every reconnect. While on a fallback it
  probes the preferred relay's `/health` every 30 s; two successes trigger a
  reconnect, with at least 60 s between two switches.
- **B4 Mesh directory on both relays.** `MeshSyncService.publish()` sends the
  owner-signed mesh blob to every distinct relay URL the app knows
  (preferences, endpoints, members). Why: a relay only serves rooms for
  members it can verify, so a phone relay without the blob would hide the
  phone's own sessions.
- **B5 App endpoint `local`.** `EndpointKind.local` joins the ordered
  candidate list last (LAN, then Tailscale/manual, then local). While
  connected to `local`, the recheck timer probes the other candidates and
  reconnects to the first that answers twice. A Settings entry "Relay auf
  diesem Telefon" holds the loopback URL.
- **B6 Re-pair once.** `phone-setup` prints a link whose `r` is the loopback
  relay; the app adopts it as the `local` endpoint.

**Acceptance (Stage B)**
- PC off: phone sessions are visible in the app and chat works; phone agents
  reach each other through the local broker.
- PC on: within two minutes all sessions sit on the PC relay, and
  `list_peers` on a PC shows the phone's agents.
- PC off again: within one minute the phone sessions are back through the
  local relay, after exactly one reconnect.
- Switching the PC five times in a row leaves no stuck "offline" tile.

## Stage C — AGY on the phone (detail: plan 174)

- The route is fixed by S3: proot-distro Debian 13. The launcher gains a
  **prelude** for AGY, run inside the session's tmux window:
  `proot-distro login debian --bind <termux home>:/root/termux-home -- bash -lc
  'remote-pi agy …'`.
- **Sign-in helper.** With `SSH_CONNECTION` set, AGY prints its OAuth URL. The
  helper shows the URL, opens it in any browser, and types the returned
  authorization code into the CLI. Consent to data collection stays with the
  owner.
- `remote-pi agy` needs Node and the extension inside the distro for the mesh
  plugin. The setup command installs both there.
- `device_info.agents` includes `agy` on the phone once the distro and the
  binary are found.

**Acceptance**
- From the app: choose the phone, choose AGY, and a terminal opens on the
  phone with AGY signed in inside the chosen folder.
- From inside AGY, `list_peers` shows the phone's Pi agents: the mesh plugin
  is active.

## Security notes

- **Same trust model as a PC.** The phone daemon accepts the same requests
  under the same guards: pairing, relay auth, and `remoteCwdAllowed`.
- **`allow-external-apps=true` widens Termux's surface.** It lets other apps
  holding Termux's run-command permission start processes in Termux. The
  Piper app does not need it (it talks through the relay). The setup command
  explains this and the docs repeat it.
- **Bind the phone relay to `127.0.0.1`.** Nobody on the WLAN should reach the
  phone's relay by default.
- **Termux storage is app-private** and covered by device encryption.

## DoD

- [x] **Step 0**: S1, S2, S3 written up in `pi-extension/docs/android.md` with
      go/no-go for S2 and S3.
- [ ] **Stage A**: from the app, the user picks PC or phone and Pi or AGY.
      Pi sessions on the phone are chat-capable in the app and can be opened
      in Termux. AGY starts on the PC and on the phone (Stage C for the
      latter). AGY sessions are not shown as chats (by decision).
- [ ] **Model at start**: either agent can be started with a chosen model.
      Leaving the row untouched starts the session exactly as before.
- [ ] **Stage B**: with the PC off, phone sessions work in the app and the
      phone's agents form a mesh. With the PC on, everything is one mesh
      again.
- [ ] **Stage C** (conditional): AGY runs on the phone and is offered in the
      agent picker.
- [ ] No regression for PC-only users: default device, default agent and the
      Windows launch path are unchanged.
- [ ] Unit and widget tests for every new wire field and picker.

## Next plans

- **173**: Stage B in detail (relay artifact, managed relay, relay
  preference, `local` endpoint, mesh fan-out).
- **174**: Stage C in detail, based on the S3 route.
- **175**: AGY chat in the app (transcript, tool calls, approvals). Deferred
  by decision; the biggest single item.
- Start AGY with an initial task and receive the result as a mesh message.
- Switch the model of a running AGY session from the app. AGY ships a
  `remote-control` daemon and an ACP server (see `agy --help`); evaluate them
  as the channel when planning 175.
- List of terminal sessions started from the app, with "stop".
- Clone a project from the PC to the phone over the mesh (plan 158).
- AGY on the phone without Termux, if the Linux Terminal route wins.
