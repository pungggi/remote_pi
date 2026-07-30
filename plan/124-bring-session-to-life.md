# Plan 124 — Bring an offline session to life (resume in its own cwd)

## Context

**User goal:** from the phone, tap a session in the **Offline** list and
**bring it back to life** — i.e. continue working in **that session's existing
cwd** (often a git worktree) with its **existing conversation history**. No new
worktree, no permanent pin.

**Why it doesn't work today.** A session is a conversation bound to
`(pubkey, roomId)` where `roomId = roomIdFor(cwd, name)`. A session is offline
when no `pi` process is running at its cwd. The only ways to bring its room back
online are:

1. Walk to the PC and run `pi` in that cwd.
2. **Pin** it (plan/113) → supervisor runs `pi` there **always**, resurrected at
   every boot.
3. Long-press → **Open terminal** (plan/108/120) → spawns a **new worktree**
   off the folder, i.e. a **new** session/conversation. The original offline room
   stays dead.

There is no **one-shot revive**: "start `pi` at this session's cwd, run until it
dies or the PC reboots, continue the existing chat, but do **not** pin it."

**Key enablers already present (this plan leans on all of them):**

- The supervisor already spawns `pi --mode rpc` per cwd. The child is launched
  with **`--continue`**, which resumes the **most recent** session JSONL for the
  cwd (`rpc_child.ts` → `rpcSpawnArgs`, `useContinue = true`). So a revived
  process automatically **continues the existing conversation** — no history work
  needed.
- Room identity (`rooms.ts` → `roomIdFor`): for the common case (an unnamed
  agent, or one whose name equals `defaultAgentName(cwd)`), the room is purely a
  function of cwd (legacy `roomIdForCwd`). So a spawn at the session's cwd lands
  in the **same room** → the offline tile flips live → same conversation. For a
  **custom-named** session the room is name-scoped, so the spawn must pass the
  same `--name`; the app already has it (`HomeItem.room.name`).
- The phone already reaches the **device daemon** (fixed room `"device"`,
  plan/120) to dispatch offline actions; `open_terminal` already falls back to
  it. The same channel carries this new action.
- The supervisor exposes a control UDS (`daemon/client.ts`) with `register` /
  `start` / `stop`. **But `register` → `addDaemon` → `saveRegistry`** persists to
  `daemons.json`, and `_spawnAllFromRegistry()` runs at boot — so `register` is
  effectively a **pin** (always resurrected). There is **no transient spawn**.

**The one genuinely new piece:** a supervisor op that spawns the child **without
persisting** to the registry — alive now, auto-restarted on crash while the
supervisor lives, **not** resurrected at boot or by `stop_all`.

## Non-goals

- Not creating worktrees or new sessions. The whole point is to reuse the
  existing cwd + conversation.
- Not always-on pinning (plan/113 already does that). Revive is on-demand and
  non-persistent; the user can still pin separately if they want permanence.
- Not waking a powered-off PC (that's plan/120 "Next 123" — Wake-on-LAN). Revive
  requires the supervisor/device daemon to already be reachable.

## Design

```
Phone (offline tile)                      Relay                      PC
──────────────────────         ─────────────────────         ───────────────────────
long-press → "Start session" ─► (pubkey, "device") ──► device daemon's extension
HomeViewModel.startSession                                       ↓ start_session_request {cwd,name?}
  switchTo + wait-for-online                                      ↓
  route to device room (plan/120)                                daemon/client.ts → supervisor
                                                                  ↓ op: "start_transient" {cwd,name?}
                                                                  spawn pi --mode rpc --continue [--name X]
                                                                      -e <remote-pi> --approve   (at cwd)
                                                                  ↓ connects in room = roomIdFor(cwd,name)
                                                                  ← start_session_result {ok, room_id}
tile flips live as room is announced  ◄── room_announced (rooms push) ◄─
chat opens into the EXISTING history (--continue reused the jsonl)
```

### Supervisor — transient spawn (new)

- New control op `start_transient { cwd; name? }` in `daemon/control_protocol.ts`
  (`ControlRequest` union) + reply shape `{ id; cwd; room_id }`.
- `daemon/supervisor.ts` `_opStartTransient`: spawn the child with the **same**
  machinery as a registered daemon (`rpcSpawnArgs(ext, name, /*useContinue*/ true)`
  + the env injection `_spawnDeviceDaemon`/`_spawnOne` already use), in a
  **transient slot** keyed by `daemonIdForCwd(cwd)` — **not** added to the
  registry, **not** persisted. Compute `room_id = roomIdFor(cwd, name)` for the
  reply.
- Lifecycle rules:
  - **Auto-restart on crash** with the same backoff as registered daemons (the
    user wants it alive; a transient that dies and stays dead is a worse UX than
    a pin). Reuses the existing `restartTimer`/`restartAttempt` slot fields.
  - **Not resurrected at boot** — `_spawnAllFromRegistry()` only iterates the
    persisted registry, so a transient is gone after a supervisor/PC restart.
  - **`stop_all` / `stop {id}`** stops it (a transient is stoppable by id, and
    `stop_all` clears transient slots too).
  - **Idempotent:** if a child (registered **or** transient) already exists for
    `cwd`, return ok with the existing id/room — don't double-spawn. (Mirrors
    `addDaemon`'s "already registered" guard, but as success not error.)
- Registry/`daemons.json` is untouched. Pinned-fleet reconcile (plan/113) ignores
  transient slots.

### Protocol (app ↔ extension; no relay change — envelopes forward verbatim)

One new request/result pair on the same typed-action channel as
`open_terminal` / `list_projects`, routed to room `"device"` exactly like the
plan/120 offline fallback:

```
ClientMessage += StartSessionRequest  { type:"start_session_request", id,
                                        cwd, name? }
ServerMessage += StartSessionResult   { type:"start_session_result", in_reply_to,
                                        ok, room_id?, message? }
```

Codec: add the server type to `SERVER_TYPES`. App `sync_service.dart`
ignore-group gains the result (owned by `ActionsRepository`).

### pi-extension handler (device-daemon action dispatcher)

- `src/actions/handlers.ts`: `handleStartSession({cwd, name})` → calls
  `callSupervisor({ op:"start_transient", cwd, name })`; on
  `SupervisorOfflineError` replies `{ok:false, message:"Supervisor not running —
  run /remote-pi install"}`; on success replies `{ok:true, room_id}`. Routed by
  the device daemon's action dispatcher (alongside `list_worktrees_request` /
  `list_projects_request`).
- `types.ts`/`codec.ts`: the two new message types.

### App

- `data/actions/actions_repository.dart`: `Future<StartSessionResult>
  startSession({required String cwd, String? name})` — mirrors `openTerminal`'s
  routing: switch peer → wait-for-online → decide room (session room if live,
  else `kDeviceRoom`) → dispatch.
- `ui/home/viewmodels/home_viewmodel.dart`: `startSession(HomeItem it)` wrapper
  that pulls `cwd = it.room.cwd`, `name = it.room.name`, calls the repo, and
  surfaces `ActionFailure` toasts.
- `ui/home/home_page.dart` long-press menu: new entry **"Start session"** (⚡
  `LucideIcons.zap`), shown **only when `!isLive`** (an online session is already
  alive — the entry is hidden or disabled). Tapping it:
  1. optimistic: brief "Starting…" snackbar;
  2. `vm.startSession(it)`;
  3. on `ok`, **do nothing else** — the rooms push will announce the room and the
     tile flips live on its own (single source of truth). Optionally auto-open
     chat once the room goes live.
  4. on failure, toast the message (same "Could not reach `<PC>`…" guidance as
     plan/120 when the device room is offline).

## Steps

1. **Supervisor: transient spawn op.** `control_protocol.ts` (request/reply
   types) + `supervisor.ts` (`_opStartTransient`, transient slot map, crash
   restart, `stop_all`/`stop` coverage, idempotence, boot exclusion). Unit-test:
   spawn without persisting (assert `daemons.json` unchanged), idempotent re-spawn
   returns same id, `stop_all` clears it, registry reconcile ignores it.
   **Acceptance:** `callSupervisor({op:"start_transient", cwd})` spawns a child
   in `daemonIdForCwd(cwd)`, `loadRegistry()` is unchanged, the child
   auto-restarts once on a forced crash.

2. **Protocol + handler (extension).** `types.ts`/`codec.ts` (2 types) +
   `actions/handlers.ts` (`handleStartSession` → `start_transient`). Action-
   dispatch test: send `start_session_request`, assert a `start_session_result`
   with the expected `room_id = roomIdFor(cwd, name)`. **Acceptance:** a fake
   supervisor confirms the op + payload (`cwd`, `name`); supervisor offline →
   `ok:false` with the install hint.

3. **App: action + repository.** Mirror types in `protocol.dart`;
   `ActionsRepository.startSession` (+ `onMessage` result + `sync_service`
   ignore-group); update test fakes. **Acceptance:** unit test dispatches
   `start_session_request {cwd,name}` to the device room when the session room is
   offline, and to the session room when live.

4. **App: UI.** Long-press "Start session" entry, offline-only; `HomeViewModel`
   wrapper; optimistic snackbar + failure toast; (optional) auto-open chat on
   room-live. `dart analyze` clean. **Acceptance:** on an offline tile, the entry
   appears; on an online tile it is hidden/disabled.

5. **Verify end-to-end on device.** With the Cockpit/supervisor up and **no** `pi`
   running at a worktree cwd: long-press the offline tile → "Start session" →
   within ~5 s the tile flips live → open chat → the **previous conversation is
   there** (`--continue` reused the jsonl) → send a message, it continues the
   same session. Kill the spawned `pi` → it auto-restarts once. Stop the
   supervisor → on next boot the session is **offline again** (not pinned).
   **Acceptance:** revived session reuses history; not resurrected at boot.

## DoD

- [ ] Long-pressing an **offline** session and choosing **Start session** spawns a
      `pi` at that session's cwd (no new worktree), the room comes online, and the
      existing conversation history is present.
- [ ] The action is **not** a pin: nothing is written to `daemons.json` /
      `pinned.json`; after a supervisor or PC restart the session is offline again.
- [ ] Custom-named sessions revive into the **same** room (name-scoped), not a
      sibling; default-named sessions revive into the legacy cwd room.
- [ ] Online tiles do not show the entry (already alive). Device room offline →
      clear "Could not reach `<PC>`…" error (no silent hang).
- [ ] Idempotent: reviving an already-live session is a no-op success.
- [ ] `tsc --noEmit` clean; `dart analyze` clean; existing tests pass.

## Next plans

- **125:** Surface revive state in the Cockpit (list transient daemons separately
  from pinned; one-tap "stop" for a revived session).
- **126:** "Revive & open" as the **primary** tap action on offline tiles (today a
  bare tap is inert) — make offline tiles tappable = bring to life, with the
  worktree/pin actions demoted to the long-press menu.
- **127:** Auto-retire a revived session after N minutes idle (configurable), so a
  forgotten revive doesn't hold a process forever — the lightweight cousin of
  plan/113's "lazy pin".
