# 161 — Agent session control (worktree, spawn, compact, reset, model)

## Context

Mesh agents (plan 19/20) can discover peers (`list_peers`) and talk
(`agent_send`), but they cannot **manage sessions**. Those powers already
exist — they are just app-exclusive:

| Capability | Existing piece (reuse, do not duplicate) |
|---|---|
| Create worktree | `createWorktree()` — `actions/open_terminal.ts` (plan 108/112: branch validation, collision/reuse, worktree registry, `auto_start_relay` config) |
| Start Pi session in it | `openTerminal()` — same file (wt.exe / Start-Process, `pi --session` builder) |
| Compact | `session_compact` → `ctx.compact()` — `actions/handlers.ts` (plan 28) |
| Reset | `session_new` → `ctx.newSession()` — fresh context, SAME process |
| Choose model | `model_set` / `list_models` → `ModelRegistry` + `pi.setModel()` + persist default — `actions/handlers.ts` |
| Model at spawn | standard `pi --model <provider>/<pattern>` CLI flag (pi main.js L358) |

Gap: only the mobile app can invoke these (ClientMessage switch in
`main.ts` ~L5398). Agents get nothing.

User decisions (2026-11-08):

- **Remote control ships ungated** — any mesh peer may control another
  peer's session. Not phased, no allowlist. (A config kill-switch stays as
  the documented opt-out, default on.)
- **Spawn surface = visible terminal** — reuse the plan/108 openTerminal
  path; no headless/daemon variant in this plan.
- **Reset = `ctx.newSession()`** — fresh context, same process. "Starting a
  new session" means spawning a NEW Pi process (typically in a worktree),
  which then joins the mesh and receives work via `agent_send`.

Why this matters: it turns the mesh from a chat room into an orchestration
fabric — a lead agent can carve out a worktree, bring a fresh agent up in
it, hand it a task, compact it when the context grows, and pick the right
model for the job, without the phone or a human in the loop.

## Expected structure

- `pi-extension/src/session/control_tools.ts` (new) — thin tool
  registrations, same hand-written JSON-Schema-literal style as
  `session/tools.ts` (plan 143: no typebox). One tool per app-action verb,
  each with an optional `target`:
  - `session_compact {target?}` → `handleSessionCompact`
  - `session_reset {target?}` → `handleSessionNew` (reset = fresh context)
  - `model_set {provider, model_id, target?}` → `handleModelSet`
  - `list_models {target?}` → `handleListModels`
  - `spawn_worktree {branch?, base?, model?, target?}` → `createWorktree()`
    + `openTerminal(cwd=worktree, command="pi" + optional "--model p/m")`
  - `target` omitted → execute locally against SELF (direct handler call,
    no envelope, no round-trip). `target` = address from `list_peers` →
    reserved control envelope (below). Echo addresses verbatim (plan 38).
- Reserved control envelope — body `{ "$rp_control": { op, ... } }` carried
  by ordinary `agent_send`. Interception in the existing
  `peer.onMessage((env) => ...)` block in `main.ts` (~L5035), after the
  broker-event checks, BEFORE the agent-to-agent fall-through — control
  envelopes are commands, never injected into the target's conversation.
  The handler dispatches to the same `actions/handlers.ts` functions with a
  synthetic `ActionReplySender` that converts `action_ok` / `action_error` /
  `models_list` into a normal reply envelope (`re` = request id). Unknown
  op → typed error reply.
- Dispatch glue extraction — the dep-injection the ClientMessage switch
  does today (`ext.lastEventCtx ?? ext.lastCtx`, registry, model-persist
  callback, `_resetSessionForNew` side effects) moves into one function
  used by BOTH the app path and the control path, so behavior and
  side-effect fan-out (empty `session_history`, `model_select` broadcast)
  stay identical.
- `pi-extension/src/mcp/mesh_server.ts` — register the same five ops as MCP
  tools (Claude / Agy parity), routed through the identical envelope path.
- `pi-extension/skills/agent-network/SKILL.md` — new section: the five
  verbs, `target` semantics, envelope shape, reply-by-`re`.
- Config: `allow_remote_session_control` (default `true`) in local config —
  when false, incoming control envelopes get a `denied`-style error reply.
- Docs: `PROTOCOL.md` addendum (mesh control vocabulary) + CHANGELOG.

## Steps with acceptance criteria

1. **Dispatch extraction** — **done** (2026-11-08): six typed-action
   case bodies moved verbatim into exported `_dispatchSessionAction`
   (main.ts, right after `_resolveRegistry`); the switch delegates via
   grouped case labels; sender widened to `ActionReplySender` so the mesh
   path can pass a synthetic reply sink. `pnpm typecheck` zero errors;
   `pnpm test` 1282 passed / 74 files — zero behavior change (existing
   app-action tests untouched).
2. **Local tools (self)** — **done** (2026-11-08): `session/control_tools.ts`
   registers the five tools (JSON-schema literals, plan/143 style) with
   deps injected from index.ts (`dispatchLocal` → `_runSessionAction`,
   `spawnWorktreeLocal` → `_spawnWorktreeSession` via the lazy runtime).
   13 unit tests in `session/control_tools.test.ts` (local happy/error,
   models formatting, remote envelopes, self-address refusal,
   NOT_IN_SESSION, spawn guards).
3. **Control envelope, remote execution** — **done** (2026-11-08):
   `$rp_control` interception in `_cmdJoin`'s `peer.onMessage` (after broker
   events, before conversational fall-through); `_handleControlEnvelope`
   (kill-switch `allow_remote_session_control`, no-Pi explicit error, op
   synthesis → `_dispatchSessionAction`, sink translating ServerMessage
   replies into `rp_control_result` envelope with `re`); `_spawnWorktreeSession`
   composes `createWorktree` + `openTerminalTab` with sanitized
   `--model provider/id`. 6 tests in `session_control.test.ts` (refusals,
   error piping, reply shape, re-correlation).
4. **spawn_worktree end-to-end** — local and remote-target spawn reuse
   `createWorktree()` unchanged (reuse-if-exists included); acceptance:
   terminal window opens `pi` in the worktree, and the new session appears
   in the sender's `list_peers` shortly after (auto_start_relay, plan 112
   #2) — then a task sent to it via `agent_send` is executed (manual
   checklist, Windows + one macOS/Linux box for cross-PC `<pc>:` prefix).
5. **MCP parity** — **done** (2026-11-08): the five ops registered in
   `remote-pi-mesh` (mesh_server.ts) as sender-side tools with REQUIRED
   `target` (Claude/Agy have no Pi session of their own); shared
   `controlRequest` helper over `_mesh.request`; instructions line added.
   Manual smoke on a live Claude/Agy session still pending (with step 4).
6. **Skill + docs** — **done** (2026-11-08): SKILL.md "Session control
   (plan/161)" section + frontmatter/tools-line updates + summary item 7;
   PROTOCOL.md "Agent mesh session control (plan/161)" addendum;
   CHANGELOG `[Unreleased]` entry. Skill redeploys on next launch.

## DoD

- [ ] A Pi agent can, with zero human involvement: create a worktree,
      spawn a fresh agent in it, hand it work, compact it, reset its
      context, and change its model — locally and on a remote peer.
- [ ] `pnpm test` + `typecheck` green in `pi-extension/`; e2e manual
      matrix (self, same-PC remote, cross-PC remote) recorded in the PR.
- [ ] No duplicated worktree logic; `createWorktree`/`openTerminal`/
      handlers.ts semantics unchanged (only exported/wired).
- [ ] Kill-switch documented; default remains on per the 2026-11-08
      decision.

## Next plans

- Optional follow-ups (NOT in scope here): `session_shutdown` op; headless
  spawn via daemon RPC child (plan 26/113 machinery) as a `spawn_worktree`
  surface option; per-peer allowlist if the trust model ever changes
  (would supersede the ungated decision above — reopen explicitly).
