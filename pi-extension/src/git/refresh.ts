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
 *
 * Plan/149 — the same cadence refreshes `room_meta.gh_ref` via a best-effort
 * `gh pr view` (number/url/state of the checked-out branch's PR). Authoritative
 * when it works; when `gh` is missing/unauthed/not a repo NOTHING changes and
 * NOTHING errors. Precedence: manual refs are never replaced with a different
 * number (see session/ref_ingest.ts).
 */

import { getGitStatus } from "../actions/git_status.js";
import { ext } from "../extension-state.js";
import { upsertRoomMeta } from "../session/rooms_registry.js";
import { applyRefWithPrecedence, ghPrViewRef } from "../session/ref_ingest.js";
import type { WireGhRef } from "../protocol/types.js";

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

/**
 * Plan/149 — best-effort `gh pr view` against the session cwd. Failure of any
 * kind (no binary, no auth, not a repo, no PR for the branch) is a no-op: the
 * acceptance criteria demand "changes nothing and surfaces no error".
 */
async function refreshGhRef(cwd: string): Promise<void> {
  if (!ext.relay || !ext.myRoomId || !ext.myRoomMeta) return;
  const found = await ghPrViewRef(cwd);
  if (!found) return;
  const { next, changed } = applyRefWithPrecedence(ext.myRoomMeta.gh_ref ?? null, found);
  if (!changed) return;
  ext.myRoomMeta = { ...ext.myRoomMeta, gh_ref: next };
  try {
    ext.relay.sendControl({
      type: "room_meta_update",
      room_id: ext.myRoomId,
      meta: { gh_ref: next },
    });
  } catch { /* relay tearing down — next interval retries */ }
  try {
    upsertRoomMeta(ext.myRoomId, { ghRef: next as WireGhRef });
  } catch { /* best-effort registry write */ }
}

async function refreshRoomGit(cwd: string): Promise<void> {
  await pushGitStatus(cwd);
  await refreshGhRef(cwd);
}

export function startGitRefresh(): void {
  stopGitRefresh();
  const cwd = ext.myRoomMeta?.cwd;
  if (!cwd) return;
  void refreshRoomGit(cwd); // seed immediately (broadcasts if changed since last session)
  ext.gitRefreshTimer = setInterval(() => { void refreshRoomGit(cwd); }, GIT_REFRESH_MS);
}

export function stopGitRefresh(): void {
  if (ext.gitRefreshTimer) {
    clearInterval(ext.gitRefreshTimer);
    ext.gitRefreshTimer = null;
  }
}
