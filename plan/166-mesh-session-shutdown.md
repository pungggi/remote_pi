# Plan 166 — Mesh `session_shutdown`

## Context

Plan/161 shipped five session-control verbs on the agent mesh (compact, reset,
model_set, list_models, spawn_worktree). An orchestrating agent can create and
steer sessions, but cannot cleanly END one: the verb set closes the lifecycle
at "spawn" and leaves "stop" missing. `session_shutdown` was deliberately
excluded from the mesh scope back then (types.ts: "everything except
`session_shutdown` … stay app-only by scope decision"); this plan supersedes
that scope decision for shutdown only — the ungated trust model and the
`allow_remote_session_control:false` kill-switch are unchanged.

Almost all machinery already exists:

- `handleSessionShutdown` (actions/handlers.ts, plan/28) — calls `ctx.shutdown()`
  (SDK: graceful, deferred until `agent_settled`), refuses when `ctx.isIdle()`
  returns false ("Session is busy"), returns true only after Pi accepted.
- `_dispatchSessionAction` (main.ts) already routes a `session_shutdown` case
  (app path). `SessionShutdownMsg` exists on the wire (`{type:"session_shutdown", id}`).
- The `$rp_control` envelope path (`_handleControlEnvelopeInner`) gates on the
  kill-switch, refuses self-addressed envelopes, and maps ops via
  `_synthesizeSessionAction` → `SessionActionMessage` union (types.ts).

The gap is purely surface wiring + one semantic decision.

### Semantic decision: defer-when-busy

The plan/28 busy-refusal exists for the APP's Quit guarantee ("never
acknowledge a Quit that would need the daemon fallback"). The mesh use case is
different in two places:

- **Local self-shutdown runs mid-turn** — the tool call itself makes
  `isIdle()` false, so a strict check makes self-shutdown ALWAYS fail.
- **Remote targets are often mid-turn** when the orchestrator decides to stop
  them; strict refusal would make the verb useless at exactly the moment it
  matters.

`ctx.shutdown()` already defers until the turn settles (reply flushes first —
`runSync` answers before shutdown takes effect; the LIVE-RUN reply hardening
from PR #107 already swallows a torn-down peer). So: the mesh path passes
`defer_if_busy: true` and the handler honors it — busy target → accepted,
shutdown lands when the current turn finishes. The app Quit path keeps the
strict default (flag unset).

## Expected structure

```
pi-extension/src/protocol/types.ts        RpControlOp + "session_shutdown";
                                          SessionActionMessage + shutdown extract;
                                          ClientMessage session_shutdown gains
                                          optional defer_if_busy?: boolean
pi-extension/src/actions/handlers.ts      handleSessionShutdown: skip the busy
                                          throw when msg.defer_if_busy; doc note
pi-extension/src/main.ts                  _synthesizeSessionAction: case
                                          "session_shutdown" → msg with
                                          defer_if_busy:true; op switch in
                                          _handleControlEnvelopeInner
pi-extension/src/session/control_tools.ts new tool session_shutdown {target?};
                                          local → dispatchLocal, remote → op;
                                          formatControlResult text
pi-extension/src/mcp/mesh_server.ts       MCP tool session_shutdown (remote-only)
pi-extension/src/actions/handlers.test.ts defer/busy/idle matrix
pi-extension/src/session_control.test.ts  envelope: ok, busy-defer, kill-switch,
                                          no-pi, self-address, unknown-op
pi-extension/src/session/control_tools.test.ts  tool dispatch local+remote
PROTOCOL.md / skills/agent-network/SKILL.md / CHANGELOG.md
```

## Steps

1. **Wire type**: `RpControlOp` + `"session_shutdown"`;
   `SessionActionMessage` includes `Extract<ClientMessage, {type:"session_shutdown"}>`;
   the ClientMessage variant gains `defer_if_busy?: boolean` (optional — app
   path unchanged). Update the "everything except session_shutdown" comment.
   - AC: tsc exhaustive-switch errors point at the two switches to extend.

2. **Handler semantics**: in `handleSessionShutdown`, honor `msg.defer_if_busy`
   — when busy AND flag set, proceed to `ctx.shutdown()` (deferred) instead of
   throwing. Keep the strict throw when the flag is unset (app Quit).
   - AC: unit matrix — idle+no-flag ok; busy+no-flag throws; busy+flag ok
     (calls ctx.shutdown); no ctx → typed error.

3. **Envelope path**: `_synthesizeSessionAction` case → `{type:"session_shutdown",
   id, defer_if_busy:true}`; add the op to the shared case in
   `_handleControlEnvelopeInner` (sink already maps action_ok/action_error).
   - AC: envelope tests — ok reply `{ok:true, action:"session_shutdown"}`;
     busy target replies ok (deferred); kill-switch replies disabled error;
     self-addressed refused; `!ext.pi` replied explicitly.

4. **Pi tool** `session_shutdown {target?}` in control_tools.ts:
   no target → `dispatchLocal({type:"session_shutdown", defer_if_busy:true})`;
   with target → `_remoteControl(op:"session_shutdown")`. Description states:
   graceful, defers until the target's current turn settles, terminal closes,
   uncommitted work stays in the worktree.
   - AC: control_tools tests cover both dispatches + refusal of malformed
     target (same patterns as session_reset).

5. **MCP tool** in mesh_server.ts (remote-only, same pattern as the other
   verbs; behind `awaitMeshReady`).
   - AC: mesh_server test asserts registration + remote-only behavior.

6. **Docs**: PROTOCOL.md RpControlOp addendum (shutdown + defer semantics +
   reply-before-death note); SKILL.md session-control section lists the sixth
   verb with the busy/defer caveat; CHANGELOG `[Unreleased]`.
   - AC: docs mention the kill-switch and that the app Quit path is unchanged.

## DoD

- [ ] An agent can shut itself down (`session_shutdown` no target) — tool
      replies ok, the turn completes, pi exits gracefully.
- [ ] An agent can shut a remote peer down — target replies ok; busy targets
      accept deferred; the reply always arrives before process death.
- [ ] App Quit semantics unchanged (strict refusal when busy, no flag).
- [ ] Kill-switch `allow_remote_session_control:false` refuses shutdown too.
- [ ] `pnpm test` + typecheck green; e2e manual (self, same-PC remote) noted
      in the PR.

## Next plans

- Headless spawn via daemon RPC child (plan/26+113) as a `spawn_worktree`
  surface option — pairs with shutdown for full worker lifecycle.
- Per-peer allowlist only if the trust model ever changes (would supersede
  the 2026-11-08 ungated decision — reopen explicitly).
