/**
 * Plan/161 — agent session-control tools.
 *
 * Gives mesh agents (Pi) five capabilities that mirror the plan/28 app
 * action vocabulary, each with an optional `target`:
 *
 *   - `session_compact {target?}`   → plan/28 `session_compact` (ctx.compact)
 *   - `session_reset   {target?}`   → plan/28 `session_new` (fresh context,
 *                                     SAME process — "reset" per the
 *                                     2026-11-08 decision)
 *   - `model_set {provider, model_id, target?}` → plan/28 `model_set`
 *   - `list_models {target?}`       → plan/28 `list_models`
 *   - `spawn_worktree {branch?, base?, provider?, model_id?, target?}`
 *                                  → plan/108 `createWorktree` + `pi` in a
 *                                    visible terminal (auto-joins the mesh)
 *
 * `target` omitted → LOCAL execution against the calling agent's own
 * session, through the exact `_dispatchSessionAction` the mobile app path
 * drives (no envelope, no round-trip). `target` = a `list_peers` address →
 * a `$rp_control` envelope sent via `peer.request()`; the target's
 * extension intercepts it BEFORE conversational delivery, executes the
 * same handlers, and replies `re`-correlated (see main.ts
 * `_handleControlEnvelope`). Addresses are opaque routing keys — echoed
 * verbatim, never composed.
 *
 * Tool schemas are hand-written JSON Schema literals (plan/143): no
 * typebox in the thin entry's static graph.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type {
  RpControlOp,
  RpControlRequest,
  RpControlResult,
  ServerMessage,
  SessionActionMessage,
} from "../protocol/types.js";

const jsonSchema = (s: object) => s as unknown as never;

const NOT_IN_SESSION = "Not in a session. Run /remote-pi join first";
const REMOTE_TIMEOUT_MS = 30_000;

/** Structural peer surface the remote path needs (matches SessionPeer). */
interface ControlPeer {
  address(): string;
  name(): string;
  request(to: string, body: unknown, timeoutMs: number): Promise<{ body: unknown }>;
}

export interface SpawnWorktreeOpts {
  base?: string | null;
  branch?: string | null;
  provider?: string | null;
  model_id?: string | null;
}

export interface SpawnWorktreeResult {
  ok: boolean;
  message: string;
  path?: string;
  branch?: string;
}

/** Dependencies injected by index.ts so this module stays light and
 *  unit-testable: `dispatchLocal`/`spawnWorktreeLocal` trampoline into the
 *  lazy runtime (main.ts); `getPeer` sees the live mesh node. */
export interface SessionControlDeps {
  getPeer: () => ControlPeer | null;
  dispatchLocal(msg: SessionActionMessage): Promise<ServerMessage>;
  spawnWorktreeLocal(opts: SpawnWorktreeOpts): Promise<SpawnWorktreeResult>;
}

const TARGET_DESC =
  "Optional peer address from list_peers (`<cwd>@<name>`, `<pc>:` prefix cross-PC) " +
  "echoed VERBATIM to control ANOTHER agent's session. Omit to act on your OWN session.";

interface LocalOutcome {
  text: string;
  ok: boolean;
}

/** Format the single plan/28 ServerMessage reply into tool text. */
function _formatLocalReply(sm: ServerMessage): LocalOutcome {
  if (sm.type === "action_ok") {
    return { text: `OK: "${sm.action}" dispatched. Effects arrive through the normal channels.`, ok: true };
  }
  if (sm.type === "action_error") {
    return { text: `FAILED: "${sm.action}": ${sm.error}`, ok: false };
  }
  if (sm.type === "models_list") {
    const lines = sm.models.map((m) => {
      const cur = sm.current && sm.current.provider === m.provider && sm.current.id === m.id ? "  ← current" : "";
      return `- ${m.provider}/${m.id} — ${m.name}${cur}`;
    });
    return {
      text: lines.length > 0 ? lines.join("\n") : "(no models available)",
      ok: true,
    };
  }
  if (sm.type === "error") {
    return { text: `FAILED: ${sm.message}`, ok: false };
  }
  return { text: JSON.stringify(sm), ok: false };
}

/** Send a `$rp_control` envelope via peer.request and format the
 *  `rp_control_result` reply. Never throws — transport errors surface as
 *  a failed outcome string. */
async function _remoteControl(
  peer: ControlPeer,
  target: string,
  ctrl: RpControlRequest["$rp_control"],
): Promise<LocalOutcome & { details?: RpControlResult["rp_control_result"] }> {
  let replyEnv: { body: unknown };
  try {
    replyEnv = await peer.request(target, { $rp_control: ctrl }, REMOTE_TIMEOUT_MS);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { text: `Remote control failed: ${msg}`, ok: false };
  }
  const res = (replyEnv.body as RpControlResult | null)?.rp_control_result;
  if (!res) {
    return { text: "Remote peer replied without a control result — likely an out-of-date remote-pi build.", ok: false };
  }
  if (!res.ok) {
    return { text: `FAILED on "${target}": ${res.error ?? "unknown error"}`, ok: false, details: res };
  }
  if (res.action === "list_models") {
    const lines = (res.models ?? []).map((m) => {
      const cur = res.current && res.current.provider === m.provider && res.current.id === m.id ? "  ← current" : "";
      return `- ${m.provider}/${m.id} — ${m.name}${cur}`;
    });
    return { text: lines.length > 0 ? lines.join("\n") : "(no models available)", ok: true, details: res };
  }
  if (res.action === "spawn_worktree") {
    const where = res.path ? `\npath: ${res.path}` : "";
    const branch = res.branch ? `\nbranch: ${res.branch}` : "";
    return {
      text: `${res.message ?? "spawned"}${where}${branch}\nThe new session auto-joins the mesh — watch list_peers, then agent_send it a task.`,
      ok: true,
      details: res,
    };
  }
  return { text: `OK on "${target}": "${res.action}" dispatched.`, ok: true, details: res };
}

/** Resolve the target: self-address is refused (omit target instead),
 *  remote requires the mesh. Returns null for local execution. */
function _resolveTarget(
  peer: ControlPeer | null,
  target: string | undefined,
): { error: string } | { target: string } | null {
  if (target === undefined || target === null || target === "") return null; // local
  if (!peer) return { error: NOT_IN_SESSION };
  if (target === peer.address() || target === peer.name()) {
    return {
      error: `Refused: "${target}" is your own address — omit \`target\` to act on your own session.`,
    };
  }
  return { target };
}

export function registerSessionControlTools(pi: ExtensionAPI, deps: SessionControlDeps): void {
  const TargetParam = {
    type: "string",
    description: TARGET_DESC,
  } as const;

  // ── session_compact ────────────────────────────────────────────────────────
  pi.registerTool<never, { ok: boolean }>({
    name: "session_compact",
    label: "Session Compact",
    description:
      "Compact (summarize + truncate) a session's context — your own when `target` is " +
      "omitted, or another agent's by address. Useful when a session's context is nearly " +
      "full or before handing it a large new task. The peer's extension executes the same " +
      "code path the mobile app uses; effects stream back through normal channels.",
    promptSnippet:
      "session_compact({target?}): compact context of self (no target) or a peer (address verbatim).",
    parameters: jsonSchema({
      type: "object",
      properties: { target: TargetParam },
    }),
    execute: async (_id, params) => {
      const { target } = params as { target?: string };
      const peer = deps.getPeer();
      const t = _resolveTarget(peer, target);
      if (t && "error" in t) return { content: [{ type: "text", text: t.error }], details: { ok: false } };
      const out = t && "target" in t
        ? await _remoteControl(peer!, t.target, { op: "session_compact" })
        : _formatLocalReply(await deps.dispatchLocal({ type: "session_compact", id: `ctl-${Date.now()}` }));
      return { content: [{ type: "text", text: out.text }], details: { ok: out.ok } };
    },
  });

  // ── session_reset ──────────────────────────────────────────────────────────
  pi.registerTool<never, { ok: boolean }>({
    name: "session_reset",
    label: "Session Reset",
    description:
      "Reset a session to a FRESH context in the SAME process (the mobile app's 'New " +
      "session' action): wipes the conversation, keeps the terminal/process. `target` " +
      "omitted = your own session; an address = another agent's. Prefer this over " +
      "spawn_worktree when the agent should continue in place with a clean slate. " +
      "Resetting YOUR OWN session mid-turn discards the conversation you are in — use " +
      "it deliberately (e.g. at a milestone boundary, or on an idle worker).",
    promptSnippet:
      "session_reset({target?}): fresh context, same process, self or peer. Destructive to the conversation — deliberate use only.",
    parameters: jsonSchema({
      type: "object",
      properties: { target: TargetParam },
    }),
    execute: async (_id, params) => {
      const { target } = params as { target?: string };
      const peer = deps.getPeer();
      const t = _resolveTarget(peer, target);
      if (t && "error" in t) return { content: [{ type: "text", text: t.error }], details: { ok: false } };
      const out = t && "target" in t
        ? await _remoteControl(peer!, t.target, { op: "session_new" })
        : _formatLocalReply(await deps.dispatchLocal({ type: "session_new", id: `ctl-${Date.now()}` }));
      return { content: [{ type: "text", text: out.text }], details: { ok: out.ok } };
    },
  });

  // ── model_set ──────────────────────────────────────────────────────────────
  pi.registerTool<never, { ok: boolean }>({
    name: "model_set",
    label: "Model Set",
    description:
      "Switch the model of a session — your own when `target` is omitted, or another " +
      "agent's by address. Use list_models first to see what is available (each peer " +
      "has its OWN registry — a remote peer may offer different models than you). " +
      "Sets the LIVE model and persists it as the peer's default.",
    promptSnippet:
      "model_set({provider, model_id, target?}): switch model of self or a peer. list_models first.",
    parameters: jsonSchema({
      type: "object",
      properties: {
        provider: { type: "string", description: "Model provider, e.g. 'anthropic'." },
        model_id: { type: "string", description: "Model id from list_models, e.g. 'claude-opus-4-7'." },
        target: TargetParam,
      },
      required: ["provider", "model_id"],
    }),
    execute: async (_id, params) => {
      const { provider, model_id, target } = params as {
        provider: string;
        model_id: string;
        target?: string;
      };
      const peer = deps.getPeer();
      const t = _resolveTarget(peer, target);
      if (t && "error" in t) return { content: [{ type: "text", text: t.error }], details: { ok: false } };
      const ctrl: RpControlRequest["$rp_control"] = { op: "model_set", provider, model_id };
      const out = t && "target" in t
        ? await _remoteControl(peer!, t.target, ctrl)
        : _formatLocalReply(await deps.dispatchLocal({ type: "model_set", id: `ctl-${Date.now()}`, provider, model_id }));
      return { content: [{ type: "text", text: out.text }], details: { ok: out.ok } };
    },
  });

  // ── list_models ────────────────────────────────────────────────────────────
  pi.registerTool<never, { ok: boolean }>({
    name: "list_models",
    label: "List Models",
    description:
      "List the models available to a session — your own registry when `target` is " +
      "omitted, or a REMOTE peer's registry by address (peers on other machines may " +
      "have different providers/auth configured). Shows the current model. Use before " +
      "model_set or before spawning a worktree session with a specific model.",
    promptSnippet: "list_models({target?}): models + current of self or a peer. Cheap; call freely.",
    parameters: jsonSchema({
      type: "object",
      properties: { target: TargetParam },
    }),
    execute: async (_id, params) => {
      const { target } = params as { target?: string };
      const peer = deps.getPeer();
      const t = _resolveTarget(peer, target);
      if (t && "error" in t) return { content: [{ type: "text", text: t.error }], details: { ok: false } };
      const out = t && "target" in t
        ? await _remoteControl(peer!, t.target, { op: "list_models" })
        : _formatLocalReply(await deps.dispatchLocal({ type: "list_models", id: `ctl-${Date.now()}` }));
      return { content: [{ type: "text", text: out.text }], details: { ok: out.ok } };
    },
  });

  // ── spawn_worktree ─────────────────────────────────────────────────────────
  pi.registerTool<never, { ok: boolean; path?: string; branch?: string }>({
    name: "spawn_worktree",
    label: "Spawn Worktree Session",
    description:
      "Create a git worktree off a base repo and start a FRESH Pi session there in a " +
      "visible terminal (running `pi`, optionally with `--model provider/model_id`). " +
      "The new session auto-joins the mesh as its own peer — poll list_peers, then " +
      "agent_send it a task. Reuses existing worktrees when the branch/folder already " +
      "exists (re-tap semantics). `target` runs the spawn on ANOTHER machine; omit for " +
      "your own. Default base = the session cwd; branch defaults to `work/<timestamp>`.",
    promptSnippet:
      "spawn_worktree({branch?, base?, provider?, model_id?, target?}): worktree + fresh pi session (auto-joins mesh). Watch list_peers, then agent_send the task.",
    parameters: jsonSchema({
      type: "object",
      properties: {
        branch: {
          type: "string",
          description: "Branch to create in the worktree (validated by git). Default `work/<timestamp>`.",
        },
        base: {
          type: "string",
          description: "Base repo path. Default: the (target) session's cwd.",
        },
        provider: { type: "string", description: "Optional model provider for the spawned session's `pi --model`." },
        model_id: { type: "string", description: "Optional model id — requires provider." },
        target: TargetParam,
      },
    }),
    execute: async (_id, params) => {
      const { branch, base, provider, model_id, target } = params as {
        branch?: string;
        base?: string;
        provider?: string;
        model_id?: string;
        target?: string;
      };
      const peer = deps.getPeer();
      const t = _resolveTarget(peer, target);
      if (t && "error" in t) return { content: [{ type: "text", text: t.error }], details: { ok: false } };
      if ((provider && !model_id) || (!provider && model_id)) {
        const msg = "spawn_worktree requires both provider and model_id (or neither).";
        return { content: [{ type: "text", text: msg }], details: { ok: false } };
      }
      if (t && "target" in t) {
        const out = await _remoteControl(peer!, t.target, {
          op: "spawn_worktree",
          ...(branch ? { branch } : {}),
          ...(base ? { base } : {}),
          ...(provider && model_id ? { provider, model_id } : {}),
        });
        return { content: [{ type: "text", text: out.text }], details: { ok: out.ok } };
      }
      const r = await deps.spawnWorktreeLocal({ base: base ?? null, branch: branch ?? null, provider: provider ?? null, model_id: model_id ?? null });
      const text = r.ok
        ? `${r.message}\npath: ${r.path ?? "?"}\nbranch: ${r.branch ?? "?"}\nThe new session auto-joins the mesh — watch list_peers, then agent_send it a task.`
        : r.message;
      return {
        content: [{ type: "text", text }],
        details: { ok: r.ok, ...(r.ok && r.path ? { path: r.path } : {}), ...(r.ok && r.branch ? { branch: r.branch } : {}) },
      };
    },
  });
}

// Re-exports for index.ts wiring (single import site for the control surface).
export type { RpControlOp };
