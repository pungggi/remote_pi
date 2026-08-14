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
import { projectsRoots } from "../config.js";
import { listWorktrees } from "./worktree_registry.js";

/** True when `child` equals `parent` or lives somewhere under it. */
function isUnder(child: string, parent: string): boolean {
  if (child === parent) return true;
  return child.startsWith(parent.endsWith(sep) ? parent : parent + sep);
}

/** All paths a remote action may target. Test seam; production reads config. */
export function allowedRemoteCwds(): string[] {
  const roots = projectsRoots().map((root) => resolve(root));
  const worktrees = listWorktrees().map((entry) => resolve(entry.path));
  return [...roots, ...worktrees];
}

/** Policy verdict for a remote-supplied cwd. */
export function remoteCwdAllowed(cwd: string): boolean {
  const target = resolve(cwd);
  return allowedRemoteCwds().some((allowed) => isUnder(target, allowed));
}
