/**
 * Plan/108 — open a new terminal at a project folder (remote `/ps clone`).
 *
 * The app sends `open_terminal_request`; this handler opens a new Windows
 * Terminal tab (or a console-window fallback) at the resolved cwd, optionally
 * running `pi`, and replies with `open_terminal_result`. Logic ported from
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
import { existsSync } from "node:fs";
import type { ClientMessage } from "../protocol/types.js";
import type { ActionReplySender } from "./handlers.js";

type OpenTerminalRequestMsg = Extract<
  ClientMessage,
  { type: "open_terminal_request" }
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

  const runPi = msg.runPi !== false; // default true (matches /ps clone)
  const outcome = await openTerminalTab(cwd, runPi ? "pi" : undefined);

  sender.send({
    type: "open_terminal_result",
    in_reply_to: msg.id,
    ok: outcome.ok,
    message: outcome.message,
    method: outcome.method,
  });
}
