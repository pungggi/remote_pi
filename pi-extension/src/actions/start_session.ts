/**
 * Plan/124 — device-daemon handler for `start_session_request`.
 *
 * Brings an OFFLINE session back to life in its OWN cwd (no new worktree, no
 * pin). Plan/152 prefers an exact interactive resume: when the room registry
 * has the Pi session ID, open a NEW VISIBLE terminal window running
 * `pi --session <id>` (a background MRU tab is not sufficient).
 *
 * Older rooms have no stored ID. They open the SAME kind of visible terminal
 * with `pi --continue`, preserving the cwd's most-recent conversation without
 * a hidden RPC process. Because the App↔Pi room is `roomIdFor(cwd, name)`,
 * either path re-announces the SAME room and the tile flips live.
 *
 * Both paths use the Windows launcher from open_terminal and currently report
 * unsupported on other platforms.
 *
 * Always replies (never hangs the action channel).
 */
import type { ClientMessage } from "../protocol/types.js";
import type { ActionReplySender } from "./handlers.js";
import { remoteCwdAllowed } from "./cwd_policy.js";
import { roomIdFor } from "../rooms.js";
import { readRoomsRegistry } from "../session/rooms_registry.js";
import { openTerminalTab, piSessionResumeCommand } from "./open_terminal.js";

type StartSessionRequestMsg = Extract<
  ClientMessage,
  { type: "start_session_request" }
>;

export function handleStartSession(
  sender: ActionReplySender,
  msg: StartSessionRequestMsg,
): void {
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
  const roomId = roomIdFor(cwd, name);
  const sessionId = readRoomsRegistry().get(roomId)?.sessionId?.trim();
  const command = sessionId ? piSessionResumeCommand(sessionId) : "pi --continue";
  const successMessage = sessionId
    ? "Opened terminal — resuming the saved Pi session."
    : "Opened terminal — continuing the latest Pi session in this folder.";
  void openTerminalTab(cwd, command, { newWindow: true }).then(
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
