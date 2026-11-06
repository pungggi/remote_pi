/**
 * Plan/158 — make the PC FORGET a past session (the missing half of session
 * cleanup).
 *
 * Until now every cleanup path was partial: plan/17 deletes the phone-side
 * record only, plan/148 removes the worktree + branch but leaves the
 * `~/.pi/piper/rooms.json` entry alive. The room-keeper (plan/140) re-opens
 * every registry entry on its sweep, and each keeper connect fires
 * `room_announced` — which re-persists the room on the phone. Result: the
 * tile always resurrects as an archive entry.
 *
 * `forget_room_request` prunes that registry entry (the keeper releases the
 * room as "stale" on its next sweep — no RPC into the supervisor needed) and
 * optionally deletes the session's chat-history transcripts under
 * `~/.pi/agent/sessions/<encoded cwd>/`.
 *
 * Deliberately stateless about liveness: the app-side guard (plan/148, reused
 * by the consolidated flow) refuses to fire while any same-peer session is
 * live at the folder. The handler itself is idempotent — a room that is
 * already forgotten answers ok:true with `registry_removed: false`, so a
 * retried batch never fails on half-done work.
 *
 * History deletion is precise where it can be:
 *  - Registry entry knows its Pi `sessionId` (plan/152+): delete only
 *    `*_<sessionId>.jsonl` — no risk to other sessions sharing the encoded
 *    folder name (cwds that differ only in `/ \ :` placement collide).
 *  - Pre-plan/152 entry (no sessionId): delete the folder's top-level
 *    `*.jsonl` transcripts (never the whole folder — `broker.sock`-style
 *    infra lives elsewhere, but staying file-level keeps a collision from
 *    nuking another project's folder shape).
 *
 * Served by the always-on device daemon like the other offline-session
 * actions, so cleanup works while the room itself is dark.
 */
import { existsSync, readdirSync, rmSync, statSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import type { ClientMessage } from "../protocol/types.js";
import type { ActionReplySender } from "./handlers.js";
import { forgetRoom, readRoomsRegistry } from "../session/rooms_registry.js";
import { encodeCwd, sessionsRoot } from "../session/file_index.js";

type ForgetRoomRequestMsg = Extract<ClientMessage, { type: "forget_room_request" }>;

/** Deletes the room's transcript files. Returns what happened, for the reply. */
export function deleteRoomHistory(
  cwd: string,
  sessionId: string | undefined,
): { removed: boolean; note: string } {
  const dir = join(sessionsRoot(), encodeCwd(cwd));
  if (!existsSync(dir)) {
    return { removed: false, note: "kept: no chat history folder on the computer" };
  }
  // Exact match when the registry knows the Pi session id (plan/152+).
  if (sessionId && sessionId.trim()) {
    const id = sessionId.trim();
    const targets = readdirSync(dir).filter(
      (f) => f.endsWith(`_${id}.jsonl`) || f === `${id}.jsonl`,
    );
    if (targets.length === 0) {
      return { removed: false, note: "kept: transcript for this session not found" };
    }
    let removed = 0;
    for (const f of targets) {
      try {
        unlinkSync(join(dir, f));
        removed++;
      } catch {
        /* best-effort: a locked file must not fail the whole forget */
      }
    }
    return removed > 0
      ? { removed: true, note: `deleted ${removed} transcript file(s)` }
      : { removed: false, note: "kept: transcript files locked (in use?)" };
  }
  // Pre-plan/152 entry: no exact id — delete the folder's top-level
  // transcripts (file-level only; see module docs for the collision note).
  let removed = 0;
  for (const f of readdirSync(dir)) {
    if (!f.endsWith(".jsonl")) continue;
    const p = join(dir, f);
    try {
      if (!statSync(p).isFile()) continue;
      unlinkSync(p);
      removed++;
    } catch {
      /* best-effort */
    }
  }
  // Sweep up the now-empty folder (best-effort; harmless when it stays).
  try {
    if (readdirSync(dir).length === 0) rmSync(dir, { recursive: true });
  } catch {
    /* ignore */
  }
  return removed > 0
    ? { removed: true, note: `deleted ${removed} transcript file(s)` }
    : { removed: false, note: "kept: no transcript files found" };
}

/**
 * Plan/158 — replies with `forget_room_result`. Deletes the room's
 * transcripts (when asked) and prunes the rooms.json entry. ok:false only
 * when the registry write itself throws — everything else is reported via
 * fields + note. History runs first so every crash window is recoverable.
 */
export function handleForgetRoom(sender: ActionReplySender, msg: ForgetRoomRequestMsg): void {
  // Read BEFORE pruning: the entry carries the cwd (transcript folder) and
  // the Pi sessionId (exact file match).
  const entry = readRoomsRegistry().get(msg.room_id);

  // History FIRST (PR #94 review): deleting transcripts before the registry
  // prune keeps every failure window recoverable — if we crash mid-flow the
  // room is still registered, so a retry re-runs both steps. Prune-then-
  // history would orphan the transcripts forever: the entry (cwd + session
  // id) is what locates them, and the UI path for a retry is gone.
  let historyRemoved: boolean | undefined;
  let historyNote: string | undefined;
  if (msg.delete_history) {
    if (!entry || typeof entry.cwd !== "string" || !entry.cwd.trim()) {
      // Unknown room (or pre-cwd entry): nothing to locate on disk.
      historyRemoved = false;
      historyNote = "kept: session folder unknown (or never registered)";
    } else {
      const res = deleteRoomHistory(entry.cwd, entry.sessionId);
      historyRemoved = res.removed;
      historyNote = res.note;
    }
  }

  let registryRemoved = false;
  try {
    registryRemoved = forgetRoom(msg.room_id) !== null;
  } catch (e) {
    sender.send({
      type: "forget_room_result",
      in_reply_to: msg.id,
      ok: false,
      message: `Could not update the session registry: ${(e as Error).message}`,
      registry_removed: false,
      ...(historyRemoved !== undefined ? { history_removed: historyRemoved } : {}),
      ...(historyNote !== undefined ? { history_note: historyNote } : {}),
    });
    return;
  }

  sender.send({
    type: "forget_room_result",
    in_reply_to: msg.id,
    ok: true,
    message: registryRemoved
      ? "The computer forgot this session."
      : "The computer had already forgotten this session.",
    registry_removed: registryRemoved,
    ...(historyRemoved !== undefined ? { history_removed: historyRemoved } : {}),
    ...(historyNote !== undefined ? { history_note: historyNote } : {}),
  });
}
