/**
 * Plan/108 — open a new terminal in a throwaway git worktree off the base
 * project (remote `/ps clone` + isolated working copy).
 *
 * The app sends `open_terminal_request`; this handler first creates a git
 * worktree off the resolved cwd (branch `work/<stamp>`, sibling
 * `worktrees/<stamp>` folder), then opens a new Windows Terminal tab (or a
 * console-window fallback) INSIDE the worktree, optionally running `pi`, and
 * replies with `open_terminal_result`. Terminal-spawn logic ported from
 * pi-ps `open-tab.ts` (MIT, same author):
 *
 *   - `WT_SESSION` set (we're inside Windows Terminal) → `wt.exe -w 0 new-tab`
 *     adds a tab to the most-recently-used window.
 *   - otherwise → `Start-Process` opens a fresh console window.
 *
 * On-demand (not pushed): only fires when the user taps "Open terminal". The
 * handler replies on every path — including failure (ok:false) — so the app
 * never hits the 15s action timeout; a misconfigured path surfaces as a
 * snackbar, not a hang.
 *
 * Platform guard: only Windows is supported for now. The paired daemon runs
 * in the user's session (local socket supervisor — plan 40, NOT a Session-0
 * Windows Service), so it can open a visible desktop window. Mac/Linux
 * launchers are plan 108b; on those the handler replies ok:false "unsupported".
 */
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import type { ClientMessage, WireWorktree } from "../protocol/types.js";
import type { ActionReplySender } from "./handlers.js";
import { addWorktree, forgetWorktree, listWorktrees } from "./worktree_registry.js";

type OpenTerminalRequestMsg = Extract<
  ClientMessage,
  { type: "open_terminal_request" }
>;

type ListWorktreesRequestMsg = Extract<
  ClientMessage,
  { type: "list_worktrees_request" }
>;

type RemoveWorktreeRequestMsg = Extract<
  ClientMessage,
  { type: "remove_worktree_request" }
>;

export interface OpenTerminalOutcome {
  ok: boolean;
  message: string;
  method: "wt" | "window" | "none";
}

/** Quote a token for a cmd.exe double-quoted context (paths have no "). */
function cmdQuote(s: string): string {
  return `"${String(s)}"`;
}

/** Escape a string for safe PowerShell single-quoted interpolation. */
function psSingleQuote(s: string): string {
  return `'${String(s).replace(/'/g, "''")}'`;
}

/** Compact local timestamp for branch + folder names: YYYYMMDD-HHMMSS. */
function worktreeStamp(d = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return (
    `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}` +
    `-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
  );
}

/** Best-effort human-readable message from an exec error (prefer stderr). */
function errMsg(e: unknown): string {
  const err = e as { stderr?: Buffer | string; stdout?: Buffer | string; message?: string };
  for (const buf of [err.stderr, err.stdout]) {
    if (!buf) continue;
    const s = (typeof buf === "string" ? buf : buf.toString("utf8")).trim();
    if (s) return s;
  }
  return String(err.message ?? e).trim();
}

export interface WorktreeResult {
  ok: boolean;
  entry?: WireWorktree;
  message: string;
}

/**
 * Plan/108 (worktree mode) — create a throwaway git worktree off `baseCwd`
 * (current HEAD) and return its tracked entry. New branch `work/<stamp>`,
 * worktree placed in a sibling `worktrees/<stamp>` folder next to the base
 * repo. The entry is recorded in the worktree registry (plan 112).
 *
 * Returns ok:false (never throws) when the path isn't a git repo, `git` is
 * missing, or `git worktree add` fails — the caller surfaces it as a
 * snackbar. Worktrees are pruned via the app's remove action (git worktree
 * remove + branch delete + registry forget).
 */
export function createWorktree(baseCwd: string): WorktreeResult {
  const d = new Date();
  const stamp = worktreeStamp(d);
  const branch = `work/${stamp}`;
  const worktreesDir = join(dirname(baseCwd), "worktrees");
  const worktreePath = join(worktreesDir, stamp);

  // 1. Must be inside a git work tree.
  try {
    execFileSync("git", ["-C", baseCwd, "rev-parse", "--is-inside-work-tree"], {
      encoding: "utf8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
  } catch (e) {
    return { ok: false, message: `Not a git repository: ${baseCwd} — ${errMsg(e)}` };
  }

  // 2. Ensure the sibling worktrees/ folder exists.
  try {
    mkdirSync(worktreesDir, { recursive: true });
  } catch (e) {
    return { ok: false, message: `Cannot create ${worktreesDir}: ${errMsg(e)}` };
  }

  // 3. Create the worktree on a fresh branch off HEAD.
  try {
    execFileSync("git", ["-C", baseCwd, "worktree", "add", "-b", branch, worktreePath], {
      encoding: "utf8",
      timeout: 30000,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
  } catch (e) {
    return { ok: false, message: `git worktree add failed: ${errMsg(e)}` };
  }

  const entry: WireWorktree = {
    id: stamp,
    base: baseCwd,
    path: worktreePath,
    branch,
    created_at: d.toISOString(),
  };
  addWorktree(entry);
  return { ok: true, entry, message: `Created worktree ${branch}` };
}

let _shellCache: string | null = null;

/**
 * Resolve the PowerShell executable once per process: prefer `pwsh.exe`
 * (PowerShell 7) on PATH, fall back to Windows PowerShell (`powershell.exe`).
 * Cached because the path never changes during a session.
 */
function resolveShell(): string {
  if (_shellCache) return _shellCache;
  try {
    const out = execFileSync("where", ["pwsh"], {
      encoding: "utf8",
      timeout: 2000,
      stdio: ["ignore", "pipe", "ignore"],
      windowsHide: true,
    }).trim();
    const first = out.split(/\r?\n/)[0];
    if (first) {
      _shellCache = first;
      return first;
    }
  } catch {
    // pwsh not installed → fall through to Windows PowerShell.
  }
  _shellCache = "powershell.exe";
  return _shellCache;
}

interface ChildHandle {
  on(event: "error", cb: (err: Error) => void): unknown;
  on(event: "close", cb: (code: number | null) => void): unknown;
  unref(): unknown;
}

/**
 * Opens a new terminal at `cwd`, optionally running `command` (e.g. "pi").
 * Mirrors pi-ps `openTab`: WT_SESSION → `wt.exe new-tab`; else Start-Process
 * window. A 2s safety net assumes success — the target runs independently of
 * the launcher (detached + unref'd).
 */
export function openTerminalTab(
  cwd: string,
  command: string | undefined,
): Promise<OpenTerminalOutcome> {
  return new Promise((resolve) => {
    if (process.platform !== "win32") {
      resolve({
        ok: false,
        message: "Opening a terminal is only supported on Windows so far.",
        method: "none",
      });
      return;
    }

    const inWindowsTerminal = Boolean(process.env.WT_SESSION);
    const shellExe = resolveShell();
    const cmdSuffix = command
      ? ` -NoExit -Command ${cmdQuote(command)}`
      : "";
    const withCmd = command ? ` — running ${command}` : "";

    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const done = (r: OpenTerminalOutcome) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve(r);
    };

    if (inWindowsTerminal) {
      // ── Windows Terminal: open a real new tab in the MRU window ──
      const argsLine = `-w 0 new-tab -d ${cmdQuote(cwd)} ${cmdQuote(shellExe)}${cmdSuffix}`;
      const okMessage = `Opened terminal tab at: ${cwd}${withCmd}`;
      try {
        const child = spawn(`wt.exe ${argsLine}`, [], {
          detached: true,
          stdio: "ignore",
          shell: true,
          windowsHide: true,
        }) as unknown as ChildHandle;
        child.on("error", (err) =>
          done({ ok: false, message: `Failed to open: ${err.message}`, method: "wt" }),
        );
        child.on("close", () => done({ ok: true, message: okMessage, method: "wt" }));
        timer = setTimeout(() => done({ ok: true, message: okMessage, method: "wt" }), 2000);
        child.unref();
      } catch (e) {
        done({
          ok: false,
          message: `Failed to launch wt.exe: ${(e as Error).message}`,
          method: "wt",
        });
      }
    } else {
      // ── Fallback: open a new console window via Start-Process ──
      const argList = command ? `-NoExit -Command ${command}` : "";
      const psCommand =
        `Start-Process -FilePath ${psSingleQuote(shellExe)}` +
        (argList ? ` -ArgumentList ${psSingleQuote(argList)}` : "") +
        ` -WorkingDirectory ${psSingleQuote(cwd)}`;
      const okMessage = `Opened terminal window at: ${cwd}${withCmd}`;
      try {
        const child = spawn(shellExe, ["-NoProfile", "-Command", psCommand], {
          detached: true,
          stdio: "ignore",
          windowsHide: true,
        }) as unknown as ChildHandle;
        child.on("error", (err) =>
          done({ ok: false, message: `Failed to open: ${err.message}`, method: "window" }),
        );
        child.on("close", () => done({ ok: true, message: okMessage, method: "window" }));
        timer = setTimeout(() => done({ ok: true, message: okMessage, method: "window" }), 2000);
        child.unref();
      } catch (e) {
        done({
          ok: false,
          message: `Failed to launch ${shellExe}: ${(e as Error).message}`,
          method: "window",
        });
      }
    }
  });
}

/**
 * Replies with `open_terminal_result`. `ok` is false when: the platform isn't
 * Windows, no cwd is resolvable, the path doesn't exist, or the launcher
 * failed. Never throws — every path sends a reply so the app can't time out.
 *
 * `sessionCwd` is the Pi's own working directory (from room_meta); used when
 * the request omits `cwd` (pure `/ps clone` behavior — open at the current
 * folder).
 */
export async function handleOpenTerminal(
  sender: ActionReplySender,
  msg: OpenTerminalRequestMsg,
  sessionCwd: string | null,
): Promise<void> {
  const requested = msg.cwd && msg.cwd.trim() ? msg.cwd.trim() : null;
  const cwd = requested ?? sessionCwd;

  if (!cwd) {
    sender.send({
      type: "open_terminal_result",
      in_reply_to: msg.id,
      ok: false,
      message: "No working directory to open — pin a path or open from a session with a folder.",
      method: "none",
    });
    return;
  }

  if (!existsSync(cwd)) {
    sender.send({
      type: "open_terminal_result",
      in_reply_to: msg.id,
      ok: false,
      message: `Path not found: ${cwd}`,
      method: "none",
    });
    return;
  }

  // Plan/112 — reopen: when the request carries a `worktree_path`, skip
  // creation entirely and open a terminal at that existing worktree.
  const reopenPath = msg.worktree_path && msg.worktree_path.trim() ? msg.worktree_path.trim() : null;

  let worktreePath: string;
  let created: WireWorktree | undefined;
  if (reopenPath) {
    if (!existsSync(reopenPath)) {
      sender.send({
        type: "open_terminal_result",
        in_reply_to: msg.id,
        ok: false,
        message: `Worktree path not found: ${reopenPath}`,
        method: "none",
      });
      return;
    }
    worktreePath = reopenPath;
  } else {
    // Plan/108 — spawn a throwaway git worktree off the base project at `cwd`
    // and open the terminal INSIDE it (not the base repo). Each tap creates
    // an isolated working copy on its own branch `work/<stamp>`. ok:false
    // (e.g. not a git repo, or worktree add failed) surfaces as a snackbar.
    const wt = createWorktree(cwd);
    if (!wt.ok || !wt.entry) {
      sender.send({
        type: "open_terminal_result",
        in_reply_to: msg.id,
        ok: false,
        message: wt.message,
        method: "none",
      });
      return;
    }
    worktreePath = wt.entry.path;
    created = wt.entry;
  }

  const runPi = msg.runPi !== false; // default true (matches /ps clone)
  const outcome = await openTerminalTab(worktreePath, runPi ? "pi" : undefined);

  sender.send({
    type: "open_terminal_result",
    in_reply_to: msg.id,
    ok: outcome.ok,
    message: outcome.ok && created
      ? `${outcome.message} (branch ${created.branch})`
      : outcome.message,
    method: outcome.method,
    ...(created ? { worktree: created } : {}),
  });
}

/**
 * Plan/112 — replies with `list_worktrees_result`. Returns the reconciled
 * registry, optionally filtered by base repo path. Always ok:true (an empty
 * list is a valid answer, not an error).
 */
export function handleListWorktrees(
  sender: ActionReplySender,
  msg: ListWorktreesRequestMsg,
): void {
  const worktrees = listWorktrees(msg.base ?? null);
  sender.send({
    type: "list_worktrees_result",
    in_reply_to: msg.id,
    ok: true,
    worktrees,
  });
}

/**
 * Plan/112 — replies with `remove_worktree_result`. Runs
 * `git worktree remove <path>` (then `git branch -D <branch>`) and prunes the
 * registry entry. ok:false when the id is unknown or git fails (dirty tree,
 * etc.) — the entry is left intact so the user can retry or force-remove.
 */
export function handleRemoveWorktree(
  sender: ActionReplySender,
  msg: RemoveWorktreeRequestMsg,
): void {
  const entry = listWorktrees(null).find((w) => w.id === msg.worktree_id);
  if (!entry) {
    sender.send({
      type: "remove_worktree_result",
      in_reply_to: msg.id,
      ok: false,
      message: "Worktree not found (it may already be removed).",
    });
    return;
  }

  // Remove the working tree if it still exists on disk.
  if (existsSync(join(entry.path, ".git"))) {
    try {
      execFileSync("git", ["-C", entry.base, "worktree", "remove", entry.path], {
        encoding: "utf8",
        timeout: 30000,
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      });
    } catch (e) {
      sender.send({
        type: "remove_worktree_result",
        in_reply_to: msg.id,
        ok: false,
        message: `git worktree remove failed: ${errMsg(e)}`,
      });
      return;
    }
  }

  // Delete the branch (worktree remove does NOT delete the branch). Best-effort
  // — an unmerged branch or a race surfaces as a non-fatal failure.
  try {
    execFileSync("git", ["-C", entry.base, "branch", "-D", entry.branch], {
      encoding: "utf8",
      timeout: 10000,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
  } catch {
    /* branch may have unmerged commits or be gone — non-fatal */
  }

  forgetWorktree(entry.id);
  sender.send({
    type: "remove_worktree_result",
    in_reply_to: msg.id,
    ok: true,
    message: `Removed worktree ${entry.branch}`,
  });
}
