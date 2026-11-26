/**
 * Termux terminal launcher — plan/173, stage A3.
 *
 * On a PC "open a terminal" is `wt.exe new-tab` (plan/108). Termux has no
 * such command surface: its `RUN_COMMAND` intent failed from inside Termux in
 * the spike, while tmux worked for Pi and for AGY. So a phone session is a
 * detached tmux session named after its relay room — the phone's equivalent
 * of one terminal tab on the PC:
 *
 *   tmux new-session -d -s <room> -c <cwd> '<command>'
 *
 * The user attaches from Termux on demand (`tmux attach -t <room>`); stage A5
 * adds the app-side button. The session ends when its command exits, exactly
 * like a terminal tab whose program returns.
 *
 * Two environment details matter because the caller is usually the device
 * daemon (`pi --mode rpc`, room `device`):
 *
 *   - Its inline identity (`REMOTE_PI_DIRECT_CONFIG`, `REMOTE_PI_DAEMON`) must
 *     not reach the new `pi`, or the session would join the phone-filtered
 *     `device` room and never show up as a tile. It is scrubbed twice: from
 *     the environment tmux inherits, and inside the command string — because
 *     the tmux SERVER keeps the environment of whichever client started it.
 *   - tmux runs the command string with `sh -c`, so the unset prelude is plain
 *     POSIX and works for any command the callers build.
 */

import { spawn, type ChildProcess } from "node:child_process";

/** What a launched session was started with. `none` = nothing was spawned. */
export type TermuxMethod = "tmux" | "none";

export interface TermuxLaunchOutcome {
  ok: boolean;
  message: string;
  method: TermuxMethod;
  /** The tmux session name (the relay room) when one was requested. */
  session?: string;
}

/** Environment variables that carry a daemon's identity into a child. */
export const TERMUX_DAEMON_SCRUB = "unset REMOTE_PI_DIRECT_CONFIG REMOTE_PI_DAEMON";

/** Login shell for a session without a command. `$SHELL` is set by Termux's
 *  login; a boot-time process may lack it, hence the Termux bash fallback. */
const TERMUX_LOGIN_SHELL = '"${SHELL:-/data/data/com.termux/files/usr/bin/bash}" -l';

/** Tmux session names: letters, digits, `_` and `-`. A relay room id is 12
 *  base64url characters, so every room id passes. `.` and `:` are the two
 *  characters tmux rewrites in session names — never let them in. */
export function tmuxSessionNameOk(name: string): boolean {
  return /^[A-Za-z0-9_-]{1,64}$/.test(name);
}

/** The command string tmux executes inside the session. Without a command a
 *  login shell is opened in the folder (the "just a terminal there" case). */
export function termuxShellCommand(command: string | undefined): string {
  return command ? `${TERMUX_DAEMON_SCRUB}; ${command}` : `${TERMUX_DAEMON_SCRUB}; exec ${TERMUX_LOGIN_SHELL}`;
}

export interface TmuxNewSessionInput {
  /** Session name — the relay room of the session being started. */
  session: string;
  /** Absolute folder the session starts in. */
  cwd: string;
  /** Shell command to run; omitted opens a login shell. */
  command?: string;
  /** Initial size of the detached window. tmux resizes it as soon as a
   *  client attaches; a TUI that draws before anyone attaches (AGY, stage C)
   *  needs a sensible canvas up front. */
  cols?: number;
  rows?: number;
}

/** `tmux new-session …` argument vector. Options first, the command last. */
export function tmuxNewSessionArgs(input: TmuxNewSessionInput): string[] {
  if (!tmuxSessionNameOk(input.session)) {
    throw new RangeError(`not a usable tmux session name: ${JSON.stringify(input.session)}`);
  }
  const args = ["new-session", "-d", "-s", input.session, "-c", input.cwd];
  if (input.cols !== undefined && input.cols > 0) args.push("-x", String(Math.floor(input.cols)));
  if (input.rows !== undefined && input.rows > 0) args.push("-y", String(Math.floor(input.rows)));
  args.push(termuxShellCommand(input.command));
  return args;
}

/** Turns tmux's stderr into the message a phone user can act on. */
export function tmuxFailureMessage(session: string, stderr: string): string {
  const detail = stderr.trim().replace(/\s+/g, " ").slice(0, 300);
  if (/duplicate session/i.test(detail)) {
    return `A terminal for this room is already open on the phone. Attach with: tmux attach -t ${session}`;
  }
  if (/no such command|not found|is tmux running/i.test(detail)) {
    return `tmux failed: ${detail || "tmux server not running"}`;
  }
  return detail ? `tmux failed: ${detail}` : "tmux failed";
}

export interface TermuxSpawnDeps {
  /** `child_process.spawn`, injectable so tests never start tmux. */
  spawn?: typeof spawn;
  /** How long tmux may take to create the session. Default 10 s. */
  timeoutMs?: number;
}

/**
 * Starts the detached tmux session and resolves once tmux has answered: code 0
 * means the session exists, anything else is reported with tmux's own words.
 * Missing tmux (ENOENT) is named explicitly with the package to install.
 * Never throws.
 */
export function startTermuxSession(
  input: TmuxNewSessionInput,
  deps: TermuxSpawnDeps = {},
): Promise<TermuxLaunchOutcome> {
  const spawnFn = deps.spawn ?? spawn;
  const session = input.session;
  let args: string[];
  try {
    args = tmuxNewSessionArgs(input);
  } catch (e) {
    return Promise.resolve({ ok: false, message: (e as Error).message, method: "none", session });
  }
  const withCmd = input.command ? ` — running ${input.command}` : "";
  const okMessage =
    `Opened tmux session ${session} at: ${input.cwd}${withCmd} ` +
    `(attach on the phone with: tmux attach -t ${session})`;

  return new Promise<TermuxLaunchOutcome>((resolve) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let stderr = "";
    const done = (r: TermuxLaunchOutcome): void => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve(r);
    };

    let child: ChildProcess;
    try {
      child = spawnFn("tmux", args, {
        cwd: input.cwd,
        stdio: ["ignore", "ignore", "pipe"],
        detached: true,
        env: envWithoutDaemonIdentity(process.env),
      });
    } catch (e) {
      done({ ok: false, message: `Failed to launch tmux: ${(e as Error).message}`, method: "none", session });
      return;
    }

    child.stderr?.on("data", (chunk: Buffer | string) => { stderr += chunk.toString(); });
    child.on("error", (err: NodeJS.ErrnoException) => {
      if (err.code === "ENOENT") {
        done({
          ok: false,
          message: "tmux is not installed on this phone. Run: pkg install tmux (or remote-pi phone-setup)",
          method: "none",
          session,
        });
        return;
      }
      done({ ok: false, message: `Failed to launch tmux: ${err.message}`, method: "none", session });
    });
    child.on("close", (code) => {
      if (code === 0) done({ ok: true, message: okMessage, method: "tmux", session });
      else done({ ok: false, message: tmuxFailureMessage(session, stderr), method: "none", session });
    });
    timer = setTimeout(() => {
      try { child.kill("SIGKILL"); } catch { /* already gone */ }
      done({
        ok: false,
        message: `tmux did not answer within ${Math.round((deps.timeoutMs ?? 10_000) / 1000)} s`,
        method: "none",
        session,
      });
    }, deps.timeoutMs ?? 10_000);
    child.unref?.();
  });
}

/** The daemon identity must not reach the session's `pi` (see the module
 *  note). Everything else — PATH, relay URL, Termux prefix — is inherited. */
export function envWithoutDaemonIdentity(env: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const out = { ...env };
  delete out.REMOTE_PI_DIRECT_CONFIG;
  delete out.REMOTE_PI_DAEMON;
  return out;
}
