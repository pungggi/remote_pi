/**
 * Plan/124 — device-daemon handler for `start_session_request`.
 *
 * Brings an OFFLINE session back to life in its OWN cwd (no new worktree, no
 * pin). Plan/152 prefers an exact interactive resume: when the room registry
 * has the Pi session ID, open a NEW VISIBLE terminal window running
 * `pi --session-id <id>` (a background MRU tab is not sufficient). The id is
 * opened or created: a session that was only opened has no file yet, and a
 * deleted one has none either, so `pi --session <id>` would exit at once and
 * take the terminal with it (issue #142).
 *
 * Older rooms have no stored ID. They open the SAME kind of visible terminal
 * with `pi --continue`, preserving the cwd's most-recent conversation without
 * a hidden RPC process. Because the App↔Pi room is `roomIdFor(cwd, name)`,
 * either path re-announces the SAME room and the tile flips live.
 *
 * Plan/173 — the request may name another agent and a one-session model.
 * `agent: "agy"` starts `remote-pi agy` in the folder instead: AGY has no
 * stored session to resume here, so it always starts fresh, and its chat is
 * not shown in the app (by decision). The reply's `room_id` stays the folder's
 * room id: on a Termux host it names the tmux session the user attaches to.
 *
 * Both agents use the platform launcher from open_terminal: Windows Terminal
 * on Windows (plan/124/152), a detached tmux session named after the room on
 * a Termux host (plan/173). Other platforms currently report unsupported.
 *
 * Always replies (never hangs the action channel).
 */
import type { AgentResume, AgentCommandInput } from "./launch.js";
import { buildAgentCommand } from "./launch.js";
import type { ClientMessage } from "../protocol/types.js";
import type { ActionReplySender } from "./handlers.js";
import { remoteCwdAllowed } from "./cwd_policy.js";
import { roomIdFor } from "../rooms.js";
import { readRoomsRegistry } from "../session/rooms_registry.js";
import {
  AGY_TMUX_SIZE,
  openTerminalTab,
  readStartSelection,
  startModelProblem,
} from "./open_terminal.js";

type StartSessionRequestMsg = Extract<
  ClientMessage,
  { type: "start_session_request" }
>;

export async function handleStartSession(
  sender: ActionReplySender,
  msg: StartSessionRequestMsg,
): Promise<void> {
  // Plan/173 — a bad agent or model token is refused before the folder is
  // even looked at.
  const picked = readStartSelection(msg);
  if (!picked.ok) {
    sender.send({ type: "start_session_result", in_reply_to: msg.id, ok: false, message: picked.message });
    return;
  }
  const { selection } = picked;

  const cwd = msg.cwd?.trim();
  if (!cwd) {
    sender.send({
      type: "start_session_result",
      in_reply_to: msg.id,
      ok: false,
      message: "cwd is required",
    });
    return;
  }
  const name = msg.name?.trim() || undefined;
  // Security fix 2026-08 (M3) — the supervisor spawns `pi --mode rpc` at this
  // cwd; pi auto-loads .pi/ extensions from it. Restrict to project roots /
  // registered worktrees so a forged request can't spawn in attacker-chosen
  // directories.
  if (!remoteCwdAllowed(cwd)) {
    sender.send({
      type: "start_session_result",
      in_reply_to: msg.id,
      ok: false,
      message:
        `Remote session start is restricted to project roots — add '${cwd}' ` +
        "to projects.roots in ~/.pi/piper/config.json to allow it.",
    });
    return;
  }
  // Plan/173 — refuse a model the agent does not offer (AGY only; see
  // `startModelProblem`) before a terminal opens that would die on it.
  const problem = await startModelProblem(selection);
  if (problem) {
    sender.send({ type: "start_session_result", in_reply_to: msg.id, ok: false, message: problem });
    return;
  }

  const roomId = roomIdFor(cwd, name);
  const sessionId = readRoomsRegistry().get(roomId)?.sessionId?.trim();
  let command: string;
  let successMessage: string;
  if (selection.agent === "agy") {
    command = buildAgentCommand({ agent: "agy", model: selection.model });
    successMessage =
      "Opened terminal — AGY is running in this folder. Its chat is not shown in the app; use the terminal.";
  } else {
    const resume: AgentResume = sessionId ? { kind: "session-id", id: sessionId } : { kind: "continue" };
    const input: AgentCommandInput = { agent: "pi", resume, model: selection.model };
    command = buildAgentCommand(input);
    successMessage = sessionId
      ? "Opened terminal — resuming the Pi session of this room."
      : "Opened terminal — continuing the latest Pi session in this folder.";
  }
  void openTerminalTab(
    cwd,
    command,
    // Plan/173 — AGY draws into the detached tmux session before the first
    // attach, so it gets a canvas up front.
    selection.agent === "agy"
      ? { newWindow: true, sessionName: roomId, size: { ...AGY_TMUX_SIZE } }
      : { newWindow: true, sessionName: roomId },
  ).then(
    (outcome) => {
      sender.send({
        type: "start_session_result",
        in_reply_to: msg.id,
        ok: outcome.ok,
        room_id: roomId,
        message: outcome.ok ? successMessage : outcome.message,
      });
    },
    (e: unknown) => {
      sender.send({
        type: "start_session_result",
        in_reply_to: msg.id,
        ok: false,
        room_id: roomId,
        message: e instanceof Error ? e.message : String(e),
      });
    },
  );
}
