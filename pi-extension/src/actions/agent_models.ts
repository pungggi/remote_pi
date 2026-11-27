/**
 * Plan/173 stage A2 — the Antigravity CLI's model catalogue, read on the
 * device that will run it.
 *
 * `list_models { agent: "agy" }` and the `device_info` agent probe both need
 * to talk to `agy`. One module owns that, so the two never drift:
 *
 *   - `probeAgy()` answers "can this device start AGY at all?" with one fast
 *     call (`agy --version`, about 0.4 s on a PC, 1.9 s under proot).
 *   - `listAgyModels()` parses `agy models`, which prints `id<TAB>name` per
 *     line on stdout (progress chatter goes to stderr).
 *
 * Both are cached for ten minutes: a device picker may re-ask on every open,
 * and a cold `agy` on a phone costs seconds of battery.
 *
 * One wire shape for every agent (plan/173): a model is `{ provider, id, name }`
 * as for Pi. AGY has no provider half, so `provider` is a display grouping
 * derived from the id — the app's picker tabs keep working. Only the id ever
 * reaches the AGY command line.
 *
 * Nothing here throws to the caller and nothing hangs: every process has a
 * deadline, and a failure comes back as `{ ok:false, message }` with AGY's
 * own words when it printed any.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { SAFE_MODEL_TOKEN, type WireModel } from "../protocol/types.js";

/** How long a cached answer stays valid. */
export const AGY_CACHE_MS = 10 * 60 * 1000;

/** `agy --version` is fast everywhere; `agy models` may fetch a catalogue. */
export const AGY_VERSION_TIMEOUT_MS = 15_000;
export const AGY_MODELS_TIMEOUT_MS = 30_000;

/** Display provider for ids that name no known family. */
export const AGY_PROVIDER_FALLBACK = "agy";

/** Display grouping derived from the model id (never sent to AGY). */
export function agyProviderForId(id: string): string {
  const lower = id.toLowerCase();
  if (lower.startsWith("claude")) return "anthropic";
  if (lower.startsWith("gemini")) return "google";
  if (lower.startsWith("gpt")) return "openai";
  return AGY_PROVIDER_FALLBACK;
}

/**
 * Parse `agy models` output: one `id<TAB>name` per line. Blank lines and
 * lines without a tab are skipped; a name is optional (the id is repeated).
 * The id must pass the same charset guard the command line uses, so a
 * catalogue can never smuggle a flag into `--model`.
 */
export function parseAgyModels(stdout: string): WireModel[] {
  const out: WireModel[] = [];
  const seen = new Set<string>();
  for (const rawLine of stdout.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;
    const tab = line.indexOf("\t");
    const id = (tab === -1 ? line : line.slice(0, tab)).trim();
    const name = (tab === -1 ? line : line.slice(tab + 1)).trim() || id;
    if (!SAFE_MODEL_TOKEN.test(id) || seen.has(id)) continue;
    seen.add(id);
    out.push({
      id,
      name,
      provider: agyProviderForId(id),
      // AGY publishes no such metadata on this surface; the app hides the
      // thinking control for `reasoning:false` and treats 0 as "unknown".
      reasoning: false,
      context_window: 0,
      vision: false,
    });
  }
  return out;
}

export type AgyModelsResult = { ok: true; models: WireModel[] } | { ok: false; message: string };

export interface AgyDeps {
  /** `child_process.spawn`, injectable so tests never start agy. */
  spawn?: typeof spawn;
  /** Overrides the cache clock (tests pass a fixed `now`). */
  now?: () => number;
  /** Deadline overrides, so a test never waits the real 15 or 30 seconds. */
  versionTimeoutMs?: number;
  modelsTimeoutMs?: number;
}

interface CacheEntry {
  at: number;
  value: AgyModelsResult | boolean;
}

const _cache = new Map<string, CacheEntry>();

/** Test seam — drop both cached answers. */
export function _resetAgyCacheForTests(): void {
  _cache.clear();
}

function cached<T extends "models" | "probe">(
  key: T,
  now: number,
): (T extends "models" ? AgyModelsResult : boolean) | undefined {
  const hit = _cache.get(key);
  if (!hit || now - hit.at > AGY_CACHE_MS) return undefined;
  return hit.value as T extends "models" ? AgyModelsResult : boolean;
}

/** The agy executable and how to spawn it. Windows resolves the CLI through
 *  the shell's PATHEXT (`agy.exe`, or an `agy.cmd` shim from an npm install);
 *  a bare `spawn("agy.cmd")` misses the plain `.exe` of the native
 *  installer, which is the common case. */
export function agySpawnSpec(platform: NodeJS.Platform = process.platform): { cmd: string; shell: boolean } {
  return platform === "win32" ? { cmd: "agy", shell: true } : { cmd: "agy", shell: false };
}

interface RunResult {
  code: number | null;
  stdout: string;
  stderr: string;
  error?: NodeJS.ErrnoException;
  timedOut: boolean;
}

/** Run `agy <args>` under a deadline. Never throws, never rejects. */
function runAgy(
  args: string[],
  timeoutMs: number,
  spawnFn: typeof spawn,
): Promise<RunResult> {
  const { cmd, shell } = agySpawnSpec();
  return new Promise<RunResult>((resolve) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const done = (r: RunResult): void => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve(r);
    };
    let child: ChildProcess;
    try {
      // Fixed argument vectors only (no caller text), so `shell:true` on
      // Windows has nothing to quote-split.
      child = spawnFn(cmd, args, { stdio: ["ignore", "pipe", "pipe"], shell, windowsHide: true });
    } catch (e) {
      done({ code: null, stdout: "", stderr: "", error: e as NodeJS.ErrnoException, timedOut: false });
      return;
    }
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (chunk: Buffer | string) => { stdout += chunk.toString(); });
    child.stderr?.on("data", (chunk: Buffer | string) => { stderr += chunk.toString(); });
    child.on("error", (err) => done({ code: null, stdout, stderr, error: err, timedOut: false }));
    child.on("close", (code) => done({ code, stdout, stderr, timedOut: false }));
    timer = setTimeout(() => {
      try { child.kill("SIGKILL"); } catch { /* already gone */ }
      done({ code: null, stdout, stderr, timedOut: true });
    }, timeoutMs);
  });
}

function cleanMessage(stderr: string, fallback: string): string {
  // Drop the progress line AGY prints while fetching, keep what it said.
  const lines = stderr
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l && !/^fetching available models/i.test(l));
  return lines.join(" ").slice(0, 400) || fallback;
}

export function agyDeadlineLabel(timeoutMs: number): string {
  return timeoutMs < 1000 ? `${timeoutMs} ms` : `${Math.round(timeoutMs / 1000)} s`;
}

/** Can this device start AGY? True when `agy --version` exits 0. Cached. */
export async function probeAgy(deps: AgyDeps = {}): Promise<boolean> {
  const now = (deps.now ?? Date.now)();
  const hit = cached("probe", now);
  if (hit !== undefined) return hit;
  const timeoutMs = deps.versionTimeoutMs ?? AGY_VERSION_TIMEOUT_MS;
  const r = await runAgy(["--version"], timeoutMs, deps.spawn ?? spawn);
  const ok = r.code === 0;
  // Only a success is cached: a failure (signed out, half-installed, slow
  // first start) should get another chance on the next question.
  if (ok) _cache.set("probe", { at: now, value: true });
  return ok;
}

/** AGY's model catalogue on this device. Cached when it succeeded. */
export async function listAgyModels(deps: AgyDeps = {}): Promise<AgyModelsResult> {
  const now = (deps.now ?? Date.now)();
  const hit = cached("models", now);
  if (hit !== undefined) return hit;
  const timeoutMs = deps.modelsTimeoutMs ?? AGY_MODELS_TIMEOUT_MS;
  const r = await runAgy(["models"], timeoutMs, deps.spawn ?? spawn);
  let value: AgyModelsResult;
  if (r.error && r.error.code === "ENOENT") {
    value = { ok: false, message: "agy is not installed on this device" };
  } else if (r.timedOut) {
    value = { ok: false, message: `agy models did not answer within ${agyDeadlineLabel(timeoutMs)}` };
  } else if (r.code !== 0) {
    value = { ok: false, message: cleanMessage(r.stderr, r.stdout.trim() || `agy models exited with code ${r.code}`) };
  } else {
    const models = parseAgyModels(r.stdout);
    // Exit 0 with nothing usable is the signed-out shape ("Please sign in to
    // view available models…" on stdout) — report it instead of an empty list
    // the app would show as "AGY has no models".
    if (models.length === 0) {
      value = { ok: false, message: cleanMessage(r.stdout, "agy models printed no models") };
    } else {
      value = { ok: true, models };
      _cache.set("models", { at: now, value });
    }
  }
  return value;
}

/** The ids AGY offers, or null when the catalogue is unavailable. */
export async function agyModelIds(deps: AgyDeps = {}): Promise<string[] | null> {
  const r = await listAgyModels(deps);
  return r.ok ? r.models.map((m) => m.id) : null;
}
