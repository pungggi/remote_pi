# Plan 120 — Open terminal from offline session via supervisor device daemon

## Context

**Problem:** Tapping "Open terminal" on an offline session (Offline tab) fails with
a timeout. The action targets `(pubkey, room_id)` on the relay, but no pi process
is connected for that room — the Pi session for that cwd isn't running.

**Why we can't just retry:** Opening a terminal on a remote PC requires a process
there that (a) is connected to the relay and (b) can spawn a local terminal. Today
only the Pi extension does this, and it's only alive while a `pi` session runs in
that cwd.

**Key architectural facts that make this solvable:**

- The **Pi-key is a singleton per machine** (`~/.pi/piper/identity.json` or platform
  keyring). Every `pi` process on a PC shares the same Ed25519 keypair. The phone
  pairs against this pubkey.
- The **relay routes by `(pubkey, room_id)`**. Multiple processes with the same
  keypair coexist in different rooms.
- **`open_terminal_request` is handled by the pi-extension**, which any `pi`
  process loads — regardless of its own cwd. The request carries the target `cwd`,
  so the handler creates the worktree at the *requested* path, not the agent's own.
- The **Cockpit is a long-running desktop app** that stays open while individual pi
  sessions come and go. It can spawn `pi --mode rpc` processes.

**Insight:** The supervisor (`pi-supervisord`) is a background system service
installed via `remote-pi install`. It always spawns a "device daemon" — a
`pi --mode rpc` child that connects to the relay in a well-known `"device"`
room. The phone routes offline terminal-open requests there. The device
daemon's pi-extension handles the request and opens a terminal at the requested
cwd on that PC.

## Expected structure

```
Phone (offline session)                     Relay                      PC
─────────────────────────         ──────────────────         ──────────────────────
HomeViewModel.openTerminal  ──►   (pubkey, "device")   ──►   Cockpit device agent
  offline? → device room                                      pi --mode rpc (temp dir)
                                                              ↓ open_terminal_request
                                                              pi-extension handler
                                                              ↓
                                                              worktree + wt.exe tab
```

### Device room

A fixed, well-known room ID so both sides agree without negotiation:

```
kDeviceRoom = "device"
```

Routing still includes the pubkey, so there's no cross-machine collision.

### Cockpit device agent

A `pi --mode rpc --no-session` process spawned by the Cockpit on startup (or on
first relay connect), kept alive for the Cockpit's lifetime. It:

1. Runs in a temp directory (avoids cwd-lock conflicts with real sessions).
2. Uses `REMOTE_PI_DIRECT_CONFIG` with `agent_name: "device"` +
   `auto_start_relay: true` so it connects to the relay automatically.
3. Connects in room `"device"` (injected via the config/hello).
4. Loads the remote-pi extension (no `--no-extensions`) so it handles
   `open_terminal_request`.
5. Does NOT appear as a chat session on the phone (the `"device"` room is
   filtered out of the rooms list, or simply never announces room_meta that the
   app renders — see "Rooms filtering" below).

The Cockpit communicates with it over the existing RPC stdin/stdout channel only
for lifecycle (start/stop). Terminal-open is handled autonomously by the extension.

### Phone fallback routing

When `openTerminal` targets an offline session:

1. Switch the connection to the target peer (already done — `switchTo`).
2. Wait for `StatusOnline` (already done — plan/108-offline).
3. **NEW:** if the target room is offline, dispatch to room `"device"` instead of
   the session room. The `open_terminal_request` carries the original `cwd` +
   `branch`, so the device agent creates the worktree at the right path.
4. If the device room also has no recipient → timeout → clear error message.

### Rooms filtering

The device agent must NOT show up as a regular session on the phone. Options:

- **A (preferred):** The device agent's `room_meta` carries a flag
  (`device: true` or `kind: "device"`). The app filters it out of `HomeList.items`.
- **B (simpler):** The app filters any room whose id is the literal `"device"`.

## Steps

### Step 1 — Cockpit: spawn the device agent

**Files:** `cockpit/lib/app/cockpit/data/` (new `device_agent.dart`),
`cockpit/lib/app/cockpit/cockpit_module.dart` (wire into boot).

- New `DeviceAgentController` that owns a `pi --mode rpc --no-session` child
  process in a temp dir with `REMOTE_PI_DIRECT_CONFIG`:
  ```json
  { "agent_name": "device", "auto_start_relay": true }
  ```
- The agent must connect in room `"device"`. This needs either:
  - A new config field `room_id: "device"` that the extension honours, OR
  - An env var `REMOTE_PI_ROOM_ID=device` the extension reads at start.
- Start on Cockpit boot (after relay config is confirmed); restart on crash with
  backoff (mirror `EphemeralPiRpc` patterns but persistent).
- Stop on Cockpit shutdown.
- **Acceptance:** `remote-pi` CLI or relay logs show a `(pubkey, "device")`
  connection while the Cockpit is open; it drops on close.

### Step 2 — pi-extension: honour a fixed room override

**Files:** `pi-extension/src/index.ts` (room resolution at `_cmdStart`),
`pi-extension/src/session/local_config.ts` (new `room_id?` field).

- Add `room_id?` to `LocalConfig`. When set, `_cmdStart` uses it verbatim instead
  of `roomIdFor(cwd, name)`.
- Backward compatible: absent → current behaviour (cwd-derived room).
- **Acceptance:** A `pi` started with `room_id: "device"` in its direct config
  connects to the relay in room `"device"` (visible in relay logs / rooms push).

### Step 3 — App: filter the device room from the Home list

**Files:** `app/lib/ui/home/states/home_state.dart` (`HomeList.items`),
`app/lib/data/transport/connection_manager.dart` (room snapshot).

- Filter the `"device"` room (or rooms with `room_meta.kind == "device"`) from
  `HomeList.items` so it never renders as a session tile.
- Keep it in the raw rooms snapshot (the phone needs to know the device agent is
  reachable to decide fallback routing).
- **Acceptance:** With the Cockpit open, no phantom "device" session appears in
  the All/Online/Offline tabs.

### Step 4 — App: fallback dispatch to the device room

**Files:** `app/lib/ui/home/viewmodels/home_viewmodel.dart` (`openTerminal`),
`app/lib/data/actions/actions_repository.dart` (room-scoped dispatch),
`app/lib/data/transport/connection_manager.dart` (if needed).

- Add an optional `room` parameter to `IActionsRepository.openTerminal` /
  `_dispatch` so a single action can target a specific room without globally
  switching the active room (avoids racing other in-flight actions).
- In `HomeViewModel.openTerminal`, after `switchTo` + `_waitForOnline`:
  - If the target room is live → dispatch to the session room (current path).
  - If the target room is offline → dispatch to `kDeviceRoom` instead.
- Constant: `const kDeviceRoom = 'device';` (shared between app + extension).
- **Acceptance:** Tapping "Open terminal" on an offline session (Cockpit open)
  opens a terminal on the PC within a few seconds. Cockpit closed → falls back
  to the timeout error.

### Step 5 — Error message polish

**Files:** `app/lib/ui/home/viewmodels/home_viewmodel.dart` (`_waitForOnline`).

- When the device-room dispatch also times out, show:
  `"Could not reach <name>. Start the Cockpit or Pi on that computer."`
- **Acceptance:** Clear, actionable error when neither Pi nor Cockpit is running.

## DoD

- [ ] Cockpit open + Pi offline → "Open terminal" from Offline tab opens a terminal
      on the PC (worktree + pi tab) within ~5 s.
- [ ] Cockpit closed + Pi offline → clear error message (no silent hang).
- [ ] Pi online → existing fast path unchanged (no device-room round-trip).
- [ ] No phantom "device" session in the Home list.
- [ ] Device agent restarts on crash; stops on Cockpit close.
- [ ] Unit tests: room filtering, fallback routing logic, device-agent lifecycle.

## Next plans

- **121:** Surface device-agent health in the Cockpit (relay dot, restart button).
- **122:** Let the device agent handle other offline actions (git status, model
  list) so the phone's Quick Actions work without a live Pi session too.
- **123:** Wake-on-LAN / auto-start Pi on the PC when the phone requests it
  (requires a always-on supervisor or OS-level service).
