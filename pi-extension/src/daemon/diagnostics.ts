/**
 * Plan/159 — per-daemon diagnostics on disk.
 *
 * Two artifacts per daemon id under `~/.pi/piper/daemons/`:
 *
 *   `<id>.log`  — the child's stderr, appended line-by-line with a
 *                 timestamp prefix. Survives however the supervisor was
 *                 launched (Task Scheduler tee, watchdog redirection, or
 *                 NO redirection at all — the 2026-11-07 incident showed a
 *                 hidden-start supervisor discards child stderr entirely,
 *                 leaving crash forensics impossible).
 *   `<id>.dead` — crash-loop marker: the child exhausted the backoff
 *                 schedule and is retrying at the max cadence. Written as
 *                 one JSON line (`{at, exit_code, attempt}`); removed on
 *                 the next spawn. Lets `daemon status`, `doctor`, and a
 *                 watchdog see "fleet dead" as queryable state instead of
 *                 silence.
 *
 * All writes are best-effort: diagnostics must never take the supervisor
 * or a child stream handler down. Paths resolve against `REMOTE_PI_HOME`
 * (tests inject a scratch home), matching registry.ts.
 */

import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Hard cap for a per-daemon log. Beyond it the file is truncated to its
 *  tail so recent errors stay readable without unbounded growth. */
export const DAEMON_LOG_MAX_BYTES = 5 * 1024 * 1024;

/** How much of the tail to keep when the cap is hit. */
export const DAEMON_LOG_KEEP_BYTES = 1024 * 1024;

function daemonDiagnosticsRoot(): string {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  return join(root, ".pi", "piper", "daemons");
}

export function daemonLogPath(id: string): string {
  return join(daemonDiagnosticsRoot(), `${id}.log`);
}

export function deadMarkerPath(id: string): string {
  return join(daemonDiagnosticsRoot(), `${id}.dead`);
}

/** Best-effort `mkdir -p` of the diagnostics dir. */
function ensureDir(): void {
  try { mkdirSync(daemonDiagnosticsRoot(), { recursive: true }); } catch { /* best-effort */ }
}

/**
 * Appends one stderr chunk to the daemon's log with a timestamp prefix.
 * Best-effort in every direction; caps the file at DAEMON_LOG_MAX_BYTES by
 * rewriting it with its own tail (a `pi` daemon can be chatty on stderr
 * during a crash loop — 5 MB of recent history is plenty for forensics).
 */
export function appendDaemonLog(id: string, text: string): void {
  try {
    ensureDir();
    const path = daemonLogPath(id);
    const stamp = new Date().toISOString();
    // Chunk may carry partial lines; prefix per chunk keeps ordering without
    // buffering (the child writes line-buffered in practice).
    appendFileSync(path, `[${stamp}] ${text}`);
    const size = statSync(path).size;
    if (size > DAEMON_LOG_MAX_BYTES) {
      const keep = readFileSync(path);
      const tail = keep.subarray(Math.max(0, keep.length - DAEMON_LOG_KEEP_BYTES));
      writeFileSync(path, tail);
    }
  } catch { /* diagnostics must never throw into a stream handler */ }
}

export interface DeadMarker {
  at: string;
  exit_code: number | null;
  attempt: number;
}

/** Writes (or refreshes) the crash-loop marker for `id`. Best-effort. */
export function writeDeadMarker(id: string, info: DeadMarker): void {
  try {
    ensureDir();
    writeFileSync(deadMarkerPath(id), JSON.stringify(info) + "\n");
  } catch { /* best-effort */ }
}

/** Removes the crash-loop marker (called on every spawn so a recovered
 *  daemon stops reporting dead). Best-effort; a missing marker is fine. */
export function clearDeadMarker(id: string): void {
  try { rmSync(deadMarkerPath(id), { force: true }); } catch { /* best-effort */ }
}

/** Returns the crash-loop marker contents, or null when none exists. */
export function readDeadMarker(id: string): DeadMarker | null {
  try {
    if (!existsSync(deadMarkerPath(id))) return null;
    const parsed = JSON.parse(readFileSync(deadMarkerPath(id), "utf8")) as DeadMarker;
    if (typeof parsed.at !== "string") return null;
    return parsed;
  } catch {
    return null;
  }
}
