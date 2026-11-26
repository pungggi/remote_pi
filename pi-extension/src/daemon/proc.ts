/**
 * Process-table helpers for the Termux guard and uninstaller (plan/173).
 *
 * Linux/Android only: everything is a pure function over a `/proc` tree, so
 * the lookup logic is unit-testable on any OS with a fake directory of
 * `cmdline` files. Nothing here spawns or signals a process by itself, except
 * `signalPid`, which is a thin wrapper over `process.kill`.
 *
 * Why `/proc` and no pid file for the supervisor: the supervisor is started
 * by several launchers (boot script, guard, a shell) and carries no pid file.
 * Its argv does identify it, and inside Termux every process belongs to the
 * same app uid, so the table is complete for our purposes.
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

export const DEFAULT_PROC_ROOT = "/proc";

/** argv of one process, or null when it cannot be read (gone, or a zombie
 *  whose argv was already cleared). Android null-separates the arguments. */
export function readCmdline(procRoot: string, pid: number): string[] | null {
  try {
    const raw = readFileSync(join(procRoot, String(pid), "cmdline"), "utf8");
    return raw.split("\0").filter((s) => s.length > 0);
  } catch {
    return null;
  }
}

/** Numeric directory names of a `/proc` tree, without the `exclude` pids. */
export function listPids(procRoot: string = DEFAULT_PROC_ROOT, ...exclude: number[]): number[] {
  let names: string[];
  try {
    names = readdirSync(procRoot);
  } catch {
    return [];
  }
  const out: number[] = [];
  for (const name of names) {
    if (!/^\d+$/.test(name)) continue;
    const pid = Number(name);
    if (exclude.includes(pid)) continue;
    out.push(pid);
  }
  return out;
}

/** True while `/proc/<pid>` exists. A zombie still has its entry; nothing in
 *  Termux leaves zombies behind for long (the app reaps its children). */
export function isPidAlive(pid: number, procRoot: string = DEFAULT_PROC_ROOT): boolean {
  try {
    statSync(join(procRoot, String(pid)));
    return true;
  } catch {
    return false;
  }
}

/** True for the node executable itself: Termux's `node`, Debian's `nodejs`. Only
 *  a process whose argv[0] is node can be the supervisor or the guard — an
 *  editor, grep, tmux or a `bash -c "node …"` launcher shell never qualifies,
 *  however much its command line looks like one. */
export function isNodeExecutable(argv0: string | undefined): boolean {
  if (!argv0) return false;
  const base = argv0.replace(/\\/g, "/").split("/").pop() ?? "";
  return base === "node" || base === "nodejs";
}

/** The script node was told to run: the first argument after the executable
 *  that is not an option. Node keeps it exactly as typed on the command
 *  line, so a symlink keeps its link path. */
function scriptArg(argv: string[]): string | undefined {
  return argv.slice(1).find((a) => !a.startsWith("-"));
}

/** True when argv is the supervisor: `node …/dist/bin/supervisord.js`.
 *  argv[0] must be node and the SCRIPT argument must be the supervisor entry
 *  (the `pi-supervisord` symlink counts: node keeps the link path when the
 *  binary is started through it). Anything else that merely mentions the
 *  name — `vim …/supervisord.js`, `grep supervisord`, `bash -c "node …
 *  supervisord.js"`, a `--name supervisord.js` value — does not match. */
export function isSupervisorArgv(argv: string[]): boolean {
  if (!isNodeExecutable(argv[0])) return false;
  const script = scriptArg(argv);
  return script !== undefined && /(^|\/)(supervisord\.js|pi-supervisord)$/.test(script);
}

/** Node options whose next argument is a module node loads BEFORE the entry
 *  script: this is where a wrapper puts its shim. */
const PRELOAD_OPTIONS: ReadonlySet<string> = new Set(["--require", "-r", "--import"]);

/** True when argv is the guard loop: `node …/index.js guard run`
 *  (also through the `remote-pi` symlink). argv[0] must be node, and the
 *  FIRST argument that looks like the entry script must be followed by
 *  exactly `guard run`. That argument is not assumed to sit right behind
 *  `node`: a wrapper may put options before it, with a value of their own
 *  (`node --require <shim> …/index.js guard run`), and reading only the
 *  first non-option argument made such a guard look dead. Option TOKENS are
 *  never the entry script, nor is the module behind a preload option. An
 *  earlier entry-like argument followed by other words (`index.js daemon
 *  status … index.js guard run`) is the entry of some other command: not
 *  the guard. The interim shell guard (`piper-guard.sh`) is deliberately
 *  NOT this: it gets retired, never mistaken for a running instance. */
export function isGuardArgv(argv: string[]): boolean {
  if (!isNodeExecutable(argv[0])) return false;
  for (let i = 1; i + 2 < argv.length; i++) {
    const arg = argv[i] ?? "";
    // An option TOKEN is never the entry script (also in the `--require=<file>`
    // form), and behind a preload option in its two-argument form stands the
    // module node loads first, not the script it runs. A value of some other
    // option that happens to end like the entry script would be taken for it:
    // not a shape any wrapper uses.
    if (arg.startsWith("-") || PRELOAD_OPTIONS.has(argv[i - 1] ?? "")) continue;
    if (/(^|\/)(index\.js|remote-pi)$/.test(arg)) return argv[i + 1] === "guard" && argv[i + 2] === "run";
  }
  return false;
}

/** True for the INTERIM guard the phone ran before `remote-pi guard` existed:
 *  a shell running `…/piper-guard.sh` (as a script argument or inside a
 *  `bash -c` command string). It shares the pid file and the log with the
 *  real guard, so the real guard has to find and stop it. */
export function isInterimGuardArgv(argv: string[]): boolean {
  // Only a shell can be the interim guard; a node process mentioning the
  // script (an editor wrapper, a test) is not it.
  if (isNodeExecutable(argv[0]) || !/^(.*\/)?(ba|da|a|z|k)?sh$/.test(argv[0] ?? "")) return false;
  return argv.slice(1).some((a) => /piper-guard\.sh(\s|$)/.test(a));
}

/** Every pid, other than `excludePids` (default: this process and its parent —
 *  a caller's own launcher must never be a match), whose argv satisfies
 *  `predicate`. */
export function findPidsMatching(
  predicate: (argv: string[]) => boolean,
  procRoot: string = DEFAULT_PROC_ROOT,
  excludePids: number[] = [process.pid, process.ppid],
): number[] {
  const out: number[] = [];
  for (const pid of listPids(procRoot, ...excludePids.filter((p) => Number.isInteger(p)))) {
    const argv = readCmdline(procRoot, pid);
    if (argv && argv.length > 0 && predicate(argv)) out.push(pid);
  }
  return out;
}

/** Pids of running `pi-supervisord` node processes. */
export function findSupervisorPids(procRoot: string = DEFAULT_PROC_ROOT): number[] {
  return findPidsMatching(isSupervisorArgv, procRoot);
}

/** Pids of running `remote-pi guard run` loops. */
export function findGuardPids(procRoot: string = DEFAULT_PROC_ROOT): number[] {
  return findPidsMatching(isGuardArgv, procRoot);
}

/** Pids of running interim shell guards (`piper-guard.sh`). */
export function findInterimGuardPids(procRoot: string = DEFAULT_PROC_ROOT): number[] {
  return findPidsMatching(isInterimGuardArgv, procRoot);
}

// ── Process age (for the guard's age restart) ─────────────────────────────

/** Clock ticks per second of the kernel's process start times. Linux and
 *  Android use USER_HZ = 100. */
export const CLK_TCK = 100;

/** Field 22 (`starttime`, clock ticks since boot) of a `/proc/<pid>/stat`
 *  line. The comm field (2) may contain spaces and parentheses, so parsing
 *  starts after the LAST `)`. */
export function parseStartTicks(statLine: string): number | null {
  const close = statLine.lastIndexOf(")");
  if (close < 0) return null;
  const fields = statLine.slice(close + 1).trim().split(/\s+/);
  // state(3) ppid(4) … itrealvalue(21) starttime(22) → index 19 after comm.
  const ticks = Number(fields[19]);
  return Number.isFinite(ticks) && ticks >= 0 ? ticks : null;
}

/** `btime` of `/proc/stat` (boot time, seconds since the epoch), in ms. */
export function parseBootTimeMs(procStat: string): number | null {
  for (const line of procStat.split(/\r?\n/)) {
    const m = /^btime\s+(\d+)\s*$/.exec(line);
    if (m) return Number(m[1]) * 1000;
  }
  return null;
}

/** Wall-clock start time of `pid`, in epoch ms, or null when `/proc` cannot
 *  answer. Both inputs are counted from boot in monotonic time, which stops
 *  while the device suspends: on a phone that slept the result is LATER than
 *  the true start, so an age based on it is never overestimated. */
export function processStartMs(
  pid: number,
  procRoot: string = DEFAULT_PROC_ROOT,
  clkTck: number = CLK_TCK,
): number | null {
  let stat: string;
  let procStat: string;
  try {
    stat = readFileSync(join(procRoot, String(pid), "stat"), "utf8");
    procStat = readFileSync(join(procRoot, "stat"), "utf8");
  } catch {
    return null;
  }
  const ticks = parseStartTicks(stat);
  const boot = parseBootTimeMs(procStat);
  if (ticks === null || boot === null) return null;
  return boot + (ticks * 1000) / clkTck;
}

/** Send a signal. Returns false when the process is already gone. */
export function signalPid(pid: number, signal: NodeJS.Signals): boolean {
  try {
    process.kill(pid, signal);
    return true;
  } catch {
    return false;
  }
}
