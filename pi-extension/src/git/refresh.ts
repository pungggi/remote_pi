/**
 * Git-status publisher — polls `git status` for the session cwd and pushes it
 * as `room_meta.git` so every subscribed app renders the Home-list git line
 * without a per-session round-trip.
 *
 * Extracted from src/index.ts (god-file split). Reaches shared state via 'ext'.
 *
 * NOT realtime: re-run every GIT_REFRESH_MS and only re-broadcast when the
 * snapshot changes (JSON-equal). Seeded into the hello roomMeta + kept fresh by
 * this interval across the relay session (Plan/107b).
 */

import { getGitStatus } from "../actions/git_status.js";
import { ext } from "../extension-state.js";

const GIT_REFRESH_MS = 60_000; // 1 min — posh-git-style Home tile refresh

async function pushGitStatus(cwd: string): Promise<void> {
  if (!ext.relay || !ext.myRoomId) return;
  const status = await getGitStatus(cwd);
  // Suppress no-op broadcasts (unchanged snapshot) to avoid relay churn.
  if (JSON.stringify(ext.lastGitStatus) === JSON.stringify(status)) return;
  ext.lastGitStatus = status;
  if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, git: status };
  try {
    ext.relay.sendControl({
      type: "room_meta_update",
      room_id: ext.myRoomId,
      meta: { git: status },
    });
  } catch { /* relay tearing down — next interval retries */ }
}

export function startGitRefresh(): void {
  stopGitRefresh();
  const cwd = ext.myRoomMeta?.cwd;
  if (!cwd) return;
  void pushGitStatus(cwd); // seed immediately (broadcasts if changed since last session)
  ext.gitRefreshTimer = setInterval(() => { void pushGitStatus(cwd); }, GIT_REFRESH_MS);
}

export function stopGitRefresh(): void {
  if (ext.gitRefreshTimer) {
    clearInterval(ext.gitRefreshTimer);
    ext.gitRefreshTimer = null;
  }
}
