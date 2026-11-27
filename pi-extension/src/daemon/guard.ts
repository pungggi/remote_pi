/**
 * `remote-pi guard` — the Termux stand-in for a service manager (plan/173).
 *
 * On a PC the supervisor is kept alive from OUTSIDE: systemd, launchd or the
 * Task Scheduler restart it, and the plan/168 watchdog covers a wedged one.
 * Termux has none of that, and no cron either. If the supervisor dies (OOM
 * kill, phantom-process killer, a crash), the phone silently leaves the mesh
 * until a human opens Termux — the 2026-11-25 outage. The guard closes
 * exactly that gap and nothing else.
 *
 * It is a SEPARATE light process (it must outlive what it repairs) that makes
 * a real `{"op":"status"}` round trip on the control socket every 30 s — a
 * listening socket proves nothing, a reply proves the event loop is alive —
 * and acts on three things (owner decision of 2026-11-26, every number a
 * setting, see `GuardConfig`):
 *
 *   - no process, no reply            → start the supervisor
 *   - process there, silent for 2 probes → kill it, then start a new one
 *   - supervisor older than 24 h      → one graceful restart (age restart)
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
 * Restarts are rate limited so no setting can turn the guard into a loop:
 *   - at most `RESTART_RATE_MAX` supervisor starts in any `RESTART_RATE_WINDOW_S`
 *     (a start that the limit would refuse simply waits, including the kill
 *     of a wedged supervisor: nothing is killed before its replacement may
 *     start);
 *   - after the k-th start of an outage the next one waits `START_BACKOFF_S[k]`;
 *     the ladder is forgiven after 10 stable minutes.
 * One log line per transition plus one per action, in `~/.pi/piper/guard.log`.
 *
 * Single instance through a pid file whose pid must be alive AND a guard. The
 * interim shell guard the phone ran before this one existed shares that pid
 * file, so `guard run` retires it first: stop it by its pid, rename its
 * script, then take the lock. Two guards never fight.
 *
 * A restart sequence (stop old, start new) is marked in `guard.restarting`
 * for the time it runs: `guard stop` sees the marker and waits instead of
 * sending SIGKILL into the middle of it.
 */

import { spawn } from "node:child_process";
import {
  appendFileSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { connect } from "node:net";
import { dirname, join } from "node:path";
import { isTermux, fileStamp } from "../termux.js";
import { supervisorSockPath } from "./sock_path.js";
import { callSupervisor } from "./client.js";
import type { ControlReply, DaemonInfo } from "./control_protocol.js";
import { findNodeBinary, findRemotePiScript, findSupervisorScript, supervisordLogPath } from "./install.js";
import {
  DEFAULT_PROC_ROOT,
  findGuardPids,
  findSupervisorPids,
  isGuardArgv,
  isInterimGuardArgv,
  isPidAlive,
  processStartMs,
  readCmdline,
  signalPid,
} from "./proc.js";

// ── Tunables ───────────────────────────────────────────────────────────────

/** How long a `status` round trip may take before it counts as "no reply". */
export const PROBE_TIMEOUT_MS = 5_000;
/** Continuous "up" time after which the start backoff is forgiven. */
export const GUARD_STABLE_MS = 10 * 60_000;
/** `start device` rate limit of its own: one per cooldown, at most BUDGET per window. */
export const DEVICE_RESTART_COOLDOWN_MS = 60_000;
export const DEVICE_RESTART_WINDOW_MS = 10 * 60_000;
export const DEVICE_RESTART_BUDGET = 3;
/** Before its first tick the guard gives a just-started supervisor this long
 *  to answer: the boot script starts both within a second of each other, and
 *  "no reply yet" is not "down". */
export const STARTUP_GRACE_MS = 20_000;
/** `~/.pi/piper/guard.log` is trimmed to its tail above this size. */
export const GUARD_LOG_MAX_BYTES = 1024 * 1024;
export const GUARD_LOG_KEEP_LINES = 200;

/** Every number the owner asked to be configurable. Defaults are the owner's
 *  words: check every 30 s, restart after two failed checks, one graceful
 *  restart after 24 h of uptime, with a restart-rate limit. */
export interface GuardConfig {
  /** Interval between health checks. */
  intervalMs: number;
  /** Consecutive silent probes of a PRESENT supervisor before it is declared
   *  wedged and restarted. A MISSING supervisor is started at once. */
  failsBeforeRestart: number;
  /** Graceful restart once the supervisor's uptime exceeds this. 0 = off. */
  maxAgeMs: number;
  /** At most this many supervisor starts inside `rateWindowMs`. 0 = no limit. */
  rateMax: number;
  rateWindowMs: number;
  /** After the k-th start of an outage series (1-based) the next start waits
   *  `startBackoffMs[k - 1]`; the last value repeats. */
  startBackoffMs: number[];
  /** SIGINT / SIGTERM to SIGKILL escalation for a process that will not go. */
  stopGraceMs: number;
}

export const DEFAULT_GUARD_CONFIG: Readonly<GuardConfig> = {
  intervalMs: 30_000,
  failsBeforeRestart: 2,
  maxAgeMs: 24 * 60 * 60_000,
  rateMax: 3,
  rateWindowMs: 10 * 60_000,
  startBackoffMs: [15_000, 30_000, 60_000, 120_000, 300_000, 600_000],
  stopGraceMs: 10_000,
};

/** Setting names as used in `guard.conf` and, with the prefix
 *  `REMOTE_PI_GUARD_`, in the environment. */
export const GUARD_CONF_PREFIX = "REMOTE_PI_GUARD_";

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

/** The interim shell guard's script, pid file and this guard's config share
 *  the directory; the config file name is deliberately the same the interim
 *  guard used, so its settings carry over where the names match. */
export function guardConfPath(): string {
  return join(piperDir(), "guard.conf");
}

export function interimGuardScriptPath(): string {
  return join(piperDir(), "piper-guard.sh");
}

/** Written while a restart sequence runs; `guard stop` waits on it. */
export function guardRestartMarkerPath(): string {
  return join(piperDir(), "guard.restarting");
}

// ── Log ────────────────────────────────────────────────────────────────────

/** `YYYY-MM-DD HH:MM:SS` in local time — the watchdog's format, so the two
 *  logs read the same on the same day. */
export function formatLogLine(now: number, message: string): string {
  const d = new Date(now);
  const sec = String(d.getSeconds()).padStart(2, "0");
  return `${calendarDate(now)} ${timeOfDay(now)}:${sec} ${message}`;
}

function calendarDate(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number): string => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** `HH:MM` in local time, for "until" hints in log lines. */
export function timeOfDay(ms: number): string {
  const d = new Date(ms);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

/** `15 s`, `90 min`, `24 h`, `24 h 30 min` — durations as a person reads them. */
export function humanMs(ms: number): string {
  if (ms < 60_000) return `${Math.round(ms / 1000)} s`;
  const totalMin = Math.round(ms / 60_000);
  if (totalMin < 60) return `${totalMin} min`;
  const h = Math.floor(totalMin / 60);
  const min = totalMin % 60;
  return min === 0 ? `${h} h` : `${h} h ${min} min`;
}

/** The effective settings in one line, logged at every start. */
export function describeGuardConfig(cfg: GuardConfig): string {
  const backoff = cfg.startBackoffMs.length > 0 ? cfg.startBackoffMs.map(humanMs).join(", ") : "none";
  return [
    `check every ${humanMs(cfg.intervalMs)}`,
    `restart after ${cfg.failsBeforeRestart} silent ${cfg.failsBeforeRestart === 1 ? "probe" : "probes"}`,
    cfg.maxAgeMs > 0 ? `age restart above ${humanMs(cfg.maxAgeMs)}` : "age restart off",
    cfg.rateMax > 0 ? `at most ${cfg.rateMax} start(s) per ${humanMs(cfg.rateWindowMs)}` : "no start limit",
    `start backoff ${backoff}`,
    `stop grace ${humanMs(cfg.stopGraceMs)}`,
  ].join("; ");
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

// ── Configuration ──────────────────────────────────────────────────────────

/** `KEY=VALUE` lines with `#` comments, an optional `export`, single or
 *  double quotes around the value, and an inline `# comment` behind the value
 *  — the shape a shell `source`s, because the interim guard's `guard.conf`
 *  was written for bash, which reads `KEY=30   # why` as `30`. */
export function parseConf(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const m = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line);
    if (!m) continue;
    let value = stripInlineComment(m[2]!).trim();
    if ((value.startsWith('"') && value.endsWith('"') && value.length >= 2)
      || (value.startsWith("'") && value.endsWith("'") && value.length >= 2)) {
      value = value.slice(1, -1);
    }
    out[m[1]!] = value;
  }
  return out;
}

/** Cuts an inline comment off a value the way a shell does: a `#` outside
 *  quotes that begins a word (the start of the value, or right after
 *  whitespace). A `#` glued to the value (`15,30#x`) and one inside quotes are
 *  characters of the value; an unbalanced quote runs to the end of the line. */
export function stripInlineComment(value: string): string {
  let quote: string | null = null;
  for (let i = 0; i < value.length; i++) {
    const c = value[i];
    if (quote !== null) {
      if (c === quote) quote = null;
    } else if (c === '"' || c === "'") {
      quote = c;
    } else if (c === "#" && (i === 0 || /\s/.test(value[i - 1]!))) {
      return value.slice(0, i);
    }
  }
  return value;
}

function seconds(value: string): number | null {
  if (!/^\d+(?:\.\d+)?$/.test(value.trim())) return null;
  const n = Number(value);
  return Number.isFinite(n) ? Math.round(n * 1000) : null;
}

function listOfSeconds(value: string): number[] | null {
  const parts = value.split(",").map((p) => p.trim()).filter((p) => p.length > 0);
  if (parts.length === 0) return null;
  const out: number[] = [];
  for (const part of parts) {
    const ms = seconds(part);
    if (ms === null) return null;
    out.push(ms);
  }
  return out;
}

/** Setting names of the INTERIM shell guard that mean the same as ours. The
 *  phone's `~/.pi/piper/guard.conf` is the interim file, so these keep it
 *  configuring the new guard instead of being reported as unknown. They only
 *  feed the canonical setting (read-only): when a file holds both names, the
 *  canonical one wins. */
export const GUARD_CONF_ALIASES: Readonly<Record<string, string>> = {
  CHECK_INTERVAL_S: "INTERVAL_S",
  RESTART_GRACE_S: "STOP_GRACE_S",
  RATE_MAX_RESTARTS: "RESTART_RATE_MAX",
  RATE_WINDOW_S: "RESTART_RATE_WINDOW_S",
};

/** Keys of the interim file that have no counterpart here, with the hint
 *  that replaces them. Reported once at start, like any ignored setting. */
export const SUPERSEDED_GUARD_KEYS: Readonly<Record<string, string>> = {
  RATE_BACKOFF_S: "replaced by START_BACKOFF_S (the backoff between starts)",
  RESTART_BACKOFF_S: "replaced by START_BACKOFF_S (the backoff between starts)",
};

/** The canonical name of a setting: itself, or what an interim alias maps to. */
export function canonicalGuardKey(key: string): string {
  return GUARD_CONF_ALIASES[key] ?? key;
}

/**
 * Applies one `KEY=VALUE` setting (canonical name or interim alias).
 * Returns false when the key is unknown or superseded, or the value is not
 * usable; the caller reports those once at start, so a typo in `guard.conf`
 * never silently disables a limit.
 */
export function applyGuardSetting(cfg: GuardConfig, key: string, value: string): boolean {
  switch (canonicalGuardKey(key)) {
    case "INTERVAL_S": {
      const ms = seconds(value);
      if (ms === null || ms < 1000) return false;
      cfg.intervalMs = ms;
      return true;
    }
    case "FAILS_BEFORE_RESTART": {
      if (!/^\d+$/.test(value.trim())) return false;
      cfg.failsBeforeRestart = Math.max(1, Number(value));
      return true;
    }
    case "MAX_AGE_S": {
      const ms = seconds(value);
      if (ms === null) return false;
      cfg.maxAgeMs = ms;
      return true;
    }
    case "RESTART_RATE_MAX": {
      if (!/^\d+$/.test(value.trim())) return false;
      cfg.rateMax = Number(value);
      return true;
    }
    case "RESTART_RATE_WINDOW_S": {
      const ms = seconds(value);
      if (ms === null || ms < 1000) return false;
      cfg.rateWindowMs = ms;
      return true;
    }
    case "START_BACKOFF_S": {
      const list = listOfSeconds(value);
      if (list === null) return false;
      cfg.startBackoffMs = list;
      return true;
    }
    case "STOP_GRACE_S": {
      const ms = seconds(value);
      if (ms === null) return false;
      cfg.stopGraceMs = ms;
      return true;
    }
    default:
      return false;
  }
}

export interface GuardConfigLoad {
  config: GuardConfig;
  /** Where a value actually changed: `guard.conf`, `env`. */
  sources: string[];
  /** Keys that were ignored (unknown name or bad value), with the reason. */
  ignored: string[];
}

/**
 * Defaults, then `guard.conf`, then the environment. The environment wins on
 * purpose: an override given for one test run must not be silently undone by
 * a file that forgotten settings live in (the interim guard got that wrong).
 * Inside one source the interim aliases are applied before the canonical
 * names, so a file that holds both takes the canonical value.
 */
export function loadGuardConfig(
  env: NodeJS.ProcessEnv = process.env,
  confText: string | null = readGuardConfText(),
): GuardConfigLoad {
  const config: GuardConfig = { ...DEFAULT_GUARD_CONFIG, startBackoffMs: [...DEFAULT_GUARD_CONFIG.startBackoffMs] };
  const sources: string[] = [];
  const ignored: string[] = [];
  if (confText !== null) {
    let changed = false;
    for (const [key, value] of orderedEntries(parseConf(confText))) {
      if (applyGuardSetting(config, key, value)) changed = true;
      else ignored.push(`guard.conf: ${key} (${ignoredReason(key)})`);
    }
    if (changed) sources.push("guard.conf");
  }
  const envEntries: Array<[string, string]> = [];
  for (const [name, value] of Object.entries(env)) {
    if (name.startsWith(GUARD_CONF_PREFIX) && value !== undefined) {
      envEntries.push([name.slice(GUARD_CONF_PREFIX.length), value]);
    }
  }
  for (const [key, value] of orderedEntries(envEntries)) {
    if (applyGuardSetting(config, key, value)) sources.push(`env:${GUARD_CONF_PREFIX}${key}`);
    else ignored.push(`${GUARD_CONF_PREFIX}${key} (${ignoredReason(key)})`);  }
  return { config, sources, ignored };
}

/** Why a key was not applied: superseded by a new setting, or simply unknown
 *  (or its value unusable). The reason only; the caller names the key. */
function ignoredReason(key: string): string {
  return SUPERSEDED_GUARD_KEYS[key] ?? "unknown setting or bad value";
}

/** `KEY=VALUE` pairs with the interim aliases first and the canonical names
 *  last, so that applying them in order lets a canonical name win. */
function orderedEntries(entries: Record<string, string> | Array<[string, string]>): Array<[string, string]> {
  const list = Array.isArray(entries) ? entries : Object.entries(entries);
  const rank = ([key]: [string, string]): number => (key in GUARD_CONF_ALIASES ? 0 : 1);
  return [...list].sort((a, b) => rank(a) - rank(b));
}

export function readGuardConfText(): string | null {
  try {
    return existsSync(guardConfPath()) ? readFileSync(guardConfPath(), "utf8") : null;
  } catch {
    return null;
  }
}

// ── Single instance and the interim guard ──────────────────────────────────

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

export interface InterimRetireDeps {
  /** Pid named by the shared pid file, or null. */
  pidFilePid: () => number | null;
  isInterim: (pid: number) => boolean;
  signal: (pid: number, signal: NodeJS.Signals) => boolean;
  isAlive: (pid: number) => boolean;
  sleep: (ms: number) => Promise<void>;
  /** Renames the interim script so nothing can start it again. */
  rename: (from: string, to: string) => boolean;
  now: () => number;
  log: (line: string) => void;
}

/**
 * Stops the interim shell guard (`piper-guard.sh`) the phone ran before this
 * guard existed, and puts its script out of reach. It shares `guard.pid` and
 * `guard.log` with this guard, so a running interim instance must be gone
 * before `guard run` takes the lock. A pid file that names anything else
 * (dead pid, another process) is left for the lock to replace. Returns the
 * log lines; empty when there was nothing to retire.
 */
export async function retireInterimGuard(
  deps: InterimRetireDeps,
  opts: { pidFile?: string; script?: string; graceMs?: number } = {},
): Promise<string[]> {
  const lines: string[] = [];
  const log = (message: string): void => {
    const line = formatLogLine(deps.now(), message);
    lines.push(line);
    deps.log(line);
  };
  const pid = deps.pidFilePid();
  if (pid !== null && deps.isInterim(pid) && deps.isAlive(pid)) {
    log(`interim guard: stopping pid ${pid} (remote-pi guard takes over)`);
    deps.signal(pid, "SIGTERM");
    const polls = Math.ceil((opts.graceMs ?? DEFAULT_GUARD_CONFIG.stopGraceMs) / 200);
    for (let i = 0; i < polls && deps.isAlive(pid); i++) await deps.sleep(200);
    if (deps.isAlive(pid)) {
      deps.signal(pid, "SIGKILL");
      for (let i = 0; i < 10 && deps.isAlive(pid); i++) await deps.sleep(100);
    }
    log(deps.isAlive(pid) ? `interim guard: pid ${pid} did not exit after SIGKILL` : `interim guard: stopped (pid ${pid})`);
  }
  const script = opts.script ?? interimGuardScriptPath();
  const backup = `${script}.replaced-${fileStamp(deps.now())}`;
  if (deps.rename(script, backup)) {
    log(`interim guard: script renamed to ${backup} (remote-pi guard run is the only guard now)`);
  }
  return lines;
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
 *  supervisor reports an error — every one of those means "not proven alive".
 *  (Never the exit code of `remote-pi daemon status`: that used to be 0 even
 *  on a reply timeout.) */
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
  | { kind: "age-restart" }
  | { kind: "restart-device" };

/** Everything the tick needs, injectable so the whole state machine is a unit
 *  test with a fake clock and no processes. */
export interface GuardDeps {
  config: GuardConfig;
  now: () => number;
  /** Fleet rows from the supervisor, or null when it did not prove alive. */
  probe: () => Promise<DaemonInfo[] | null>;
  /** Pids of supervisor processes currently in the process table. */
  supervisorPids: () => number[];
  /** Age of a process in ms since it started, or null when unknown. */
  processAge: (pid: number) => number | null;
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
  /** Restart-in-progress marker: set for the time a stop-and-start runs. */
  marker: { set: (text: string) => void; clear: () => void };
}

/** Mutable memory across ticks. Create with `createGuardState`. */
export interface GuardState {
  /** Consecutive probes without a reply. */
  misses: number;
  supervisor: "up" | "down" | null;
  /** Start of the current continuous "up" period (a lower bound for the age). */
  upSince: number | null;
  downSince: number | null;
  /** Supervisor starts inside the rate window (epoch ms). */
  startTimes: number[];
  /** Starts of the current outage series; the k-th start makes the next one
   *  wait `startBackoffMs[k - 1]`. */
  backoffIndex: number;
  /** Earliest time the next supervisor start is allowed by the backoff. */
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
  /** "Postponed" (by the start limit or by the start backoff) is logged once
   *  per wait, not per tick. */
  postponedLogged: boolean;
  /** Pids the age restart already replaced; the same incarnation is never
   *  restarted twice even when its process age cannot be read. */
  ageRestarted: number[];
}

export function createGuardState(): GuardState {
  return {
    misses: 0,
    supervisor: null,
    upSince: null,
    downSince: null,
    startTimes: [],
    backoffIndex: 0,
    nextStartAt: 0,
    device: null,
    deviceStarts: [],
    nextDeviceStartAt: 0,
    deviceBudgetLogged: false,
    scriptMissingLogged: false,
    postponedLogged: false,
    ageRestarted: [],
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

/** Signal, then SIGKILL if the process outlives the grace period. Polls a
 *  fixed number of times (200 ms apart) rather than reading the wall clock, so
 *  a test with an instant `sleep` never spins for real seconds. */
export async function terminatePid(
  pid: number,
  deps: Pick<GuardDeps, "signal" | "isAlive" | "sleep">,
  signal: NodeJS.Signals = "SIGTERM",
  graceMs = DEFAULT_GUARD_CONFIG.stopGraceMs,
): Promise<void> {
  if (!deps.signal(pid, signal)) return;
  const polls = Math.ceil(graceMs / 200);
  for (let i = 0; i < polls && deps.isAlive(pid); i++) await deps.sleep(200);
  if (deps.isAlive(pid)) deps.signal(pid, "SIGKILL");
  // Give the kernel a moment to reap before the caller starts a replacement.
  for (let i = 0; i < 10 && deps.isAlive(pid); i++) await deps.sleep(100);
}

/** Earliest time a supervisor start is allowed: the backoff and, when the
 *  window already holds `rateMax` starts, the moment its oldest start leaves
 *  the window. Sound for any values: a backoff shorter than the window simply
 *  loses to the window, one longer wins. */
export function startAllowedAt(state: Pick<GuardState, "startTimes" | "nextStartAt">, cfg: GuardConfig): number {
  let at = state.nextStartAt;
  if (cfg.rateMax > 0 && state.startTimes.length >= cfg.rateMax) {
    const kthLast = state.startTimes[state.startTimes.length - cfg.rateMax];
    if (kthLast !== undefined) at = Math.max(at, kthLast + cfg.rateWindowMs);
  }
  return at;
}

/** Drops starts that left the window, then records one. */
function recordStart(state: GuardState, cfg: GuardConfig, now: number): number {
  state.startTimes = state.startTimes.filter((t) => now - t < cfg.rateWindowMs);
  state.startTimes.push(now);
  const wait = cfg.startBackoffMs[Math.min(state.backoffIndex, cfg.startBackoffMs.length - 1)];
  state.backoffIndex += 1;
  state.nextStartAt = now + (wait ?? 0);
  return wait ?? 0;
}

/** Age of the oldest supervisor process from the process table; the observed
 *  "up" period only when the table cannot tell. /proc ages merely run LATE on
 *  a device that slept (monotonic time stops), so an age restart never fires
 *  early; the observed period starts no earlier than the guard did. */
function supervisorAge(deps: GuardDeps, state: GuardState, pids: number[], now: number): number {
  let known: number | null = null;
  for (const pid of pids) {
    const processAge = deps.processAge(pid);
    if (processAge !== null) known = Math.max(known ?? 0, processAge);
  }
  if (known !== null) return known;
  return state.upSince === null ? 0 : now - state.upSince;
}

/** True when the rate limiter, not the backoff, is what holds the next start. */
function limitedByRate(state: Pick<GuardState, "startTimes">, cfg: GuardConfig): boolean {
  return cfg.rateMax > 0 && state.startTimes.length >= cfg.rateMax;
}

/**
 * One guard pass: probe, log every transition, repair what is the guard's to
 * repair. Returns the action taken (for `guard once` and the tests).
 */
export async function tick(state: GuardState, deps: GuardDeps): Promise<{ action: GuardAction; lines: string[] }> {
  const cfg = deps.config;
  const lines: string[] = [];
  const log = (message: string): void => {
    const line = formatLogLine(deps.now(), message);
    lines.push(line);
    deps.log(line);
  };
  /** A stop-and-start sequence; marked so `guard stop` waits for it. */
  const restart = async (body: () => Promise<void>): Promise<void> => {
    deps.marker.set(`guard pid ${process.pid} since ${new Date(deps.now()).toISOString()}`);
    try {
      await body();
    } finally {
      deps.marker.clear();
    }
  };
  const now0 = deps.now();
  state.startTimes = state.startTimes.filter((t) => now0 - t < cfg.rateWindowMs);
  const rows = await deps.probe();

  // ── supervisor ──
  if (rows === null) {
    state.misses += 1;
    const pids = deps.supervisorPids();
    if (state.supervisor !== "down") {
      state.supervisor = "down";
      state.upSince = null;
      state.downSince = now0;
      state.postponedLogged = false;
      log(
        pids.length > 0
          ? `supervisor: no reply (pid ${pids.join(", ")} still present; restarted after ${cfg.failsBeforeRestart} silent probes)`
          : `supervisor: down (no process, no reply on ${deps.sockPath})`,
      );
    }
    // A PRESENT supervisor gets its configured silent probes before anything
    // is done to it; a MISSING one is started right away.
    if (pids.length > 0 && state.misses < cfg.failsBeforeRestart) return { action: { kind: "none" }, lines };

    const allowedAt = startAllowedAt(state, cfg);
    if (now0 < allowedAt) {
      // Nothing is killed before its replacement may start: a wedged
      // supervisor left running is no worse than no supervisor at all. A wait
      // is said once, whichever of the two holds the start. The start line
      // announced the backoff, but a guard that then logs nothing for half an
      // hour reads as dead (2026-11-27, the owner's phone: 27 min without a
      // line between "down" and "start #2").
      if (!state.postponedLogged) {
        state.postponedLogged = true;
        log(limitedByRate(state, cfg)
          ? `supervisor: restart postponed by the start limit (${cfg.rateMax} per ${humanMs(cfg.rateWindowMs)}) until ${timeOfDay(allowedAt)}`
          : `supervisor: start postponed by the start backoff until ${timeOfDay(allowedAt)}`);
      }
      return { action: { kind: "none" }, lines };
    }
    state.postponedLogged = false;
    let outcome: GuardAction = { kind: "none" };
    await restart(async () => {
      if (pids.length > 0) {
        log(`supervisor: pid ${pids.join(", ")} alive but silent for ${state.misses} probes → kill`);
        for (const pid of pids) await terminatePid(pid, deps, "SIGTERM", cfg.stopGraceMs);
      }
      const started = deps.startSupervisor();
      const wait = recordStart(state, cfg, deps.now());
      // The replacement gets its own silent probes before it may be called wedged.
      state.misses = 0;
      if (started) {
        log(`supervisor: start #${state.backoffIndex} (next attempt in ${humanMs(wait)} if it does not answer)`);
        outcome = { kind: "start-supervisor" };
      } else if (!state.scriptMissingLogged) {
        state.scriptMissingLogged = true;
        log(`supervisor: could not start (script or node missing — reinstall remote-pi); retrying in ${humanMs(wait)}`);
      }
    });
    return { action: outcome, lines };
  }

  if (state.supervisor === "down") {
    log(`supervisor: back up after ${humanMs(Math.max(0, now0 - (state.downSince ?? now0)))} (${rows.length} fleet row(s))`);
  } else if (state.supervisor === null) {
    // First observation: record where we started from, once.
    log(`supervisor: up (${rows.length} fleet row(s))`);
  }
  if (state.supervisor !== "up") {
    state.supervisor = "up";
    state.upSince = now0;
    state.postponedLogged = false;
  } else if (state.backoffIndex > 0 && now0 - (state.upSince ?? now0) >= GUARD_STABLE_MS) {
    // Stable long enough: forgive the failed starts of the last outage.
    state.nextStartAt = 0;
    state.backoffIndex = 0;
    state.scriptMissingLogged = false;
  }
  state.misses = 0;
  state.downSince = null;

  // ── age restart ──
  const pids = deps.supervisorPids();
  if (cfg.maxAgeMs > 0 && pids.length > 0 && !pids.every((p) => state.ageRestarted.includes(p))) {
    const age = supervisorAge(deps, state, pids, now0);
    if (age > cfg.maxAgeMs) {
      const allowedAt = startAllowedAt(state, cfg);
      if (now0 < allowedAt) {
        if (!state.postponedLogged) {
          state.postponedLogged = true;
          log(`supervisor: age restart (uptime ${humanMs(age)}) postponed by the start limit until ${timeOfDay(allowedAt)}`);
        }
        return { action: { kind: "none" }, lines };
      }
      state.postponedLogged = false;
      for (const pid of pids) state.ageRestarted.push(pid);      log(`supervisor: age restart (uptime ${humanMs(age)}, limit ${humanMs(cfg.maxAgeMs)})`);
      await restart(async () => {
        for (const pid of pids) await terminatePid(pid, deps, "SIGINT", cfg.stopGraceMs);
        deps.startSupervisor();
        recordStart(state, cfg, deps.now());
        state.upSince = deps.now();
      });
      return { action: { kind: "age-restart" }, lines };
    }
  }

  // ── device daemon ──
  const now = deps.now();
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

/** The restart marker as a file: created when a sequence starts, removed when
 *  it ends. A stale one (guard killed mid-restart) is harmless: `guard stop`
 *  only waits while the guard process is alive. */
export function fileMarker(path: string = guardRestartMarkerPath()): { set: (text: string) => void; clear: () => void; exists: () => boolean } {
  return {
    set: (text) => {
      try {
        mkdirSync(dirname(path), { recursive: true });
        writeFileSync(path, text + "\n");
      } catch { /* the restart still runs; only the courtesy wait is lost */ }
    },
    clear: () => {
      try { unlinkSync(path); } catch { /* already gone */ }
    },
    exists: () => existsSync(path),
  };
}

export function defaultGuardDeps(overrides: Partial<GuardDeps> = {}): GuardDeps {
  const marker = fileMarker();
  return {
    config: loadGuardConfig().config,
    now: () => Date.now(),
    probe: () => probeStatus(),
    supervisorPids: () => findSupervisorPids(),
    processAge: (pid) => {
      const start = processStartMs(pid);
      return start === null ? null : Date.now() - start;
    },
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
    marker: { set: marker.set, clear: marker.clear },
    ...overrides,
  };
}

export interface GuardLoop {
  /** Stops the loop and resolves once no tick — and no restart inside a
   *  tick — is running. */
  stop: () => Promise<void>;
  /** Resolves when the loop has stopped by itself (signal). */
  done: Promise<void>;
}

/**
 * The foreground loop: one tick at once, then every `config.intervalMs`. Logs
 * its effective settings and every guard lifetime so `guard.log` shows both.
 * A SIGTERM during a restart does not abort it: the loop finishes the tick
 * and then stops.
 */
export function runGuardLoop(opts: { config?: GuardConfig; deps?: Partial<GuardDeps>; onSignal?: () => void; wireSignals?: boolean } = {}): GuardLoop {
  const config = opts.config ?? loadGuardConfig().config;
  const deps = defaultGuardDeps({ ...(opts.deps ?? {}), config });
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
    // A tick that is restarting the supervisor right now runs to its end.
    if (inFlight) await inFlight;
    deps.log(formatLogLine(deps.now(), `guard stopped (pid ${process.pid})`));
    releaseGuardLock(guardPidPath(), process.pid);
    resolveDone();
  };

  deps.log(formatLogLine(deps.now(), `guard started (pid ${process.pid}): ${describeGuardConfig(config)}`));
  // The first pass waits for a supervisor that is merely still booting.
  inFlight = (async (): Promise<void> => {
    await settleBeforeFirstTick(deps);
    if (running) await runTick();
  })().finally(() => { inFlight = null; });
  const timer = setInterval(() => {
    if (inFlight) return; // a slow tick is never stacked on another
    inFlight = runTick().finally(() => { inFlight = null; });
  }, config.intervalMs);

  const onSignal = (): void => {
    void stop().finally(() => opts.onSignal?.());
  };
  // Tests drive `stop()` themselves and must not leave signal listeners in
  // the test process.
  if (opts.wireSignals !== false) {
    process.once("SIGTERM", onSignal);
    process.once("SIGINT", onSignal);
  }
  return { stop, done };
}

// ── CLI: `remote-pi guard <run|start|status|stop|once>` ────────────────────

export function guardUsage(): string {
  return [
    "Usage: remote-pi guard <run|start|status|stop|once>",
    "",
    "  run     the loop in the foreground (one instance, pid file locked;",
    "          retires the interim piper-guard.sh first)",
    "  start   start the loop detached; no-op when it already runs",
    "  status  guard, supervisor, device daemon and the effective settings",
    "  stop    stop the loop; waits for a restart in progress (supervisor keeps running)",
    "  once    one check now; exit 0 when healthy or repaired, 1 otherwise",
    "",
    "Settings: ~/.pi/piper/guard.conf (KEY=VALUE) and REMOTE_PI_GUARD_<KEY>:",
    "  INTERVAL_S, FAILS_BEFORE_RESTART, MAX_AGE_S, RESTART_RATE_MAX,",
    "  RESTART_RATE_WINDOW_S, START_BACKOFF_S (comma list), STOP_GRACE_S",
    "  Interim names are aliases: CHECK_INTERVAL_S, RESTART_GRACE_S,",
    "  RATE_MAX_RESTARTS, RATE_WINDOW_S (the new name wins; env wins over both)",
    "",
    "On a PC the service manager restarts the supervisor; the guard is for Termux.",
  ].join("\n");
}

/** The pid of the guard that holds the pid-file lock, or null: the file names
 *  a process that is alive AND runs the guard loop. So a file left behind by
 *  a crash or a reboot never passes for a running guard once the OS has
 *  handed the pid to something else. */
export function guardLockHolderPid(pidFile: string = guardPidPath(), procRoot: string = DEFAULT_PROC_ROOT): number | null {
  const pid = pidFilePid(pidFile);
  return pid !== null && guardProcessAlive(pid, procRoot) ? pid : null;
}

/** The pid of the running guard loop, or null: the lock holder, else a guard
 *  whose pid file was removed while it runs, found by its command line (the
 *  loop takes the file back on its next watch). For such a guard `start`
 *  stays a no-op and `status` tells the truth. Only `start`'s own "started"
 *  answer insists on the lock (`guardLockHolderPid`).
 *
 *  Two loops without a lock settle themselves within one watch period (the
 *  one that retakes the lock makes the other leave). Until then the lowest
 *  pid is reported, so the answer does not depend on the order /proc is
 *  listed in.
 *
 *  Cost: one walk through /proc when nobody holds the lock. Callers that
 *  poll must throttle it, as `phone-setup` does (once a second); `start`
 *  polls the lock holder instead, which reads the pid file only. */
export function runningGuardPid(pidFile: string = guardPidPath(), procRoot: string = DEFAULT_PROC_ROOT): number | null {
  const holder = guardLockHolderPid(pidFile, procRoot);
  if (holder !== null) return holder;
  const byArgv = findGuardPids(procRoot);
  return byArgv.length === 0 ? null : Math.min(...byArgv);
}

function pidFilePid(pidFile: string): number | null {
  try {
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    return Number.isInteger(pid) ? pid : null;
  } catch {
    return null;
  }
}

/** Production wiring for `retireInterimGuard`. */
function defaultInterimRetireDeps(log: (line: string) => void): InterimRetireDeps {
  return {
    pidFilePid: () => pidFilePid(guardPidPath()),
    isInterim: (pid) => isPidAlive(pid) && (() => {
      const argv = readCmdline(DEFAULT_PROC_ROOT, pid);
      return argv !== null && isInterimGuardArgv(argv);
    })(),
    signal: (pid, sig) => signalPid(pid, sig),
    isAlive: (pid) => isPidAlive(pid),
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    rename: (from, to) => {
      if (!existsSync(from)) return false;
      try {
        renameSync(from, to);
        return true;
      } catch {
        return false;
      }
    },
    now: () => Date.now(),
    log,
  };
}

/** Starts the loop detached and waits briefly for its lock. */
export interface GuardStartDeps {
  spawnFn?: typeof spawn;
  sleep: (ms: number) => Promise<void>;
  /** A running guard, with or without its pid file: one found here means
   *  "already running" and nothing is spawned. */
  runningPid: () => number | null;
  /** The guard that holds the pid-file lock. "started" is reported only when
   *  this answers, so a child that was merely seen and then died (a refused
   *  `guard run`, a lock held elsewhere) is never a success. Without it the
   *  strict `guardLockHolderPid` is used, never the caller's `runningPid`:
   *  a caller that hands in only that one must not get the weaker answer. */
  lockHolder?: () => number | null;
  logPath?: string;
}

export async function guardStart(
  deps: GuardStartDeps = {
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    runningPid: runningGuardPid,
  },
): Promise<{ ok: boolean; message: string }> {
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
  const lockHolder = deps.lockHolder ?? guardLockHolderPid;
  for (let i = 0; i < 20; i++) {
    await deps.sleep(150);
    const pid = lockHolder();
    if (pid !== null) return { ok: true, message: `guard started (pid ${pid})` };
  }
  return { ok: false, message: `guard did not take its lock — see ${logPath}` };
}

/** SIGTERM to the guard that holds the lock and wait. While a restart
 *  sequence is in progress (marker file present) the wait is extended instead
 *  of escalating to SIGKILL: a half-done restart would leave no supervisor at
 *  all.
 *
 *  Only the LOCK HOLDER is signalled. A loop found by its command line alone
 *  (the pid file missing or stale) is named and left alone: nothing proves
 *  which loop the pid file meant, and `stop` must never guess (fourth review
 *  on #130). */
export interface GuardStopDeps {
  /** The guard that holds the pid-file lock. */
  runningPid: () => number | null;
  signal: (pid: number, sig: NodeJS.Signals) => boolean;
  isAlive: (pid: number) => boolean;
  sleep: (ms: number) => Promise<void>;
  restartInProgress: () => boolean;
  /** Loops found by command line that hold no lock; named when there is no
   *  lock holder. Absent: none are looked for. */
  lockless?: () => number[];
}

export async function guardStop(
  deps: GuardStopDeps = {
    runningPid: guardLockHolderPid,
    lockless: () => findGuardPids(),
    signal: signalPid,
    isAlive: isPidAlive,
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    restartInProgress: () => existsSync(guardRestartMarkerPath()),
  },
): Promise<{ ok: boolean; message: string }> {
  const pid = deps.runningPid();
  if (pid === null) {
    const stray = (deps.lockless ?? (() => []))();
    if (stray.length === 0) return { ok: true, message: "guard is not running" };
    return {
      ok: false,
      message:
        "no guard holds the lock (the pid file is missing or stale); loop(s) found by command line: " +
        `${[...stray].sort((a, b) => a - b).join(", ")} — nothing was stopped. Restore the pid file, or stop them by hand.`,
    };
  }
  if (!deps.signal(pid, "SIGTERM")) return { ok: true, message: "guard is not running" };
  let waitedMs = 0;
  while (deps.isAlive(pid) && waitedMs < DEFAULT_GUARD_CONFIG.stopGraceMs) {
    await deps.sleep(100);
    waitedMs += 100;
  }
  // The guard finishes a restart it has begun; that may take two stop
  // graces (old supervisor's SIGKILL escalation and the start) plus slack.
  const restartCapMs = 3 * DEFAULT_GUARD_CONFIG.stopGraceMs + 60_000;
  while (deps.isAlive(pid) && deps.restartInProgress() && waitedMs < restartCapMs) {
    await deps.sleep(250);
    waitedMs += 250;
  }
  if (deps.isAlive(pid)) {
    deps.signal(pid, "SIGKILL");
    await deps.sleep(100);
    return { ok: true, message: `guard stopped (pid ${pid}, needed SIGKILL)` };
  }
  return { ok: true, message: `guard stopped (pid ${pid})` };
}

/** Four lines, same vocabulary as the log. */
export async function guardStatus(
  deps: {
    runningPid: () => number | null;
    probe: () => Promise<DaemonInfo[] | null>;
    sockPath: string;
    config: GuardConfig;
  } = { runningPid: runningGuardPid, probe: () => probeStatus(), sockPath: supervisorSockPath(), config: loadGuardConfig().config },
): Promise<string[]> {
  const pid = deps.runningPid();
  const rows = await deps.probe();
  const device = rows === null ? null : classifyDevice(rows);
  return [
    `guard:      ${pid === null ? "not running" : `running (pid ${pid})`} — ${guardLogPath()}`,
    `supervisor: ${rows === null ? `no reply on ${deps.sockPath}` : `up (${rows.length} fleet row(s))`}`,
    `device:     ${device === null ? "unknown (supervisor silent)" : DEVICE_HINTS[device]}`,
    `settings:  ${describeGuardConfig(deps.config)}`,
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
  if (result.action.kind !== "none" && result.action.kind !== "restart-device") await full.sleep(3_000);
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
      const loaded = loadGuardConfig();
      const log = (line: string): void => appendGuardLog(guardLogPath(), line);
      // The interim shell guard shares the pid file: stop it first, so the
      // lock below is taken from a retired guard, not stolen from a live one.
      await retireInterimGuard(defaultInterimRetireDeps(log));
      if (acquireGuardLock(pidFile, process.pid) === "already-running") {
        io.err(`[remote-pi] guard already running (pid ${runningGuardPid() ?? "?"})`);
        return 0;
      }
      const loop = runGuardLoop({ config: loaded.config });
      if (loaded.ignored.length > 0) {
        for (const line of loaded.ignored) log(formatLogLine(Date.now(), `guard: setting ignored: ${line}`));
      }
      // If the pid file vanished and a second guard took the lock, this one
      // leaves; if the file merely vanished, the lock is retaken silently.
      const watch = setInterval(() => {
        if (runningGuardPid() === process.pid) return;
        if (acquireGuardLock(pidFile, process.pid) === "already-running") {
          void loop.stop().then(() => process.exit(0));
        }
      }, 5 * Math.max(loaded.config.intervalMs, GUARD_STABLE_MS / 10));
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
      (r.ok ? io.out : io.err)(`[remote-pi] ${r.message}`);
      return r.ok ? 0 : 1;
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
