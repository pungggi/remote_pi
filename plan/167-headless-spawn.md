# Plan 167 — Headless spawn (`spawn_worktree {headless:true}`)

## Context

Plan/161 gave agents `spawn_worktree` — but only the **visible-terminal** variant
(the 2026-11-08 trust decision explicitly deferred the headless daemon option).
Plan/166 closed the lifecycle at the other end (`session_shutdown`). What's
still missing for a complete agent-worker story: spawn a worker **without a
terminal window** — invisible, RPC-driven, mesh-reachable, restart-safe.

The machinery already exists and is battle-tested:

- **Supervisor + RPC children** (plan/26/40): `pi --mode rpc -e <ext> --approve`
  children with auto-restart + backoff, controlled via the user-local named
  pipe `~/.pi/piper/supervisor.sock` (`daemon/client.ts`).
- **`start_transient` op** (plan/124): spawn a NON-registry child for a cwd —
  no persistence, no boot resurrection, crash-restart only. Exactly the
  lifecycle an agent-spawned worker needs: it lives until it crashes or
  `session_shutdown`s, then it's gone.
- **Daemon mesh auto-init**: children run with `REMOTE_PI_DAEMON=1`; on
  `session_start` the extension auto-starts remote-pi with the headless ctx
  (main.ts `_cmdRoot`). With `auto_start_relay` config present, the child
  joins the relay as a **mesh peer** — `list_peers`, `agent_send`,
  `session_shutdown` all work against it.
- **Config seeding**: `createWorktree()` already writes
  `saveLocalConfig(worktreePath, { agent_name: basename(baseCwd), auto_start_relay: true })`
  — the worktree is mesh-ready before any `pi` starts. No wizard needed
  (the RPC child has none; rpc_child bails early without local config).

**Gap**: `spawn_worktree` composes `createWorktree` + `openTerminalTab` —
no way to reach `start_transient`. And `start_transient` cannot carry a model
(`rpcSpawnArgs` has no `--model` flag; plan/161 requires "model at spawn via
standard `pi --model provider/pattern`").

## Design decisions (grounded in existing code)

- **Opt-in flag, default unchanged**: `headless?: boolean`, default `false`.
  Visible terminal stays the default; no behavior change for existing callers
  on any surface (Pi tool, `$rp_control` envelope, MCP).
- **Model flows through the supervisor**: `start_transient` gains
  `model?: string` (pre-joined `provider/id`, `SAFE_MODEL_TOKEN`-validated at
  every entry point BEFORE the pipe write). `rpcSpawnArgs` gains an optional
  model param → appends `--model <provider>/<id>`. The named pipe is
  user-local, so no new trust boundary — validation is correctness, not security.
- **`--continue` divergence is accepted and documented**: RPC children resume
  the most recent session for the cwd on (re)start. A **fresh** worktree has
  no prior session → first boot is a new session (same as visible). On a
  **reused** worktree the headless child CONTINUES the old conversation while
  the visible path starts a new one — that's the supervisor's core value
  (crash-restart keeps the worker's work); documented in PROTOCOL.md, not "fixed".
- **No supervisor → honest error**: `SupervisorOfflineError` from
  `callSupervisor` resolves `ok:false` with an actionable hint (start
  `pi-supervisord` / the "Piper Supervisor" logon task, or spawn without
  `headless`). No silent fallback to a visible terminal — the caller asked
  for invisible.
- **Idempotent already-running**: `start_transient` replies `started:false`
  when a child for that cwd exists; surface that as ok with a "already
  running" note (re-tap semantics, matching worktree reuse).
- **No new security surface**: remote peers still only reach `$rp_control`;
  the extension itself creates the worktree (git-base guarded, registry
  entry written) and then calls ITS OWN supervisor with the path it built.
  `remoteCwdAllowed` (fix M3) is satisfied by construction.

## Expected structure

### pi-extension

- `protocol/types.ts` — `RpControlRequest` spawn payload gains `headless?: boolean`.
- `daemon/control_protocol.ts` — `start_transient` request gains `model?: string`.
- `daemon/rpc_child.ts` — `rpcSpawnArgs(extensionPath, sessionName?, useContinue, model?)`
  appends `["--model", model]` when set; supervisor `start_transient` handler
  threads it through.
- `main.ts` — `_spawnWorktreeSession({..., headless?})`:
  - `headless:false` (or unset): exactly today's path (createWorktree → openTerminalTab).
  - `headless:true`: createWorktree → `callSupervisor({op:"start_transient",
    cwd: wt.entry.path, model?})` → reply with the **peer address**
    `<worktree-path>@<agent_name>` + "appears in list_peers shortly; send it a
    task with agent_send; end it with session_shutdown".
  - `SupervisorOfflineError` → `ok:false` with the hint above.
- `session/control_tools.ts` — Pi tool `spawn_worktree` schema + description
  gain `headless?`; result text mentions the headless specifics.
- `mcp/mesh_server.ts` — MCP `spawn_worktree` schema gains `headless?`; same
  validation order as the Pi tool (token check BEFORE headless dispatch).

### Docs

- `PROTOCOL.md` — tool table row: `headless` optional flag, the `--continue`
  divergence note, supervisor prerequisite.
- `skills/agent-network/SKILL.md` — table row + one line: headless workers
  appear in `list_peers` like any peer; shutdown closes them (clean exit,
  no restart, worktree + uncommitted work stay).
- `CHANGELOG.md` — entry.

## Steps

1. **Supervisor: model on `start_transient`.**
   `control_protocol.ts` type + `supervisor.ts` handler threading +
   `rpcSpawnArgs(extensionPath, sessionName?, useContinue, model?)`.
   AC: unit test asserts `--model provider/id` appended when set, absent when
   not; `tsc` clean; existing supervisor/rpc_child tests untouched and green.

2. **Extension: headless branch of `_spawnWorktreeSession`.**
   Flag on `RpControlRequest`, `_spawnWorktreeSession`, Pi tool, MCP tool.
   AC: unit tests (mocked `createWorktree` + `callSupervisor`):
   - headless:false → openTerminalTab path unchanged (existing tests prove it).
   - headless:true + supervisor online + started → ok, reply contains the peer
     address and `agent_send`/`session_shutdown` hints.
   - headless:true + `started:false` → ok, "already running" note.
   - headless:true + `SupervisorOfflineError` → ok:false, hint mentions
     supervisor + fallback.
   - model + headless → `model` reaches `callSupervisor` (joined, validated).
   - half/invalid model rejected identically on both paths (shared guard).

3. **Docs + CHANGELOG.**

4. **Live e2e (same-PC mesh, like plan/166's rig).**
   AC:
   - `spawn_worktree {branch, headless:true}` from an interactive peer →
     new peer visible in `list_peers` within seconds, **no terminal window**.
   - `agent_send` a tiny task → worker replies on its next turn.
   - `session_shutdown` on the worker → peer vanishes from roster; supervisor
     `list` shows no resurrected child (clean exit, transient).
   - `spawn_worktree` without `headless` still opens a visible terminal.
   - worktree still listed by `listWorktrees`; `removeWorktree` cleans up.

5. **PR + merge** (review bot if funded, else user-direct as with #111/#112).

## DoD

An agent can grow an invisible worker fleet end-to-end:
`spawn_worktree {headless:true, model}` → task via `agent_send` →
`session_shutdown` — no terminal windows, restart-safe while alive, gone
without residue when done. Visible spawn unchanged; all surfaces flag-gated;
supervisor-less machines get an actionable error instead of a hang.

## Next

- **167b** — `spawn_dir` headless without a git base (plan/121's `spawn-dir`
  surface on transient daemons) for non-git task folders.
- **167c** — headless worker concurrency caps (max transient children per
  supervisor; refuse with roster when exceeded).
- **167d** — auto-pin a headless worker's worktree at spawn (`pinned` marker)
  so it survives PC reboots for long-running fleets.
