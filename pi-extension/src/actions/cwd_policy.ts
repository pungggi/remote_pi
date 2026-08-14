/**
 * Remote-action cwd policy (security fix 2026-08, review finding M3).
 *
 * `open_terminal_request` and `start_session_request` accept a `cwd` from the
 * wire and turn it into process spawns. Spawning `pi` at an
 * attacker-controlled path is code execution: pi auto-loads project-local
 * `.pi/` config, extensions and skills from the cwd. This module restricts
 * remote-supplied cwds to:
 *
 *   1. any path inside a configured project root (`projects.roots`,
 *      `REMOTE_PI_PROJECTS_ROOTS`, default `~/source`) — including the root
 *      itself; or
 *   2. a worktree previously created by `open_terminal` (the worktree
 *      registry) — worktrees are siblings of a base repo and may legitimately
 *      sit outside the roots.
 *
 * Local sessions started outside the roots are still usable in person; only
 * REMOTE spawning is gated. Users who remote into such paths can add the root
 * via `~/.pi/piper/config.json` `projects.roots`.
 */
import { resolve, sep } from "node:path";
import { realpathSync } from "node:fs";
import { projectsRoots } from "../config.js";
import { listWorktrees } from "./worktree_registry.js";

/** True when `child` equals `parent` or lives somewhere under it. */
function isUnder(child: string, parent: string): boolean {
  if (child === parent) return true;
  return child.startsWith(parent.endsWith(sep) ? parent : parent + sep);
}

/** All paths a remote action may target. Test seam; production reads config.
 *
 *  PR #24 follow-up (#5): roots and targets are compared on `realpathSync`
 *  (symlinks resolved) — a cwd that walks through a symlink pointing OUTSIDE
 *  a root no longer passes, which was a policy bypass (`resolve` only
 *  normalizes syntax, it does not follow links). Roots that don't exist (or
 *  can't be resolved) fall back to their syntactic form — harmless: nothing
 *  can exist beneath them until they do. */
export function allowedRemoteCwds(): string[] {
  const realRoots = projectsRoots().map((root) => {
    const abs = resolve(root);
    try { return realpathSync(abs); } catch { return abs; }
  });
  const realWorktrees = listWorktrees()
    .map((entry) => resolve(entry.path))
    .map((abs) => {
      try { return realpathSync(abs); } catch { return abs; }
    });
  return [...realRoots, ...realWorktrees];
}

/** Policy verdict for a remote-supplied cwd. */
export function remoteCwdAllowed(cwd: string): boolean {
  let target: string;
  try {
    // The target must EXIST for realpath to resolve — a remote action will
    // spawn inside it, so a dangling path is rejected here rather than
    // later. (Callers already existence-check first; this is defense in
    // depth.)
    target = realpathSync(resolve(cwd));
  } catch {
    return false;
  }
  return allowedRemoteCwds().some((allowed) => isUnder(target, allowed));
}
