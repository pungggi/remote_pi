/**
 * Plan/124 — device-daemon handler for `start_session_request`.
 *
 * Brings an OFFLINE session back to life in its OWN cwd (no new worktree, no
 * pin): asks the supervisor to spawn a TRANSIENT `pi --mode rpc` at the
 * session's `cwd`. The child launches with `--continue` (see `rpc_child.ts`
 * `rpcSpawnArgs`), so it resumes the cwd's most-recent session JSONL — the
 * existing conversation carries over unchanged. Because the App↔Pi room is
 * `roomIdFor(cwd, name)` (and collapses to the legacy cwd-only room for a
 * default/unnamed agent), the spawned pi re-announces the SAME room the
 * offline tile is bound to, so the tile flips live on its own via the rooms
 * push (the app does nothing but wait).
 *
 * Requires the supervisor to be running — it owns the spawn machinery and the
 * transient-slot lifecycle. When only the Cockpit's own device agent is up
 * (no supervisor) this replies `ok:false` with an install hint; see
 * plan/124 non-goals (Cockpit-direct spawn is a later plan).
 *
 * Always replies (never hangs the action channel).
 */
import type { ClientMessage } from "../protocol/types.js";
import type { ActionReplySender } from "./handlers.js";
import { remoteCwdAllowed } from "./cwd_policy.js";
import { callSupervisor, SupervisorOfflineError } from "../daemon/client.js";

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
