/**
 * Plan/112 — persistent registry of git worktrees created by "Open terminal"
 * (plan 108's worktree mode). Stored at `~/.pi/piper/worktrees.json`, mirroring
 * `daemon/registry.ts`'s `daemons.json` convention.
 *
 * The registry is the **source of truth** the app lists against. It is
 * reconciled on every read: entries whose `path/.git` no longer exists
 * (manually deleted / pruned) are dropped and the cleanup persisted, so the
 * app never shows ghost worktrees.
 *
 * `REMOTE_PI_HOME` overrides the home root (used by tests + alternate installs).
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { WireWorktree } from "../protocol/types.js";

interface RegistryFile {
  worktrees: WireWorktree[];
}

/** Resolved at call time so tests can override via `REMOTE_PI_HOME`. */
function registryPath(): string {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  return join(root, ".pi", "piper", "worktrees.json");
}

function load(): RegistryFile {
  try {
    const raw = readFileSync(registryPath(), "utf8");
    const parsed = JSON.parse(raw) as unknown;
    if (
      parsed &&
      typeof parsed === "object" &&
      Array.isArray((parsed as RegistryFile).worktrees)
    ) {
      return parsed as RegistryFile;
    }
  } catch {
    /* missing / unreadable / invalid JSON → start empty */
  }
  return { worktrees: [] };
}

function save(reg: RegistryFile): void {
  try {
    const p = registryPath();
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, JSON.stringify(reg, null, 2) + "\n");
  } catch {
    /* best-effort — tracking must never break the launch */
  }
}

/** Records a newly-created worktree (dedupes by path). */
export function addWorktree(entry: WireWorktree): void {
  const reg = load();
  reg.worktrees = reg.worktrees.filter((w) => w.path !== entry.path);
  reg.worktrees.push(entry);
  save(reg);
}

/**
 * Returns tracked worktrees, optionally filtered by `base`. Reconciles against
 * the filesystem: drops entries whose worktree dir (`.git` file/dir) no longer
 * exists and persists the cleanup. Newest-first.
 */
export function listWorktrees(base?: string | null): WireWorktree[] {
  const reg = load();
  const live = reg.worktrees.filter((w) => {
    if (!existsSync(join(w.path, ".git"))) return false; // stale / pruned
    if (base && w.base !== base) return false;
    return true;
  });
  if (live.length !== reg.worktrees.length) save({ worktrees: live });
  // newest first (created_at desc)
  return [...live].sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
}

/** Removes the registry entry with `id`. Returns false when not found. Does
 *  NOT touch the filesystem — callers run `git worktree remove` first. */
export function forgetWorktree(id: string): boolean {
  const reg = load();
  const before = reg.worktrees.length;
  reg.worktrees = reg.worktrees.filter((w) => w.id !== id);
  if (reg.worktrees.length === before) return false;
  save(reg);
  return true;
}
