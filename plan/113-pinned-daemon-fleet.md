# Plan 113 — Pinned daemon fleet (always-on projects)

## Context

Stability work so far:
- **Relay** is now reboot-proof — a Windows scheduled task ("Piper Relay") auto-starts `relay.exe` at logon (done this session).
- **pi-extension** already auto-reconnects to the relay with backoff (`1s→2s→5s→10s→30s`) and has a **liveness watchdog** that force-closes half-open sockets after 70 s of silence. Transient drops self-heal.

What's missing is **always-on presence**: today a project only appears on the phone while an interactive `pi` terminal is open there. Close the terminal → the session vanishes from the phone. The user wants chosen projects to stay online permanently, managed by a **daemon**, with the phone able to **pin/unpin** them.

The daemon infra already exists (plan 26/40): a **supervisor** that spawns one headless `pi --mode rpc` child per registered cwd, auto-restarts crashes with backoff, and owns a registry. It is simply **not deployed** here (no supervisor running, empty registry). This plan wires it up and drives it from **pins** instead of manual `/remote-pi create`.

### Design decisions (confirmed with user)

- **Root** to scan: `C:\Users\Alessandro`.
- **Pin = always-on.** A pinned project runs a supervisor daemon → always connected → always in the phone's session list.
- **Two pinning surfaces, one source of truth:**
  - **Marker file** (Piper-side): `.pi/remote-pi/pinned` inside the project (empty; existence = pinned). Survives moves; "Piper writes a file to pin."
  - **App toggle**: pin control on the session tile + ℹ dialog → `pin_project` / `unpin_project` → extension writes/removes the marker.
- **Resource-safe**: only pinned projects run a daemon — no runaway fleet. The user pins what they want.

## Expected structure

### Pin state (source of truth)

- **Marker file** `<cwd>/.pi/remote-pi/pinned` — empty; existence = pinned. Written by the extension (app toggle, CLI) or by hand.
- **Central index** `~/.pi/piper/pinned.json`:
  ```json
  { "pinned": ["C:/Users/Alessandro/source/pi/packages/remote_pi", "..."] }
  ```
  Rebuilt from markers; the supervisor's fast lookup. Always kept in sync with the marker files.
- **Roots** `~/.pi/piper/roots.json`:
  ```json
  { "roots": ["C:/Users/Alessandro"] }
  ```
  Seed with `C:\Users\Alessandro` on first run (configurable via `piper root add/remove` CLI + future app setting).

### Supervisor changes (`daemon/supervisor.ts` + new `daemon/pin_scan.ts`)

1. **Boot reconcile**: scan roots for `.pi/remote-pi/pinned` markers → (re)build `pinned.json` → ensure one daemon per pinned cwd (start missing, stop gone). This **replaces** the manual registry as the fleet driver — the registry is derived from pins.
2. **Event-driven**: app `pin_project` / `unpin_project` → write/remove marker + mutate `pinned.json` + start/stop that one daemon immediately (no scan).
3. **Backstop poll**: every 5 min, re-scan roots + reconcile (catches out-of-band marker changes, e.g. manual `touch`/`rm` or a `git clean`).
4. **Worktree hook**: `open_terminal` create + `removeWorktree` notify the supervisor to reconcile (cheap; mostly a no-op since worktrees aren't auto-pinned).
5. **Pruned scan** (`pin_scan.ts`):
   - Looks for `<dir>/.pi/remote-pi/pinned` (existence check, no JSON parse).
   - **Skip dirs**: `AppData`, `node_modules`, `.git`, `target`, `build`, `dist`, `out`, `.cache`, `.npm`, `.cargo`, `.rustup`, `.gradle`, `.m2`, `Library`, `.venv`, `__pycache__`.
   - **Depth limit**: 6 (covers `home/source/pi/packages/<proj>` and one level of nesting).
   - Symlinks skipped. Single-threaded `readdir` with pruning; target < 2 s on a warm cache.

Each pinned cwd → standard daemon (`pi --mode rpc`), own relay room (`roomIdFor(cwd, name)`), so the phone shows each pinned project as its own session tile (per-project granularity preserved).

### Protocol (app ↔ extension; no relay change — envelopes forward verbatim)

```
ClientMessage +=
  | PinProjectRequest    { type:"pin_project_request",    id, cwd }
  | UnpinProjectRequest  { type:"unpin_project_request",  id, cwd }
  | ListPinnedRequest    { type:"list_pinned_request",    id }

ServerMessage +=
  | PinProjectResult     { type:"pin_project_result",    in_reply_to, ok, message }
  | UnpinProjectResult   { type:"unpin_project_result",  in_reply_to, ok, message }
  | ListPinnedResult     { type:"list_pinned_result",    in_reply_to, ok, paths: string[] }
```

Codec: add the three server types to `SERVER_TYPES`. App `sync_service.dart` ignore-group gains the three results (owned by `ActionsRepository`).

### pi-extension handlers (`daemon/`)

- `handlePinProject(cwd)`: `touch` marker → add to `pinned.json` → `supervisor start <cwd>` (or spawn if supervisor is this process). Reply ok.
- `handleUnpinProject(cwd)`: `rm` marker → remove from `pinned.json` → `supervisor stop <cwd>`. Reply ok.
- `handleListPinned()`: return `pinned.json` paths. Reply ok.
- Marker + index writes are atomic + best-effort (never throw — pinning must not crash pi).

### App

- **Repository**: `IActionsRepository.pinProject(cwd)` / `unpinProject(cwd)` / `listPinned()`.
- **Home session list**: fetch `listPinned()` on Home load; render a **📌 pin icon** per session tile (filled = pinned). Tap toggles → optimistic flip → `pin`/`unpin` → snackbar on failure.
  - **Decision (open)**: tile icon vs long-press menu vs ℹ-dialog-only. Recommend **tile icon + ℹ-dialog toggle** (discoverable + uncluttered). Confirm in step.
- A pinned project's tile shows even when its daemon is the only thing running (it's always connected → always announced → always listed).

### Windows auto-start

- Scheduled task **"Piper Supervisor"** at logon → starts the supervisor entry point (confirm exact binary/entry in step 1; likely `node <pkg>/dist/daemon/supervisor-entry.js` or a `piper supervisord` shim).
- The supervisor reads roots + `pinned.json` → spawns the fleet. After a reboot, pinned projects come back online automatically.
- Relay task ("Piper Relay") already exists.

## Steps

1. **Supervisor entry + auto-start.** The supervisor launches via the `pi-supervisord` bin shim (`dist/bin/supervisord.js`); `install.ts` already writes macOS launchd / Linux systemd units but on Windows only adds PATH shims (plan 40) — **no auto-start**. Add the missing piece: a **"Piper Supervisor" scheduled task at logon** that runs `pi-supervisord` (mirroring the relay task). Verify: after a relog, the supervisor named-pipe socket exists and the relay is up.
2. **Pin scan + index.** `daemon/pin_scan.ts`: pruned root scan → `pinned.json`. `daemon/registry.ts`: derive the fleet from pins (pin = registry entry). Boot reconcile in the supervisor. Unit-test scan pruning + reconcile diff (temp HOME).
3. **Pin handlers + protocol (ext).** `types.ts`/`codec.ts`: 3 new client + 3 new server types. `daemon/pin_handlers.ts`: write/remove marker + mutate index + start/stop daemon. Wire dispatch in `index.ts`. `tsc` + rebuild dist.
4. **App protocol + repository.** Mirror types in `protocol.dart`; `ActionsRepository` methods + `onMessage`; `sync_service` ignore-group. Update test fakes.
5. **App pin UI.** 📌 icon on the session tile (filled/outline from `listPinned`) + toggle in ℹ dialog. Home fetches `listPinned` on load; optimistic toggle. dart analyze clean.
6. **Verify on device.** Pin `remote_pi` from the phone → marker written → daemon spawns → tile stays after closing all terminals → survives a PC relog (supervisor re-spawns). Unpin → daemon stops, tile disappears once the room goes offline.

### Acceptance criteria

- [ ] Pinning a project from the phone writes `.pi/remote-pi/pinned`, starts a daemon, and the project stays in the session list with no terminal open.
- [ ] Unpinning removes the marker, stops the daemon, and the tile disappears (once offline).
- [ ] After a PC relog, the relay + supervisor auto-start and pinned projects come back online unaided.
- [ ] A manually-created marker (`touch <proj>/.pi/remote-pi/pinned`) is picked up by the backstop poll and promoted to a daemon.
- [ ] Scan of `C:\Users\Alessandro` completes in < 3 s with the prune rules; AppData/node_modules/build artifacts never descended into.
- [ ] `tsc --noEmit` clean; dart analyze clean; existing tests pass.

## DoD

Pinned projects are always-online on the phone, managed by the supervisor, auto-starting at logon alongside the relay. Pinning works from both the phone (tile + ℹ dialog) and the filesystem (marker file). Committed + pushed; SESSION-STATUS notes the two scheduled tasks + the dist rebuild.

## Next

- **113b** — roots management UI in the app (add/remove scan roots) + a "discover projects" picker that lists unpinned git repos under a root for one-tap pinning.
- **113c** — per-project resource cap / "lazy pin" (spawn the daemon only when the phone first opens the session, then keep it warm).
- **113d** — pin state broadcast: when a pin changes on the PC, push it to connected phones so all devices' tile icons update live (today the app polls `list_pinned` on Home load).
