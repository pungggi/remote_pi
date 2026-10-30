/**
 * Git-status publisher — polls `git status` for the session cwd and pushes it
 * as `room_meta.git` so every subscribed app renders the Home-list git line
 * without a per-session round-trip.
 *
 * Extracted from src/index.ts (god-file split). Reaches shared state via 'ext'.
 *
 * Git status stays on a one-minute cadence, but stable repository identity is
 * cached and GitHub PR lookups have their own slower cadence. This avoids
 * spawning the same metadata processes every minute in every Pi session.
 * Overlapping refreshes are skipped so a slow repository cannot accumulate
 * subprocesses. Broadcasts still happen only when a snapshot changes.
 */

import { getGitStatusSnapshot } from "../actions/git_status.js";
import type { GitRepositoryInfo } from "../actions/git_status.js";
import { ext } from "../extension-state.js";
import { upsertRoomMeta } from "../session/rooms_registry.js";
import { applyRefWithPrecedence, ghPrViewRef } from "../session/ref_ingest.js";
import type { WireGhRef, WireGitStatus } from "../protocol/types.js";

const GIT_REFRESH_MS = 60_000; // 1 min — posh-git-style Home tile refresh
const GH_REFRESH_MS = 5 * 60_000;
const REPOSITORY_INFO_REFRESH_MS = 15 * 60_000;

interface RefreshState {
  cancelled: boolean;
  running: boolean;
  repositoryInfo: GitRepositoryInfo | null;
  repositoryInfoReadAt: number;
  lastGhRefreshAt: number;
  lastGhBranch: string | null | undefined;
}

let activeRefresh: RefreshState | null = null;

function isActive(state: RefreshState): boolean {
  return activeRefresh === state && !state.cancelled;
}

/** Returns undefined when the refresh was cancelled or has no live relay. */
async function pushGitStatus(
  cwd: string,
  state: RefreshState,
): Promise<WireGitStatus | null | undefined> {
  if (!isActive(state) || !ext.relay || !ext.myRoomId) return undefined;

  const now = Date.now();
  const useCachedRepository = state.repositoryInfo !== null &&
    now - state.repositoryInfoReadAt < REPOSITORY_INFO_REFRESH_MS;
  const snapshot = await getGitStatusSnapshot(
    cwd,
    useCachedRepository ? state.repositoryInfo! : undefined,
  );
  if (!isActive(state) || !ext.relay || !ext.myRoomId) return undefined;

  if (!useCachedRepository && snapshot.status && snapshot.repositoryInfo) {
    state.repositoryInfo = snapshot.repositoryInfo;
    state.repositoryInfoReadAt = now;
  }

  const status = snapshot.status;
  // Suppress no-op broadcasts (unchanged snapshot) to avoid relay churn.
  if (JSON.stringify(ext.lastGitStatus) !== JSON.stringify(status)) {
    ext.lastGitStatus = status;
    if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, git: status };
    try {
      ext.relay.sendControl({
        type: "room_meta_update",
        room_id: ext.myRoomId,
        meta: { git: status },
      });
    } catch { /* relay tearing down — next interval retries */ }
    // Keep the same snapshot in the durable registry so cold starts and
    // keeper-held offline rooms retain their repository grouping.
    try {
      upsertRoomMeta(ext.myRoomId, { git: status });
    } catch { /* best-effort registry write */ }
  }
  return status;
}

/**
 * Plan/149 — best-effort `gh pr view` against the session cwd. Failure of any
 * kind (no binary, no auth, not a repo, no PR for the branch) is a no-op: the
 * acceptance criteria demand "changes nothing and surfaces no error".
 */
async function refreshGhRef(cwd: string, state: RefreshState): Promise<void> {
  if (!isActive(state) || !ext.relay || !ext.myRoomId || !ext.myRoomMeta) return;
  const found = await ghPrViewRef(cwd);
  if (!isActive(state) || !found || !ext.relay || !ext.myRoomId || !ext.myRoomMeta) return;
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

async function refreshRoomGit(cwd: string, state: RefreshState): Promise<void> {
  if (state.running || !isActive(state)) return;
  state.running = true;
  try {
    const status = await pushGitStatus(cwd, state);
    if (status === undefined || !isActive(state)) return;

    const branch = status?.branch ?? null;
    const now = Date.now();
    const branchChanged = state.lastGhBranch !== branch;
    if (!branchChanged && now - state.lastGhRefreshAt < GH_REFRESH_MS) return;

    // Attempt GH at most once per interval even when it is missing, unauthed,
    // or the branch has no PR. A branch change refreshes immediately.
    await refreshGhRef(cwd, state);
    if (!isActive(state)) return;
    state.lastGhRefreshAt = Date.now();
    state.lastGhBranch = branch;
  } finally {
    state.running = false;
  }
}

export function startGitRefresh(): void {
  stopGitRefresh();
  const cwd = ext.myRoomMeta?.cwd;
  if (!cwd) return;
  const state: RefreshState = {
    cancelled: false,
    running: false,
    repositoryInfo: null,
    repositoryInfoReadAt: 0,
    lastGhRefreshAt: 0,
    lastGhBranch: undefined,
  };
  activeRefresh = state;
  void refreshRoomGit(cwd, state); // seed immediately
  ext.gitRefreshTimer = setInterval(() => {
    void refreshRoomGit(cwd, state);
  }, GIT_REFRESH_MS);
}

export function stopGitRefresh(): void {
  if (activeRefresh) activeRefresh.cancelled = true;
  activeRefresh = null;
  if (ext.gitRefreshTimer) {
    clearInterval(ext.gitRefreshTimer);
    ext.gitRefreshTimer = null;
  }
}
