/**
 * Plan/173 — the agent selection carried by start requests, validated.
 *
 * `open_terminal_request` and `start_session_request` gain three optional
 * fields: `agent` and the `provider` / `model_id` pair. They arrive as plain
 * JSON from the relay, so their TypeScript types say nothing about what is
 * actually there. This module turns them into one checked value, or into a
 * message the app can show.
 *
 * Three rules, each with a reason:
 *
 *   - **An unknown agent is an error, never a fallback to Pi.** The user
 *     asked for AGY; starting Pi instead would look like success.
 *   - **A model needs both halves.** A lone `provider` or `model_id` cannot
 *     compose a `--model` flag; refusing it is clearer than picking a default.
 *   - **Tokens must pass `SAFE_MODEL_TOKEN`.** Both halves end up on a command
 *     line (`pi --model <provider>/<id>`, `agy --model <id>`), so the charset
 *     guard that plan/161 introduced for mesh envelopes applies here too.
 *
 * For AGY only `model_id` is used: it is AGY's own model id, and the
 * `provider` the app sends is a display grouping derived from it (see
 * `actions/agent_models.ts`). It is still validated, so one rule covers both
 * agents.
 *
 * Pure: no I/O, no clock. Whether the id is in the agent's catalogue is a
 * separate, device-side check (`actions/launch.ts`).
 */
import type { AgentKind } from "./types.js";
import { SAFE_MODEL_TOKEN } from "./types.js";

/** The fields every start request carries for plan/173. */
export interface AgentSelectionFields {
  agent?: unknown;
  provider?: unknown;
  model_id?: unknown;
}

/** A checked selection. `model` is null when the request chose none, which
 *  starts the session exactly as before plan/173. */
export interface AgentSelection {
  agent: AgentKind;
  model: { provider: string; model_id: string } | null;
}

export type AgentSelectionResult =
  | { ok: true; selection: AgentSelection }
  | { ok: false; message: string };

export const AGENT_KINDS: readonly AgentKind[] = ["pi", "agy"];

/** Narrow an arbitrary value to `AgentKind`, or say why it is not one. */
export function parseAgentKind(raw: unknown): { ok: true; agent: AgentKind } | { ok: false; message: string } {
  // Absent and null mean "the default". An empty string is NOT a default: it
  // is a value some client produced by mistake, and silently reading it as Pi
  // would hide that.
  if (raw === undefined || raw === null) return { ok: true, agent: "pi" };
  if (typeof raw !== "string" || !(AGENT_KINDS as readonly string[]).includes(raw)) {
    return {
      ok: false,
      message: `unknown agent ${JSON.stringify(raw ?? null)} (expected "pi" or "agy")`,
    };
  }
  return { ok: true, agent: raw as AgentKind };
}

/** Validate the `agent` / `provider` / `model_id` triple of a start request. */
export function parseAgentSelection(fields: AgentSelectionFields): AgentSelectionResult {
  const agent = parseAgentKind(fields.agent);
  if (!agent.ok) return agent;

  const hasProvider = fields.provider !== undefined && fields.provider !== null;
  const hasModelId = fields.model_id !== undefined && fields.model_id !== null;
  if (!hasProvider && !hasModelId) {
    return { ok: true, selection: { agent: agent.agent, model: null } };
  }
  if (!hasProvider || !hasModelId) {
    return {
      ok: false,
      message: "a start model needs both provider and model_id (or neither)",
    };
  }
  if (typeof fields.provider !== "string" || !SAFE_MODEL_TOKEN.test(fields.provider)) {
    return { ok: false, message: `invalid model provider: ${JSON.stringify(fields.provider)}` };
  }
  if (typeof fields.model_id !== "string" || !SAFE_MODEL_TOKEN.test(fields.model_id)) {
    return { ok: false, message: `invalid model id: ${JSON.stringify(fields.model_id)}` };
  }
  return {
    ok: true,
    selection: { agent: agent.agent, model: { provider: fields.provider, model_id: fields.model_id } },
  };
}
