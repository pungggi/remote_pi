/**
 * Plan/124 — device-daemon handler for `start_session_request`.
 *
 * Brings an OFFLINE session back to life in its OWN cwd (no new worktree, no
 * pin). Plan/152 prefers an exact interactive resume: when the room registry
 * has the Pi session ID, open a terminal running `pi --session <id>`.
 *
 * Older rooms have no stored ID. They retain the plan/124 fallback: ask the
 * supervisor to spawn a TRANSIENT `pi --mode rpc --continue`, which resumes
 * the cwd's most-recent session JSONL. Because the App↔Pi room is
 * `roomIdFor(cwd, name)`, either path re-announces the SAME room and the
 * offline tile flips live via the rooms push.
 *
 * The fallback requires the supervisor. Exact terminal resume uses the same
 * Windows launcher as open_terminal and currently reports unsupported on
 * other platforms.
 *
 * Always replies (never hangs the action channel).
 */
import type { ClientMessage } from "../protocol/types.js";
import type { ActionReplySender } from "./handlers.js";
import { remoteCwdAllowed } from "./cwd_policy.js";
import { callSupervisor, SupervisorOfflineError } from "../daemon/client.js";
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
  if (sessionId) {
    void openTerminalTab(cwd, piSessionResumeCommand(sessionId)).then(
      (outcome) => {
        sender.send({
          type: "start_session_result",
          in_reply_to: msg.id,
          ok: outcome.ok,
          room_id: roomId,
          message: outcome.ok
            ? "Opened terminal — resuming the saved Pi session."
            : outcome.message,
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
    return;
  }

  void callSupervisor({
    op: "start_transient",
    cwd,
    ...(name ? { name } : {}),
  })
    .then((r) => {
      sender.send({
        type: "start_session_result",
        in_reply_to: msg.id,
        ok: true,
        room_id: r.room_id,
      });
    })
    .catch((e: unknown) => {
      const message =
        e instanceof SupervisorOfflineError
          ? "Supervisor not running — run `/remote-pi install` or start pi-supervisord."
          : e instanceof Error
            ? e.message
            : String(e);
      sender.send({
        type: "start_session_result",
        in_reply_to: msg.id,
        ok: false,
        message,
      });
    });
}
