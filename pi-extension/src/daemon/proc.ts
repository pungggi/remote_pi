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

/** Numeric directory names of a `/proc` tree, without `excludePid`. */
export function listPids(procRoot: string = DEFAULT_PROC_ROOT, excludePid?: number): number[] {
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
    if (pid === excludePid) continue;
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

/** The script node was told to run: the first argument after the executable
 *  that is not an option. Node keeps it exactly as typed on the command
 *  line, so a symlink keeps its link path. */
function scriptArg(argv: string[]): string | undefined {
  return argv.slice(1).find((a) => !a.startsWith("-"));
}

/** True when argv looks like the supervisor: `node …/dist/bin/supervisord.js`.
 *  The `pi-supervisord` symlink is accepted too — node keeps the link path
 *  when the binary is started through it. Only the SCRIPT argument counts,
 *  so a value that merely looks like the name (`--name supervisord.js`) can
 *  never match. */
export function isSupervisorArgv(argv: string[]): boolean {
  const script = scriptArg(argv);
  return script !== undefined && /(^|\/)(supervisord\.js|pi-supervisord)$/.test(script);
}

/** True when argv looks like the guard loop: `node …/index.js guard run`
 *  (also through the `remote-pi` symlink). Both words must be the script's
 *  positionals, in that order. */
export function isGuardArgv(argv: string[]): boolean {
  const script = scriptArg(argv);
  if (script === undefined || !/(^|\/)(index\.js|remote-pi)$/.test(script)) return false;
  const i = argv.indexOf(script);
  return argv[i + 1] === "guard" && argv[i + 2] === "run";
}

/** Every pid (other than `excludePid`, default: this process) whose argv
 *  satisfies `predicate`. */
export function findPidsMatching(
  predicate: (argv: string[]) => boolean,
  procRoot: string = DEFAULT_PROC_ROOT,
  excludePid: number = process.pid,
): number[] {
  const out: number[] = [];
  for (const pid of listPids(procRoot, excludePid)) {
    const argv = readCmdline(procRoot, pid);
    if (argv && argv.length > 0 && predicate(argv)) out.push(pid);
  }
  return out;
}

/** Pids of running `pi-supervisord` processes. */
export function findSupervisorPids(procRoot: string = DEFAULT_PROC_ROOT): number[] {
  return findPidsMatching(isSupervisorArgv, procRoot);
}

/** Pids of running guard loops. */
export function findGuardPids(procRoot: string = DEFAULT_PROC_ROOT): number[] {
  return findPidsMatching(isGuardArgv, procRoot);
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
