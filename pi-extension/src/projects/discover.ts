/**
 * Plan/121 — discover git projects under configured roots so the phone can
 * list the user's repos and spawn a worktree terminal from any of them.
 *
 * A directory is a **project** when it contains a `.git` **directory** (a main
 * working tree). Git worktrees and submodules have a `.git` **file** (a pointer
 * into another repo's `worktrees/`) — those are skipped on purpose, so the list
 * shows real project roots, not the throwaway worktrees the user creates from
 * them (plan/108). Curation (hide/pin the rest) is plan/122.
 *
 * Read-only + best-effort: unreadable or missing roots are skipped silently,
 * the walk is depth-bounded and entry-capped so a pathological tree can't
 * hang or OOM the device daemon. Pure fs — no deps, trivially testable with
 * a temp tree.
 */
import { readdirSync, realpathSync, statSync } from "node:fs";
import { basename, join } from "node:path";

export interface WireProject {
  /** Absolute path of the project root (the repo's working tree). */
  path: string;
  /** `basename(path)` — the project's display name. */
  name: string;
}

export interface DiscoverOptions {
  /** Max subdirectory depth to descend below each root. Default 2 — catches
   *  both standalone repos (immediate children) and nested clones under a
   *  monorepo, without walking the whole filesystem. */
  maxDepth?: number;
  /** Hard cap on returned projects (safety against a giant tree). Default 200. */
  maxEntries?: number;
}

/** A dir is a main git repo iff `.git` exists AND is a directory. Worktrees
 *  and submodules have a `.git` FILE → excluded (see module doc). */
function isMainGitRepo(dir: string): boolean {
  let st: ReturnType<typeof statSync>;
  try {
    st = statSync(join(dir, ".git"));
  } catch {
    return false;
  }
  return st.isDirectory();
}

/** Cheap descent filter — never recurse into obvious junk trees. Keeps the
 *  walk fast and avoids descending into `node_modules` etc. */
function worthDescending(name: string): boolean {
  if (name === ".git" || name === "node_modules" || name === ".pi") return false;
  if (name.startsWith(".")) return false; // hidden (.cache, .venv, .idea, …)
  switch (name) {
    case "target":
    case "build":
    case "dist":
    case "out":
    case "__pycache__":
    case ".next":
    case "Pods":
      return false;
    default:
      return true;
  }
}

/**
 * Scan `roots` for main git repos. Depth-limited, entry-capped, deduped by
 * realpath (so a symlinked repo and its target collapse), sorted by name then
 * path. Never throws — a missing/unreadable root or a permissions error on a
 * subtree is silently skipped (discovery is best-effort; one bad dir must not
 * blank the whole list).
 */
export function discoverProjects(roots: readonly string[], opts: DiscoverOptions = {}): WireProject[] {
  const maxDepth = opts.maxDepth ?? 2;
  const maxEntries = opts.maxEntries ?? 200;
  const found = new Map<string, WireProject>(); // key = realpath for dedupe

  const visit = (dir: string, depth: number): void => {
    if (found.size >= maxEntries) return;
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return; // unreadable / not a dir — skip silently
    }
    for (const name of entries) {
      if (found.size >= maxEntries) return;
      if (!worthDescending(name)) continue;
      const child = join(dir, name);
      let st: ReturnType<typeof statSync>;
      try {
        st = statSync(child);
      } catch {
        continue;
      }
      if (!st.isDirectory()) continue;
      if (isMainGitRepo(child)) {
        let key = child;
        try {
          key = realpathSync(child); // collapse symlinked clones to one entry
        } catch {
          /* keep raw path as key */
        }
        if (!found.has(key)) {
          found.set(key, { path: child, name: basename(child) });
        }
      }
      // Descend even into found repos: a monorepo can nest other main repos
      // (e.g. `~/source/pi/packages/remote_pi`). Curation is plan/122.
      if (depth < maxDepth) visit(child, depth + 1);
    }
  };

  for (const root of roots) {
    if (root && root.trim()) visit(root.trim(), 0);
  }

  return [...found.values()].sort(
    (a, b) => a.name.localeCompare(b.name) || a.path.localeCompare(b.path),
  );
}
