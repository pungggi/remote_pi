/**
 * `remote-pi restart-supervisor` — restarts the `pi-supervisord` PROCESS
 * through the OS service manager, and PROVES that it did.
 *
 * Why the proof (2026-11-26, PR #126 F4): the command used to run its steps
 * and print "Supervisor restarted." whatever happened. On the owner's PC the
 * running supervisor had been started by hand through a `cmd.exe /c` wrapper,
 * not by the scheduled task, so `schtasks /End` had nothing to end and
 * `schtasks /Run` launched a second instance that refused to start next to
 * the first ("Refusing to start a second instance", task result 1). Same
 * pids before and after, exit code 0. The same failure class exists wherever
 * a second launcher exists: a manual instance survives `systemctl --user
 * restart` and `launchctl kickstart -k` the same way, because the new
 * instance yields to it.
 *
 * So the sequence is now: read the supervisor's identity, run the service
 * commands, then poll until the identity changed. If it has not within a
 * bound, fall back to the plan/168 kill path — stop the old process by pid,
 * wait for it and its children to go, start the service again — and poll
 * once more. The exit code is 0 only when a new supervisor was seen.
 *
 * Identity of an incarnation: the pid of the process that SERVES the control
 * socket (asked from the kernel: `GetNamedPipeServerProcessId` on Windows,
 * the `/proc` socket owner on Linux), plus the children's pids from a real
 * `status` round trip as a fallback where the owner cannot be named.
 */

import { spawnSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { callSupervisor } from "./client.js";
import type { DaemonInfo } from "./control_protocol.js";
import { LAUNCHD_LABEL, SYSTEMD_UNIT, WINDOWS_TASK_NAME } from "./install.js";
import { supervisorSockPath } from "./sock_path.js";
import { describeSocketOwner } from "../session/socket_owner.js";

/** One step of a restart sequence. `ignoreFailure` steps (e.g. `schtasks /End`
 *  when the task isn't running) don't abort the sequence. */
export interface RestartStep { cmd: string; args: string[]; ignoreFailure?: boolean }

/** Pure: the OS command sequence that restarts the supervisor service, or null
 *  when the platform isn't supported. Most platforms are 1 step; Windows is 2
 *  (`schtasks /End` then `/Run`). Exported for tests. */
export function restartSupervisorCommand(
  platform: NodeJS.Platform,
  uid: number,
): RestartStep[] | null {
  if (platform === "darwin") return [{ cmd: "launchctl", args: ["kickstart", "-k", `gui/${uid}/${LAUNCHD_LABEL}`] }];
  if (platform === "linux") return [{ cmd: "systemctl", args: ["--user", "restart", SYSTEMD_UNIT] }];
  if (platform === "win32") return [
    { cmd: "schtasks", args: ["/End", "/TN", WINDOWS_TASK_NAME], ignoreFailure: true },
    { cmd: "schtasks", args: ["/Run", "/TN", WINDOWS_TASK_NAME] },
  ];
  return null;
}

/** Pure: the command that STARTS the service without touching a running
 *  instance — the second half of the kill fallback, once the old process is
 *  gone. `-k` is dropped on macOS on purpose: there is nothing left to kill. */
export function startSupervisorCommand(platform: NodeJS.Platform, uid: number): RestartStep[] | null {
  if (platform === "darwin") return [{ cmd: "launchctl", args: ["kickstart", `gui/${uid}/${LAUNCHD_LABEL}`] }];
  if (platform === "linux") return [{ cmd: "systemctl", args: ["--user", "start", SYSTEMD_UNIT] }];
  if (platform === "win32") return [{ cmd: "schtasks", args: ["/Run", "/TN", WINDOWS_TASK_NAME] }];
  return null;
}

/** How long the service commands get to produce a new supervisor before the
 *  fallback kicks in, and again after it. Node boot, socket bind and the
 *  first `status` answer take a few seconds; 30 s leaves room for a slow
 *  machine without letting a wrong "restarted" go unnoticed for long. */
export const RESTART_WAIT_MS = 30_000;
const POLL_MS = 500;
/** SIGTERM to SIGKILL escalation for the old supervisor in the fallback. */
const KILL_GRACE_MS = 10_000;
/** After a hard kill (Windows has no graceful signal) the old children exit
 *  on their own when stdio closes; the 2026-11-26 replay took about 6 s. */
const CHILDREN_WAIT_MS = 15_000;

/** What one incarnation of the supervisor looks like from outside. */
export interface SupervisorIdentity {
  /** Pid of the process serving the control socket, or null when it could
   *  not be named (no listener, or the platform cannot tell — macOS). */
  pid: number | null;
  /** Fleet rows from a real `status` round trip; null = nobody answered. */
  rows: DaemonInfo[] | null;
}

/** Result of one OS command: ok, or why it failed. */
export type RunOutcome =
  | { ok: true; detail: string }
  | { ok: false; reason: "not-runnable" | "failed"; detail: string };

/** Everything the restart touches, injectable so the whole flow — including
 *  "the status never changes" — is a unit test with no processes. */
export interface RestartDeps {
  platform: NodeJS.Platform;
  uid: number;
  sockPath: string;
  status: () => Promise<DaemonInfo[] | null>;
  owner: () => Promise<{ pid: number } | null>;
  run: (cmd: string, args: string[]) => RunOutcome;
  kill: (pid: number, signal: NodeJS.Signals) => boolean;
  pidAlive: (pid: number) => boolean;
  sleep: (ms: number) => Promise<void>;
  now: () => number;
  log: (line: string) => void;
  /** Poll budget for one change; default RESTART_WAIT_MS. */
  waitMs?: number;
}

export interface RestartResult {
  /** True only when a supervisor with a new identity answered. */
  ok: boolean;
  message: string;
  before: SupervisorIdentity;
  after: SupervisorIdentity;
}

function fingerprint(rows: DaemonInfo[] | null): string {
  if (rows === null) return "";
  return rows.map((d) => `${d.id}:${d.pid ?? "-"}`).sort().join(",");
}

/** The current identity: one `status` round trip, and the socket owner's pid
 *  when somebody answered. (While nobody answers the owner is asked for only
 *  where it is needed, the kill fallback, to save the Windows probe a spawn
 *  per poll.) */
async function identify(deps: Pick<RestartDeps, "status" | "owner">): Promise<SupervisorIdentity> {
  const rows = await deps.status();
  const pid = rows === null ? null : (await deps.owner())?.pid ?? null;
  return { pid, rows };
}

/** Did `after` describe a different incarnation than `before`? The socket
 *  owner's pid decides wherever it is known on both sides; otherwise the
 *  children's pids do (a restart respawns every child). A supervisor that was
 *  down before and answers now counts as changed: it was started. */
export function incarnationChanged(before: SupervisorIdentity, after: SupervisorIdentity): boolean {
  if (after.rows === null) return false;
  if (before.rows === null) return true;
  if (before.pid !== null && after.pid !== null) return after.pid !== before.pid;
  const a = fingerprint(after.rows);
  return a !== "" && a !== fingerprint(before.rows);
}

function describe(identity: SupervisorIdentity): string {
  const who = identity.pid === null ? "pid unknown" : `pid ${identity.pid}`;
  return identity.rows === null ? `not answering (${who})` : `${who}, ${identity.rows.length} fleet row(s)`;
}

function human(ms: number): string {
  return `${(ms / 1000).toFixed(1)} s`;
}

async function waitForChange(
  deps: RestartDeps,
  before: SupervisorIdentity,
  waitMs: number,
): Promise<{ changed: boolean; after: SupervisorIdentity; elapsedMs: number }> {
  const started = deps.now();
  const deadline = started + waitMs;
  for (;;) {
    const after = await identify(deps);
    if (incarnationChanged(before, after)) return { changed: true, after, elapsedMs: deps.now() - started };
    if (deps.now() >= deadline) return { changed: false, after, elapsedMs: deps.now() - started };
    await deps.sleep(POLL_MS);
  }
}

function runSteps(deps: Pick<RestartDeps, "run" | "log">, steps: RestartStep[]): string | null {
  for (const step of steps) {
    const r = deps.run(step.cmd, step.args);
    const line = `${step.cmd} ${step.args.join(" ")}`;
    if (!r.ok) {
      if (step.ignoreFailure) {
        deps.log(`  ${line} → failed, ignored (${r.detail || "nothing to end"})`);
        continue;
      }
      return r.reason === "not-runnable"
        ? `${line} not runnable (${r.detail}). Is the service installed? Run \`remote-pi install\`.`
        : `${line} failed (${r.detail})`;
    }
    deps.log(`  ${line} → ok${r.detail ? ` (${r.detail})` : ""}`);
  }
  return null;
}

/** Waits until `pid` is gone; escalates to SIGKILL after `graceMs`. Resolves
 *  false when the process outlives both. */
async function stopPid(
  deps: Pick<RestartDeps, "kill" | "pidAlive" | "sleep" | "now">,
  pid: number,
  graceMs: number,
): Promise<boolean> {
  deps.kill(pid, "SIGTERM");
  const deadline = deps.now() + graceMs;
  while (deps.pidAlive(pid) && deps.now() < deadline) await deps.sleep(250);
  if (!deps.pidAlive(pid)) return true;
  deps.kill(pid, "SIGKILL");
  const hardDeadline = deps.now() + 3_000;
  while (deps.pidAlive(pid) && deps.now() < hardDeadline) await deps.sleep(250);
  return !deps.pidAlive(pid);
}

/**
 * Restarts the supervisor and proves it. Never throws; the exit code is the
 * caller's (`ok`).
 */
export async function restartSupervisor(deps: RestartDeps): Promise<RestartResult> {
  const steps = restartSupervisorCommand(deps.platform, deps.uid);
  if (!steps) {
    return {
      ok: false,
      message: `restart-supervisor is not supported on '${deps.platform}' yet. Restart pi-supervisord manually.`,
      before: { pid: null, rows: null },
      after: { pid: null, rows: null },
    };
  }
  const waitMs = deps.waitMs ?? RESTART_WAIT_MS;

  const before = await identify(deps);
  deps.log(`supervisor before: ${describe(before)}`);

  const stepError = runSteps(deps, steps);
  if (stepError) {
    return { ok: false, message: `restart-supervisor failed: ${stepError}`, before, after: before };
  }

  let seen = await waitForChange(deps, before, waitMs);
  if (seen.changed) {
    const message = `Supervisor restarted: ${describe(before)} → ${describe(seen.after)} (${human(seen.elapsedMs)}).`;
    deps.log(`[remote-pi] ${message}`);
    return { ok: true, message, before, after: seen.after };
  }

  // The service commands did not replace the running instance: a second
  // launcher (a hand-started process) is still holding the socket and the
  // service's own instance yielded to it. Fall back to the plan/168 kill path.
  const oldPid = before.pid ?? (await deps.owner())?.pid ?? null;
  deps.log(`  no new supervisor after ${human(seen.elapsedMs)}: ${describe(seen.after)}`);
  if (oldPid === null) {
    return {
      ok: false,
      before,
      after: seen.after,
      message:
        "restart-supervisor: the supervisor was NOT restarted (no new instance answered and the running " +
        "one could not be identified to stop it). Stop the running pi-supervisord by hand, then run this " +
        "again. On Windows: Get-CimInstance Win32_Process -Filter \"Name = 'node.exe'\" | Where-Object " +
        "{ $_.CommandLine -match 'supervisord\\.js' } | ForEach-Object { Stop-Process -Id $_.ProcessId }.",
    };
  }
  deps.log(`  the service did not own the running instance → stopping pid ${oldPid} and starting the service again`);
  if (!(await stopPid(deps, oldPid, KILL_GRACE_MS))) {
    return {
      ok: false,
      before,
      after: seen.after,
      message: `restart-supervisor: the supervisor was NOT restarted (pid ${oldPid} survived SIGTERM and SIGKILL).`,
    };
  }
  // Let the old children notice stdio EOF and exit, so the new supervisor
  // does not spawn its own next to a process still holding a room lock.
  const oldChildren = (before.rows ?? []).map((d) => d.pid).filter((p): p is number => p !== undefined);
  if (oldChildren.length > 0) {
    const deadline = deps.now() + CHILDREN_WAIT_MS;
    while (oldChildren.some((p) => deps.pidAlive(p)) && deps.now() < deadline) await deps.sleep(500);
    const left = oldChildren.filter((p) => deps.pidAlive(p));
    deps.log(left.length === 0 ? "  old daemons exited" : `  old daemon pid(s) ${left.join(", ")} still alive after ${human(CHILDREN_WAIT_MS)}`);
  }
  const startError = runSteps(deps, startSupervisorCommand(deps.platform, deps.uid) ?? []);
  if (startError) {
    return { ok: false, message: `restart-supervisor failed: ${startError}`, before, after: seen.after };
  }
  seen = await waitForChange(deps, before, waitMs);
  if (seen.changed) {
    const message =
      `Supervisor restarted through the fallback: ${describe(before)} → ${describe(seen.after)} (${human(seen.elapsedMs)}). ` +
      "The service did not own the running instance; keep ONE launcher (only the service should start the supervisor).";
    deps.log(`[remote-pi] ${message}`);
    return { ok: true, message, before, after: seen.after };
  }
  return {
    ok: false,
    before,
    after: seen.after,
    message:
      `restart-supervisor: the supervisor was NOT restarted (after stopping pid ${oldPid} and starting the service, ` +
      `${describe(seen.after)} after ${human(seen.elapsedMs)}). See ~/.pi/piper/supervisord.log.`,
  };
}

/** Production wiring. */
export function defaultRestartDeps(overrides: Partial<RestartDeps> = {}): RestartDeps {
  return {
    platform: process.platform,
    uid: process.getuid?.() ?? 0,
    sockPath: supervisorSockPath(),
    status: async () => {
      try {
        return (await callSupervisor({ op: "status" })).daemons;
      } catch {
        return null;
      }
    },
    owner: async () => {
      // describeSocketOwner unrefs its probe so a diagnosis can never keep a pi
      // session alive. A CLI process has nothing else on its event loop, so
      // without a handle here node would exit mid-restart — with code 0,
      // before the answer arrived.
      const keepAlive = setInterval(() => undefined, 1_000);
      try {
        const owner = await describeSocketOwner(supervisorSockPath());
        return owner === null ? null : { pid: owner.pid };
      } finally {
        clearInterval(keepAlive);
      }
    },
    run: (cmd, args) => {
      const r = spawnSync(cmd, args, { stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" });
      const detail = (r.stderr || r.stdout || "").trim();
      if (r.error) return { ok: false, reason: "not-runnable", detail: r.error.message };
      if (r.status !== 0) return { ok: false, reason: "failed", detail: `exited ${r.status}${detail ? `: ${detail}` : ""}` };
      return { ok: true, detail };
    },
    kill: (pid, signal) => {
      try {
        process.kill(pid, signal);
        return true;
      } catch {
        return false;
      }
    },
    pidAlive: (pid) => {
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        return false;
      }
    },
    sleep: (ms) => sleep(ms),
    now: () => Date.now(),
    log: (line) => console.log(`[remote-pi] ${line}`),
    ...overrides,
  };
}
