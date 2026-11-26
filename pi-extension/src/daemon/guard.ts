/**
 * `remote-pi guard` — the Termux stand-in for a service manager (plan/173).
 *
 * On a PC the supervisor is kept alive from OUTSIDE: systemd, launchd or the
 * Task Scheduler restart it, and the plan/168 watchdog covers a wedged one.
 * Termux has none of that. If the supervisor dies (OOM kill, phantom-process
 * killer, a crash), the phone silently leaves the mesh until a human opens
 * Termux — the 2026-11-25 outage. The guard closes exactly that gap and
 * nothing else.
 *
 * It is a SEPARATE light process (it must outlive what it repairs) that every
 * 30 s asks the supervisor for a real `{"op":"status"}` round trip — a
 * listening socket proves nothing, a reply proves the event loop is alive:
 *
 *   - no process, no reply            → start the supervisor
 *   - process there, silent 3 probes  → kill it, then start a new one
 *   - device daemon row `stopped`     → ask the supervisor to `start device`
 *
 * What it deliberately leaves to the layers that already own it:
 *   - crashed / crash-looped children → the supervisor's own backoff
 *     (1 s, 5 s, 30 s, 5 min; it never gives up)
 *   - a WEDGED child                  → the supervisor's ping loop (plan/168)
 *   - a wedged daemon seen from the app → `daemon_control restart` (plan/168)
 * The guard only LOGS those states, once per transition. Restarting on its
 * own would reset the supervisor's backoff and turn a crash loop hot.
 *
 * Restarts are rate limited: supervisor starts back off 0, 15 s, 30 s, 1 min,
 * 2 min, 5 min, 10 min (cap) and the ladder resets after 10 stable minutes;
 * the device daemon gets at most one `start` per minute and three per ten.
 * One log line per transition plus one per action, in `~/.pi/piper/guard.log`.
 *
 * Single instance through a pid file whose pid must be alive AND a guard, so a
 * stale file (pid reused by anything else) never blocks the next start.
 */

import { spawn } from "node:child_process";
import {
  appendFileSync,
  closeSync,
  mkdirSync,
  openSync,
  readFileSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { connect } from "node:net";
import { dirname, join } from "node:path";
import { isTermux } from "../termux.js";
import { supervisorSockPath } from "./sock_path.js";
import { callSupervisor } from "./client.js";
import type { ControlReply, DaemonInfo } from "./control_protocol.js";
import { findNodeBinary, findRemotePiScript, findSupervisorScript, supervisordLogPath } from "./install.js";
import { findSupervisorPids, isGuardArgv, readCmdline, signalPid, DEFAULT_PROC_ROOT, isPidAlive } from "./proc.js";

// ── Tunables ───────────────────────────────────────────────────────────────

/** Owner requirement: the supervisor and the device daemon are checked at
 *  least every 60 s. 30 s halves the outage window for the price of one UDS
 *  round trip per tick. */
export const GUARD_INTERVAL_MS = 30_000;
/** How long a `status` round trip may take before it counts as "no reply". */
export const PROBE_TIMEOUT_MS = 5_000;
/** Consecutive silent probes before a PRESENT supervisor is declared wedged
 *  and killed (same shape as the Windows watchdog's three strikes). */
export const WEDGE_MISSES = 3;
/** Delay before the NEXT supervisor start: attempt 1 at once, then backing
 *  off. The ladder resets once the supervisor has been up for a while. */
export const SUPERVISOR_BACKOFF_MS = [0, 15_000, 30_000, 60_000, 120_000, 300_000, 600_000];
/** Continuous "up" time after which the start backoff is forgiven. */
export const GUARD_STABLE_MS = 10 * 60_000;
/** `start device` rate limit: one per cooldown, at most BUDGET per window. */
export const DEVICE_RESTART_COOLDOWN_MS = 60_000;
export const DEVICE_RESTART_WINDOW_MS = 10 * 60_000;
export const DEVICE_RESTART_BUDGET = 3;
/** SIGTERM → wait → SIGKILL escalation for a wedged supervisor. */
export const TERMINATE_GRACE_MS = 5_000;
/** Before its first tick the guard gives a just-started supervisor this long
 *  to answer: the boot script starts both within a second of each other, and
 *  "no reply yet" is not "down". */
export const STARTUP_GRACE_MS = 20_000;
/** `~/.pi/piper/guard.log` is trimmed to its tail above this size. */
export const GUARD_LOG_MAX_BYTES = 1024 * 1024;
export const GUARD_LOG_KEEP_LINES = 200;

// ── Paths ──────────────────────────────────────────────────────────────────

/** `~/.pi/piper` — honours `REMOTE_PI_HOME` like the rest of the daemon. */
export function piperDir(): string {
  const root = process.env["REMOTE_PI_HOME"] || process.env["HOME"] || "";
  return join(root, ".pi", "piper");
}

export function guardLogPath(): string {
  return join(piperDir(), "guard.log");
}

export function guardPidPath(): string {
  return join(piperDir(), "guard.pid");
}

// ── Log ────────────────────────────────────────────────────────────────────

/** `YYYY-MM-DD HH:MM:SS` in local time — the watchdog's format, so the two
 *  logs read the same on the same day. */
export function formatLogLine(now: number, message: string): string {
  const d = new Date(now);
  const pad = (n: number): string => String(n).padStart(2, "0");
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())} ${message}`
  );
}

/** `15 s`, `1 min`, `10 min` — durations as a human reads them in a log. */
export function humanMs(ms: number): string {
  if (ms < 60_000) return `${Math.round(ms / 1000)} s`;
  const min = Math.round(ms / 60_000);
  return `${min} min`;
}

/** Appends one line; above the cap the file is cut to its last lines so a
 *  guard running for months cannot grow it without bound. */
export function appendGuardLog(path: string, line: string): void {
  try {
    mkdirSync(dirname(path), { recursive: true });
    appendFileSync(path, line.endsWith("\n") ? line : line + "\n");
    if (statSync(path).size > GUARD_LOG_MAX_BYTES) {
      // Keep exactly the newest lines; the trailing empty piece after the
      // final newline is not a line.
      const lines = readFileSync(path, "utf8").split("\n").filter((l) => l.length > 0);
      writeFileSync(path, lines.slice(-GUARD_LOG_KEEP_LINES).join("\n") + "\n");
    }
  } catch {
    // A guard that cannot write its log must still do its job.
  }
}

// ── Single instance ────────────────────────────────────────────────────────

/** True when `pid` is alive AND runs the guard loop (so a pid that was reused
 *  by an unrelated process never passes for a running guard). */
export function guardProcessAlive(pid: number, procRoot: string = DEFAULT_PROC_ROOT): boolean {
  if (!isPidAlive(pid, procRoot)) return false;
  const argv = readCmdline(procRoot, pid);
  return argv !== null && isGuardArgv(argv);
}

/**
 * Takes the pid-file lock for `pid`. "already-running" when a live guard holds
 * it; a stale file (dead pid, or a pid that is no longer a guard) is replaced.
 * Uses `wx` so two guards starting at once cannot both win.
 */
export function acquireGuardLock(
  pidFile: string,
  pid: number,
  isGuardRunning: (pid: number) => boolean = guardProcessAlive,
): "acquired" | "already-running" {
  const write = (): boolean => {
    try {
      mkdirSync(dirname(pidFile), { recursive: true });
      writeFileSync(pidFile, `${pid}\n`, { flag: "wx", mode: 0o600 });
      return true;
    } catch {
      return false;
    }
  };
  if (write()) return "acquired";
  let previous = Number.NaN;
  try {
    previous = Number(readFileSync(pidFile, "utf8").trim());
  } catch {
    /* unreadable → treat as stale below */
  }
  if (Number.isInteger(previous) && previous !== pid && isGuardRunning(previous)) {
    return "already-running";
  }
  try { unlinkSync(pidFile); } catch { /* nothing to remove */ }
  return write() ? "acquired" : "already-running";
}

export function releaseGuardLock(pidFile: string, pid: number): void {
  try {
    if (Number(readFileSync(pidFile, "utf8").trim()) === pid) unlinkSync(pidFile);
  } catch {
    /* already gone */
  }
}

// ── Observation ────────────────────────────────────────────────────────────

/** How the device daemon looks in the supervisor's fleet. */
export type DeviceClass = "running" | "starting" | "crashed" | "stopped" | "missing";

export function classifyDevice(rows: DaemonInfo[]): DeviceClass {
  const row = rows.find((d) => d.id === "device");
  if (!row) return "missing";
  return row.state;
}

/** One `{"op":"status"}` round trip over the control socket. Resolves with the
 *  fleet rows, or null when nobody answers, the reply is malformed or the
 *  supervisor reports an error — every one of those means "not proven alive". */
export function probeStatus(sockPath: string = supervisorSockPath(), timeoutMs = PROBE_TIMEOUT_MS): Promise<DaemonInfo[] | null> {
  return new Promise<DaemonInfo[] | null>((resolve) => {
    let settled = false;
    const done = (rows: DaemonInfo[] | null): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { sock.destroy(); } catch { /* already gone */ }
      resolve(rows);
    };
    const sock = connect({ path: sockPath });
    const timer = setTimeout(() => done(null), timeoutMs);
    let buf = "";
    sock.setEncoding("utf8");
    sock.once("connect", () => {
      try { sock.write(JSON.stringify({ op: "status" }) + "\n"); } catch { done(null); }
    });
    sock.on("data", (chunk: string) => {
      buf += chunk;
      const nl = buf.indexOf("\n");
      if (nl < 0) return;
      try {
        const reply = JSON.parse(buf.slice(0, nl)) as ControlReply<{ daemons: DaemonInfo[] }>;
        done(reply.ok && Array.isArray(reply.data?.daemons) ? reply.data.daemons : null);
      } catch {
        done(null);
      }
    });
    sock.once("error", () => done(null));
    sock.once("close", () => done(null));
  });
}

// ── The decision ───────────────────────────────────────────────────────────

export type GuardAction =
  | { kind: "none" }
  | { kind: "start-supervisor" }
  | { kind: "restart-device" };

/** Everything the tick needs, injectable so the whole state machine is a unit
 *  test with a fake clock and no processes. */
export interface GuardDeps {
  now: () => number;
  /** Fleet rows from the supervisor, or null when it did not prove alive. */
  probe: () => Promise<DaemonInfo[] | null>;
  /** Pids of supervisor processes currently in the process table. */
  supervisorPids: () => number[];
  isAlive: (pid: number) => boolean;
  signal: (pid: number, signal: NodeJS.Signals) => boolean;
  sleep: (ms: number) => Promise<void>;
  /** Starts a detached supervisor. Returns false when it could not be spawned. */
  startSupervisor: () => boolean;
  /** Asks the (live) supervisor to start the device daemon. */
  startDevice: () => Promise<boolean>;
  /** Where the lines go. */
  log: (line: string) => void;
  sockPath: string;
}

/** Mutable memory across ticks. Create with `createGuardState`. */
export interface GuardState {
  /** Consecutive probes without a reply. */
  misses: number;
  supervisor: "up" | "down" | null;
  /** Start of the current continuous "up" / "down" period. */
  upSince: number | null;
  downSince: number | null;
  /** Starts of the current outage series; also the backoff step — after the
   *  k-th start the next one waits SUPERVISOR_BACKOFF_MS[k]. */
  starts: number;
  /** Earliest time the next supervisor start is allowed. */
  nextStartAt: number;
  /** Last observed device class — the "from" of a transition line. */
  device: DeviceClass | null;
  /** Timestamps of recent `start device` requests (rate limit window). */
  deviceStarts: number[];
  nextDeviceStartAt: number;
  /** The budget line is written once per exhaustion, not per tick. */
  deviceBudgetLogged: boolean;
  /** Set when the supervisor script was missing, so it is logged once. */
  scriptMissingLogged: boolean;
}

export function createGuardState(): GuardState {
  return {
    misses: 0,
    supervisor: null,
    upSince: null,
    downSince: null,
    starts: 0,
    nextStartAt: 0,
    device: null,
    deviceStarts: [],
    nextDeviceStartAt: 0,
    deviceBudgetLogged: false,
    scriptMissingLogged: false,
  };
}

const DEVICE_HINTS: Record<DeviceClass, string> = {
  running: "running",
  starting: "starting",
  crashed: "crashed (the supervisor restarts it with backoff — not the guard's job)",
  stopped: "stopped (no restart is scheduled — the guard starts it)",
  missing: "no fleet row — a registry entry may cover the home cwd (remote-pi doctor)",
};

/** `device daemon: running → crashed (…)`; the first observation has no "from". */
export function deviceTransitionLine(from: DeviceClass | null, to: DeviceClass): string {
  const target = DEVICE_HINTS[to];
  return from === null
    ? `device daemon: ${target}`
    : `device daemon: ${from} → ${target}`;
}

/** SIGTERM, then SIGKILL if the process outlives the grace period. Polls a
 *  fixed number of times (200 ms apart) rather than reading the wall clock, so
 *  a test with an instant `sleep` never spins for real seconds. */
export async function terminatePid(
  pid: number,
  deps: Pick<GuardDeps, "signal" | "isAlive" | "sleep">,
  graceMs = TERMINATE_GRACE_MS,
): Promise<void> {
  if (!deps.signal(pid, "SIGTERM")) return;
  const polls = Math.ceil(graceMs / 200);
  for (let i = 0; i < polls && deps.isAlive(pid); i++) await deps.sleep(200);
  if (deps.isAlive(pid)) deps.signal(pid, "SIGKILL");
}

/**
 * One guard pass: probe, log every transition, repair what is the guard's to
 * repair. Returns the action taken (for `guard once` and the tests).
 */
export async function tick(state: GuardState, deps: GuardDeps): Promise<{ action: GuardAction; lines: string[] }> {
  const lines: string[] = [];
  const log = (message: string): void => {
    const line = formatLogLine(deps.now(), message);
    lines.push(line);
    deps.log(line);
  };
  const rows = await deps.probe();

  // ── supervisor ──
  if (rows === null) {
    state.misses += 1;
    const pids = deps.supervisorPids();
    if (state.supervisor !== "down") {
      state.supervisor = "down";
      state.upSince = null;
      state.downSince = deps.now();
      log(
        pids.length > 0
          ? `supervisor: no reply (pid ${pids.join(", ")} still present; restarted after ${WEDGE_MISSES} silent probes)`
          : `supervisor: down (no process, no reply on ${deps.sockPath})`,
      );
    }
    let killed = false;
    if (pids.length > 0) {
      if (state.misses < WEDGE_MISSES) return { action: { kind: "none" }, lines };
      log(`supervisor: pid ${pids.join(", ")} alive but silent for ${state.misses} probes → kill`);
      for (const pid of pids) await terminatePid(pid, deps);
      // The replacement gets its own three probes before it may be called
      // wedged, and it starts now: the kill was the repair, not a backoff step.
      killed = true;
      state.misses = 0;
    }
    if (!killed && deps.now() < state.nextStartAt) return { action: { kind: "none" }, lines };
    const started = deps.startSupervisor();
    state.misses = 0;
    // After start #k the next attempt waits SUPERVISOR_BACKOFF_MS[k]: 15 s
    // after the first, 30 s after the second, … capped at 10 min.
    const wait = SUPERVISOR_BACKOFF_MS[Math.min(state.starts + 1, SUPERVISOR_BACKOFF_MS.length - 1)]!;
    state.starts += 1;
    state.nextStartAt = deps.now() + wait;
    if (started) {
      log(`supervisor: start #${state.starts} (next attempt in ${humanMs(wait)} if it does not answer)`);
      return { action: { kind: "start-supervisor" }, lines };
    }
    if (!state.scriptMissingLogged) {
      state.scriptMissingLogged = true;
      log(`supervisor: could not start (script or node missing — reinstall remote-pi); retrying in ${humanMs(wait)}`);
    }
    return { action: { kind: "none" }, lines };
  }

  const now = deps.now();
  if (state.supervisor === "down") {
    log(`supervisor: back up after ${humanMs(Math.max(0, now - (state.downSince ?? now)))} (${rows.length} fleet row(s))`);
  } else if (state.supervisor === null) {
    // First observation: record where we started from, once.
    log(`supervisor: up (${rows.length} fleet row(s))`);
  }
  if (state.supervisor !== "up") {
    state.supervisor = "up";
    state.upSince = now;
  } else if (state.starts > 0 && now - (state.upSince ?? now) >= GUARD_STABLE_MS) {
    // Stable long enough: forgive the failed starts of the last outage.
    state.nextStartAt = 0;
    state.starts = 0;
    state.scriptMissingLogged = false;
  }
  state.misses = 0;
  state.downSince = null;

  // ── device daemon ──
  const device = classifyDevice(rows);
  if (device !== state.device) {
    log(deviceTransitionLine(state.device, device));
    state.device = device;
    if (device === "running") state.deviceBudgetLogged = false;
  }
  if (device === "stopped") {
    state.deviceStarts = state.deviceStarts.filter((t) => now - t < DEVICE_RESTART_WINDOW_MS);
    if (state.deviceStarts.length >= DEVICE_RESTART_BUDGET) {
      if (!state.deviceBudgetLogged) {
        state.deviceBudgetLogged = true;
        log(`device daemon: ${state.deviceStarts.length} starts in ${humanMs(DEVICE_RESTART_WINDOW_MS)} did not keep it up — leaving it alone (remote-pi doctor)`);
      }
    } else if (now >= state.nextDeviceStartAt) {
      state.deviceStarts.push(now);
      state.nextDeviceStartAt = now + DEVICE_RESTART_COOLDOWN_MS;
      const started = await deps.startDevice();
      log(started ? "device daemon: stopped → start requested" : "device daemon: stopped → start refused by the supervisor");
      return { action: { kind: "restart-device" }, lines };
    }
  }
  return { action: { kind: "none" }, lines };
}

// ── Production wiring ──────────────────────────────────────────────────────

/** Starts the supervisor detached, output appended to `supervisord.log` —
 *  the same file the boot script and the service managers use. */
export function spawnSupervisorDetached(): boolean {
  const script = findSupervisorScript();
  const node = findNodeBinary();
  if (!script || !node) return false;
  let fd: number | null = null;
  try {
    mkdirSync(dirname(supervisordLogPath()), { recursive: true });
    fd = openSync(supervisordLogPath(), "a");
    const child = spawn(node, [script], {
      detached: true,
      // The parent's stdin would tie the supervisor to this process' lifetime.
      stdio: ["ignore", fd, fd],
      env: { ...process.env, HOME: process.env["HOME"] || process.env["REMOTE_PI_HOME"] },
    });
    child.unref();
    return true;
  } catch {
    return false;
  } finally {
    if (fd !== null) {
      // The child inherited the descriptor; our copy is no longer needed.
      try { closeSync(fd); } catch { /* best-effort */ }
    }
  }
}

/** Healthy = the supervisor answered and the device daemon is up or coming up. */
export function fleetHealthy(rows: DaemonInfo[] | null): boolean {
  if (rows === null) return false;
  const device = classifyDevice(rows);
  return device === "running" || device === "starting";
}

/** Before the FIRST tick: re-probe until the supervisor answers or the grace
 *  period is over. Silent by design — nothing happened worth a log line. */
export async function settleBeforeFirstTick(
  deps: Pick<GuardDeps, "probe" | "sleep">,
  graceMs = STARTUP_GRACE_MS,
  stepMs = 5_000,
): Promise<boolean> {
  for (let waited = 0; ; waited += stepMs) {
    if ((await deps.probe()) !== null) return true;
    if (waited + stepMs > graceMs) return false;
    await deps.sleep(stepMs);
  }
}

export function defaultGuardDeps(overrides: Partial<GuardDeps> = {}): GuardDeps {
  return {
    now: () => Date.now(),
    probe: () => probeStatus(),
    supervisorPids: () => findSupervisorPids(),
    isAlive: (pid) => isPidAlive(pid),
    signal: (pid, sig) => signalPid(pid, sig),
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    startSupervisor: spawnSupervisorDetached,
    startDevice: async () => {
      try {
        const reply = await callSupervisor({ op: "start", id: "device" });
        return reply.started || reply.state === "running";
      } catch {
        return false;
      }
    },
    log: (line) => appendGuardLog(guardLogPath(), line),
    sockPath: supervisorSockPath(),
    ...overrides,
  };
}

export interface GuardLoop {
  /** Stops the loop and resolves once no tick is running. */
  stop: () => Promise<void>;
  /** Resolves when the loop has stopped by itself (signal). */
  done: Promise<void>;
}

/**
 * The foreground loop: one tick at once, then every `intervalMs`. Logs its own
 * start and stop lines so `guard.log` shows every guard lifetime.
 */
export function runGuardLoop(opts: { intervalMs?: number; deps?: Partial<GuardDeps>; onSignal?: () => void } = {}): GuardLoop {
  const deps = defaultGuardDeps(opts.deps);
  const interval = opts.intervalMs ?? GUARD_INTERVAL_MS;
  const state = createGuardState();
  let running = true;
  let inFlight: Promise<void> | null = null;
  let resolveDone: () => void = () => undefined;
  const done = new Promise<void>((resolve) => { resolveDone = resolve; });

  const runTick = async (): Promise<void> => {
    if (!running) return;
    try {
      await tick(state, deps);
    } catch (e) {
      deps.log(formatLogLine(deps.now(), `guard: tick failed: ${String(e)}`));
    }
  };

  const stop = async (): Promise<void> => {
    if (!running) return;
    running = false;
    clearInterval(timer);
    if (inFlight) await inFlight;
    deps.log(formatLogLine(deps.now(), `guard stopped (pid ${process.pid})`));
    releaseGuardLock(guardPidPath(), process.pid);
    resolveDone();
  };

  deps.log(formatLogLine(deps.now(), `guard started (pid ${process.pid}, every ${humanMs(interval)})`));
  // The first pass waits for a supervisor that is merely still booting.
  inFlight = (async (): Promise<void> => {
    await settleBeforeFirstTick(deps);
    if (running) await runTick();
  })().finally(() => { inFlight = null; });
  const timer = setInterval(() => {
    if (inFlight) return; // a slow tick is never stacked on another
    inFlight = runTick().finally(() => { inFlight = null; });
  }, interval);

  const onSignal = (): void => {
    void stop().finally(() => opts.onSignal?.());
  };
  process.once("SIGTERM", onSignal);
  process.once("SIGINT", onSignal);
  return { stop, done };
}

// ── CLI: `remote-pi guard <run|start|status|stop|once>` ────────────────────

export function guardUsage(): string {
  return [
    "Usage: remote-pi guard <run|start|status|stop|once>",
    "",
    "  run     the loop in the foreground (one instance, pid file locked)",
    "  start   start the loop detached; no-op when it already runs",
    "  status  guard, supervisor and device daemon in three lines",
    "  stop    stop the loop (the supervisor and its daemons keep running)",
    "  once    one check now; exit 0 when healthy or repaired, 1 otherwise",
    "",
    "On a PC the service manager restarts the supervisor; the guard is for Termux.",
  ].join("\n");
}

/** Reads the pid file; the pid only when it is alive AND a guard. */
export function runningGuardPid(pidFile: string = guardPidPath()): number | null {
  let pid = Number.NaN;
  try { pid = Number(readFileSync(pidFile, "utf8").trim()); } catch { return null; }
  return Number.isInteger(pid) && guardProcessAlive(pid) ? pid : null;
}

/** Starts the loop detached and waits briefly for its pid file. */
export async function guardStart(deps: { spawnFn?: typeof spawn; sleep: (ms: number) => Promise<void>; runningPid: () => number | null; logPath?: string } = { sleep: (ms) => new Promise((r) => setTimeout(r, ms)), runningPid: runningGuardPid }): Promise<{ ok: boolean; message: string }> {
  const already = deps.runningPid();
  if (already !== null) return { ok: true, message: `guard already running (pid ${already})` };
  const script = findRemotePiScript();
  const node = findNodeBinary();
  const logPath = deps.logPath ?? guardLogPath();
  let fd: number | null = null;
  try {
    mkdirSync(dirname(logPath), { recursive: true });
    fd = openSync(logPath, "a");
    const child = (deps.spawnFn ?? spawn)(node, [script, "guard", "run"], {
      detached: true,
      stdio: ["ignore", fd, fd],
      env: process.env,
    });
    child.unref();
  } catch (e) {
    return { ok: false, message: `guard could not be started: ${String(e)}` };
  } finally {
    if (fd !== null) {
      try { closeSync(fd); } catch { /* best-effort */ }
    }
  }
  // The loop takes the lock within a second or two (node boot); give it a
  // moment so the answer is real instead of "probably started".
  for (let i = 0; i < 20; i++) {
    await deps.sleep(150);
    const pid = deps.runningPid();
    if (pid !== null) return { ok: true, message: `guard started (pid ${pid})` };
  }
  return { ok: false, message: `guard did not take its lock — see ${logPath}` };
}

/** SIGTERM to the running guard; resolves when it is gone (or never was). */
export async function guardStop(deps: { runningPid: () => number | null; signal: (pid: number, sig: NodeJS.Signals) => boolean; isAlive: (pid: number) => boolean; sleep: (ms: number) => Promise<void>; pidFile?: string } = { runningPid: runningGuardPid, signal: signalPid, isAlive: isPidAlive, sleep: (ms) => new Promise((r) => setTimeout(r, ms)) }): Promise<{ ok: boolean; message: string }> {
  const pid = deps.runningPid();
  if (pid === null) return { ok: true, message: "guard is not running" };
  if (!deps.signal(pid, "SIGTERM")) return { ok: true, message: "guard is not running" };
  for (let i = 0; i < 40 && deps.isAlive(pid); i++) await deps.sleep(100);
  if (deps.isAlive(pid)) {
    deps.signal(pid, "SIGKILL");
    await deps.sleep(100);
  }
  return { ok: true, message: `guard stopped (pid ${pid})` };
}

/** Three lines, same vocabulary as the log. */
export async function guardStatus(
  deps: {
    runningPid: () => number | null;
    probe: () => Promise<DaemonInfo[] | null>;
    sockPath: string;
  } = { runningPid: runningGuardPid, probe: () => probeStatus(), sockPath: supervisorSockPath() },
): Promise<string[]> {
  const pid = deps.runningPid();
  const rows = await deps.probe();
  const device = rows === null ? null : classifyDevice(rows);
  return [
    `guard:      ${pid === null ? "not running" : `running (pid ${pid})`} — ${guardLogPath()}`,
    `supervisor: ${rows === null ? `no reply on ${deps.sockPath}` : `up (${rows.length} fleet row(s))`}`,
    `device:     ${device === null ? "unknown (supervisor silent)" : DEVICE_HINTS[device]}`,
  ];
}

/** One check now, in the foreground. Takes no lock: when a guard loop runs it
 *  owns the repairs and this only REPORTS (two processes must never fight
 *  over one supervisor); otherwise it performs one tick — repairs included,
 *  logged in the same file — which is what a cronie entry would call. */
export async function guardOnce(
  deps: Partial<GuardDeps> = {},
  opts: { guardRunning: boolean; status?: () => Promise<string[]> } = { guardRunning: runningGuardPid() !== null },
): Promise<{ healthy: boolean; lines: string[] }> {
  const full = defaultGuardDeps(deps);
  if (opts.guardRunning) {
    const rows = await full.probe();
    return { healthy: fleetHealthy(rows), lines: await (opts.status ?? guardStatus)() };
  }
  const result = await tick(createGuardState(), full);
  // Give a supervisor started just now a moment to bind before judging.
  if (result.action.kind === "start-supervisor") await full.sleep(3_000);
  return { healthy: fleetHealthy(await full.probe()), lines: result.lines };
}

/** `remote-pi guard …` entry point (reached from the thin CLI path). Returns
 *  the process exit code. */
export async function runGuardCli(
  argv: string[],
  io: { out: (line: string) => void; err: (line: string) => void } = {
    out: (l) => console.log(l),
    err: (l) => console.error(l),
  },
): Promise<number> {
  const sub = argv[3] ?? "";
  const termuxOnly = (what: string): number => {
    io.err(`[remote-pi] guard ${what} belongs on a Termux (Android) host — on a PC the service manager restarts the supervisor.`);
    return 1;
  };
  switch (sub) {
    case "run": {
      if (!isTermux()) return termuxOnly("run");
      const pidFile = guardPidPath();
      if (acquireGuardLock(pidFile, process.pid) === "already-running") {
        io.err(`[remote-pi] guard already running (pid ${runningGuardPid() ?? "?"})`);
        return 0;
      }
      const loop = runGuardLoop({ onSignal: () => process.exit(0) });
      // If the pid file vanished and a second guard took the lock, this one
      // leaves; if the file merely vanished, the lock is retaken silently.
      const watch = setInterval(() => {
        if (runningGuardPid() === process.pid) return;
        if (acquireGuardLock(pidFile, process.pid) === "already-running") {
          void loop.stop().then(() => process.exit(0));
        }
      }, 5 * GUARD_INTERVAL_MS);
      watch.unref?.();
      await loop.done;
      return 0;
    }
    case "start": {
      if (!isTermux()) return termuxOnly("start");
      const r = await guardStart();
      (r.ok ? io.out : io.err)(`[remote-pi] ${r.message}`);
      return r.ok ? 0 : 1;
    }
    case "status": {
      for (const line of await guardStatus()) io.out(`[remote-pi] ${line}`);
      return 0;
    }
    case "stop": {
      const r = await guardStop();
      io.out(`[remote-pi] ${r.message}`);
      return 0;
    }
    case "once": {
      const r = await guardOnce();
      for (const line of r.lines) io.out(line);
      io.out(`[remote-pi] guard: ${r.healthy ? "healthy" : "NOT healthy"}`);
      return r.healthy ? 0 : 1;
    }
    default:
      io.err(`[remote-pi] ${guardUsage()}`);
      return 1;
  }
}

