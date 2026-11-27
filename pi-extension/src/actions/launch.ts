/**
 * Plan/173 stage A2 — from an agent choice to the command a terminal runs.
 *
 * The app can start one of two agents in a folder. Both are a command line a
 * terminal (Windows Terminal tab, console window, detached tmux session) runs
 * in the project folder:
 *
 *   agent  fresh              continue           resume a stored session
 *   pi     `pi`               `pi --continue`    `pi --session <id>`
 *   agy    `remote-pi agy`    —                  —
 *
 * plus the optional start model: `--model <provider>/<id>` for Pi and
 * `--model <id>` for AGY (it has no provider half; the display provider the
 * app sends never reaches the command line).
 *
 * Why the `remote-pi agy` wrapper rather than `agy`: the wrapper installs the
 * mesh plugin and sets the environment, so the AGY session is a mesh peer
 * from its first turn.
 *
 * **The start model applies to that one session.** It is a command-line flag,
 * not a settings write: Pi's saved default model stays what it was, so a
 * choice made for one session does not move every other session.
 *
 * Pure: string building and checks only. Platform dispatch stays in
 * `./open_terminal.ts`, the AGY catalogue in `./agent_models.ts`.
 */

import type { AgentKind } from "../protocol/types.js";
import { SAFE_MODEL_TOKEN } from "../protocol/types.js";

/** What the started agent should do about existing conversations. */
export type AgentResume =
  | { kind: "new" }
  | { kind: "continue" }
  | { kind: "session"; id: string };

/** The command run for `agent: "agy"`. */
export const AGY_LAUNCH_COMMAND = "remote-pi agy";

export interface AgentCommandInput {
  agent: AgentKind;
  /** Pi only. AGY has no session resume on this path; it always starts
   *  fresh in the folder. */
  resume?: AgentResume;
  /** Both halves validated by the caller (`parseAgentSelection`); checked
   *  again here because this string reaches a shell. */
  model?: { provider: string; model_id: string } | null;
}

/** Escape a string for single-quoted interpolation in PowerShell and POSIX
 *  shells (`'` becomes `''`). Session ids are plain tokens, so this is a
 *  guard for a value nothing composes today. */
export function shellSingleQuote(s: string): string {
  return `'${String(s).replace(/'/g, "''")}'`;
}

function assertToken(kind: string, value: string): void {
  if (!SAFE_MODEL_TOKEN.test(value)) {
    throw new RangeError(`invalid model ${kind}: ${JSON.stringify(value)}`);
  }
}

/** ` --model <provider>/<id>`, or an empty string without a model. */
export function piModelFlag(model: AgentCommandInput["model"]): string {
  if (!model) return "";
  assertToken("provider", model.provider);
  assertToken("id", model.model_id);
  return ` --model ${model.provider}/${model.model_id}`;
}

/**
 * The command a terminal runs for this agent. Throws a RangeError on a model
 * token that must not reach a command line; callers turn that into an
 * `ok:false` reply.
 */
export function buildAgentCommand(input: AgentCommandInput): string {
  if (input.agent === "agy") {
    let modelFlag = "";
    if (input.model) {
      assertToken("id", input.model.model_id);
      modelFlag = ` --model ${input.model.model_id}`;
    }
    return `${AGY_LAUNCH_COMMAND}${modelFlag}`;
  }
  const resume = input.resume ?? { kind: "new" as const };
  let base = "pi";
  if (resume.kind === "continue") base = "pi --continue";
  if (resume.kind === "session") base = `pi --session ${shellSingleQuote(resume.id)}`;
  return `${base}${piModelFlag(input.model)}`;
}
