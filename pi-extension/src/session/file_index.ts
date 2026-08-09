/**
 * Plan/128 — durable, performant session-history index over Pi's append-only
 * `.jsonl` transcript.
 *
 * Pi persists every committed message to
 * `$PI_CODING_AGENT_DIR/sessions/<encode(cwd)>/<ts>_<uuid>.jsonl`, one line per
 * message: `{type:'message', message:{role,content,timestamp,...}}`. The mobile
 * sync path previously ignored this file and served history from the volatile
 * in-RAM `ext.messageBuffer` — which is `[]` after a process restart. This
 * module makes the `.jsonl` the durable source of truth for `session_sync`.
 *
 * Performance contract (see plan/128 budget):
 * - The index holds **metadata only** (`{ts, role, byteOffset, byteLen}`), never
 *   message bodies, so a full build is O(file bytes) and cached by
 *   `{path,size,mtime}`.
 * - On append (the file only grows) we re-scan **only the tail** past the last
 *   known line boundary — O(appended bytes), never O(file).
 * - Paging reads **only the requested byte ranges**, not the whole file.
 * - No `readFileSync` of the whole transcript on any hot path.
 *
 * Line parsing is tolerant (plan/128 risk: line-shape drift across pi
 * versions): non-`message` / unparseable / partial-write lines are skipped and
 * never throw. On total failure the caller falls back to the RAM tail
 * (today's behavior).
 *
 * Path helpers are a TS port of cockpit's `session_history_impl.dart`
 * (`_sessionsRoot` / `_encode` / `_idOf`) so both clients resolve the same file.
 */
import { createReadStream, readdirSync, statSync, type Stats } from "node:fs";
import { open } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

import type { BufferMsg } from "../extension-state.js";

/** A single scanned line of the transcript — metadata only, no body. */
export interface FileIndexEntry {
  /** `message.timestamp` (ms); 0 when absent. Used for ordering + RAM dedup. */
  ts: number;
  /** `message.role`. Used for the RAM-tail dedup key. */
  role: string;
  /** Absolute byte offset of the line start in the file (stable: file is append-only). */
  byteOffset: number;
  /** Line length in bytes, excluding the trailing `\n`. */
  byteLen: number;
}

/** A cached, reusable index over one session `.jsonl`. */
export interface FileIndex {
  path: string;
  /** `stat().size` at build time — cache key + append/replace detector. */
  size: number;
  /** `stat().mtimeMs` at build time — cache key. */
  mtimeMs: number;
  /** Scanned entries in chronological order (oldest first; byteOffset ascending). */
  entries: FileIndexEntry[];
  /**
   * Safe resume offset = byte offset just past the last fully-consumed `\n`.
   * A trailing partial line (file ended mid-write, no `\n`) is NOT consumed;
   * the next tail-scan starts here and re-reads it once the `\n` lands.
   */
  lastByteOffset: number;
  /** `${ts}:${role}` of every kept entry — O(1) RAM-tail dedup membership. */
  keys: Set<string>;
  /** `INDEX_MAX` cap hit: oldest entries were dropped from the in-RAM index. */
  olderDropped: boolean;
}

/** Resolved current-session file (newest `.jsonl` by mtime under the cwd dir). */
export interface SessionFileRef {
  path: string;
  size: number;
  mtimeMs: number;
}

const DEFAULT_INDEX_MAX = 20_000;

function indexMax(): number {
  const raw = Number(process.env.REMOTE_PI_HISTORY_INDEX_MAX);
  return Number.isFinite(raw) && raw > 0 ? Math.floor(raw) : DEFAULT_INDEX_MAX;
}

function homeDir(): string {
  // Windows doesn't set HOME; USERPROFILE is the equivalent. Mirrors cockpit.
  return process.env.HOME ?? process.env.USERPROFILE ?? homedir();
}

/** `$PI_CODING_AGENT_DIR ?? <home>/.pi/agent` + `/sessions`. Port of `_sessionsRoot`. */
export function sessionsRoot(): string {
  const agentDir = process.env.PI_CODING_AGENT_DIR ?? join(homeDir(), ".pi", "agent");
  return join(agentDir, "sessions");
}

/**
 * Encode a cwd into the pi session-folder name. Port of `_encode` /
 * `core/session-manager.js`: strip a leading separator, replace `/`, `\` and
 * `:` with `-`, wrap in `--…--`. On Windows the raw `:`/`\` (e.g. `R:\code`)
 * would otherwise form an invalid directory name.
 */
export function encodeCwd(cwd: string): string {
  const stripped = cwd.replace(/^[/\\]/, "");
  const slug = stripped.replace(/[/\\:]/g, "-");
  return `--${slug}--`;
}

/**
 * Resolve the **current** session file for a cwd: the newest `.jsonl` by mtime
 * under `sessionsRoot()/encodeCwd(cwd)`. The cwd-lock (`ext.cwdLock`) guarantees
 * a single active daemon per cwd, so newest-mtime == the live session.
 * Returns `null` when the dir is missing/unreadable or holds no transcripts.
 */
export function resolveCurrentSessionFile(cwd: string): SessionFileRef | null {
  let names: string[];
  try {
    names = readdirSync(join(sessionsRoot(), encodeCwd(cwd)));
  } catch {
    return null; // missing dir → no durable history yet
  }
  let best: { path: string; st: Stats } | null = null;
  for (const name of names) {
    if (!name.endsWith(".jsonl")) continue;
    const path = join(sessionsRoot(), encodeCwd(cwd), name);
    let st: Stats;
    try {
      st = statSync(path);
    } catch {
      continue;
    }
    if (!st.isFile()) continue;
    if (!best || st.mtimeMs > best.st.mtimeMs) best = { path, st };
  }
  if (!best) return null;
  return { path: best.path, size: best.st.size, mtimeMs: best.st.mtimeMs };
}

/**
 * Scan complete `\n`-terminated lines of a file starting at `startOffset`,
 * invoking `onLine(absoluteByteOffset, lineBytes)` for each (line excludes the
 * `\n`). Returns the safe resume offset = byte offset just past the last
 * consumed `\n`; a trailing partial line (no `\n`) is left unread.
 *
 * Byte-level (not UTF-16 char) splitting is correct for `.jsonl`: JSON encodes
 * literal newlines inside strings as the `\n` escape, so a `0x0a` byte only
 * occurs as a real line terminator.
 */
async function scanLines(
  path: string,
  startOffset: number,
  onLine: (offset: number, line: Buffer) => void,
): Promise<number> {
  let baseOffset = startOffset; // absolute file offset of buf[0] across iterations
  // Annotated as the default-generic `Buffer` (== `Buffer<ArrayBufferLike>`):
  // `subarray()` returns `Buffer<ArrayBufferLike>`, and `Buffer.alloc(0)` would
  // otherwise pin this to `Buffer<ArrayBuffer>` under TS6 + @types/node 25.
  let carry: Buffer = Buffer.alloc(0);
  const stream = createReadStream(path, { start: startOffset, highWaterMark: 65536 });
  for await (const raw of stream) {
    const chunk = raw as Buffer;
    const buf = carry.length ? Buffer.concat([carry, chunk]) : chunk;
    let cursor = 0;
    let nl: number;
    while ((nl = buf.indexOf(0x0a, cursor)) !== -1) {
      onLine(baseOffset + cursor, buf.subarray(cursor, nl));
      cursor = nl + 1;
    }
    // bytes after the final `\n` (or the whole buf if none) become the next carry.
    carry = buf.subarray(cursor);
    baseOffset += cursor;
  }
  // `baseOffset` now points at the start of the (unconsumed) trailing carry, i.e.
  // just past the last consumed `\n` — the safe resume point.
  return baseOffset;
}

function asNumber(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}
function asString(v: unknown): string {
  return typeof v === "string" ? v : "";
}

/** Parse one transcript line into metadata, or null if not a `message` line. */
function parseLine(offset: number, line: Buffer): FileIndexEntry | null {
  if (line.length === 0) return null;
  let obj: unknown;
  try {
    obj = JSON.parse(line.toString("utf8"));
  } catch {
    return null; // unparseable line — skip, never throw
  }
  if (!obj || typeof obj !== "object") return null;
  const o = obj as { type?: unknown; message?: unknown };
  if (o.type !== "message" || !o.message || typeof o.message !== "object") return null;
  const m = o.message as { timestamp?: unknown; role?: unknown };
  return {
    ts: asNumber(m.timestamp),
    role: asString(m.role),
    byteOffset: offset,
    byteLen: line.length,
  };
}

/** Build the in-RAM index (metadata only) for one file, with INDEX_MAX cap. */
async function collectEntries(path: string, startOffset: number): Promise<{
  entries: FileIndexEntry[];
  resumeOffset: number;
}> {
  const entries: FileIndexEntry[] = [];
  const resumeOffset = await scanLines(path, startOffset, (offset, line) => {
    const e = parseLine(offset, line);
    if (e) entries.push(e);
  });
  return { entries, resumeOffset };
}

function applyCap(entries: FileIndexEntry[]): { entries: FileIndexEntry[]; olderDropped: boolean } {
  const max = indexMax();
  if (entries.length <= max) return { entries, olderDropped: false };
  // Keep the newest `max` (drop oldest). Chronological order is byteOffset-ascending.
  return { entries: entries.slice(entries.length - max), olderDropped: true };
}

function buildKeys(entries: FileIndexEntry[]): Set<string> {
  const keys = new Set<string>();
  for (const e of entries) keys.add(`${e.ts}:${e.role}`);
  return keys;
}

/** Full (cold) index build: stream the whole file from offset 0. */
export async function buildIndex(path: string): Promise<FileIndex> {
  const st = statSync(path);
  const { entries, resumeOffset } = await collectEntries(path, 0);
  const capped = applyCap(entries);
  return {
    path,
    size: st.size,
    mtimeMs: st.mtimeMs,
    entries: capped.entries,
    lastByteOffset: resumeOffset,
    keys: buildKeys(capped.entries),
    olderDropped: capped.olderDropped,
  };
}

/**
 * Return a fresh index for `ref`, reusing `prev` when the file is unchanged and
 * tail-scanning when it grew. Rebuilds fully on replace/truncate/path change.
 *
 * - unchanged (`prev` matches `{path,size,mtime}`) → return `prev` (no I/O)
 * - grew (`prev.path` == && `ref.size` >= `prev.size`) → scan tail only, append
 * - otherwise (new file / shrank / replaced) → full rebuild
 */
export async function refreshIndex(
  prev: FileIndex | null,
  ref: SessionFileRef,
): Promise<FileIndex> {
  if (
    prev &&
    prev.path === ref.path &&
    prev.size === ref.size &&
    prev.mtimeMs === ref.mtimeMs
  ) {
    return prev; // cache hit — no disk I/O
  }
  // Same file, STRICTLY grew → scan only the appended tail (O(appended bytes)).
  // Same-size with a different mtime means the file was rewritten, not appended —
  // fall through to a full rebuild so we never serve stale entries.
  if (prev && prev.path === ref.path && ref.size > prev.size) {
    const { entries: tail, resumeOffset } = await collectEntries(ref.path, prev.lastByteOffset);
    const merged = applyCap(prev.entries.concat(tail));
    return {
      path: ref.path,
      size: ref.size,
      mtimeMs: ref.mtimeMs,
      entries: merged.entries,
      // Safe resume point: advances past newly-consumed `\n`s; stays put if
      // only a partial (no-`\n`) line landed, so the next refresh re-reads it.
      lastByteOffset: resumeOffset,
      keys: buildKeys(merged.entries),
      olderDropped: merged.olderDropped,
    };
  }
  return buildIndex(ref.path);
}

/**
 * Read the message bodies for the given entries via positioned reads (one open,
 * many small range reads). Lines that fail to parse or aren't `message` lines
 * are skipped — the index already filtered them, so this is defensive only.
 */
export async function readMessages(path: string, entries: FileIndexEntry[]): Promise<BufferMsg[]> {
  if (entries.length === 0) return [];
  const fh = await open(path, "r");
  try {
    const out: BufferMsg[] = [];
    for (const e of entries) {
      const buf = Buffer.alloc(e.byteLen);
      await fh.read(buf, 0, e.byteLen, e.byteOffset);
      let obj: unknown;
      try {
        obj = JSON.parse(buf.toString("utf8"));
      } catch {
        continue;
      }
      if (!obj || typeof obj !== "object") continue;
      const o = obj as { type?: unknown; message?: unknown };
      if (o.type !== "message" || !o.message || typeof o.message !== "object") continue;
      out.push(o.message as BufferMsg);
    }
    return out;
  } finally {
    await fh.close();
  }
}

// ── Cursor codec ─────────────────────────────────────────────────────────────
// Opaque tokens threaded by the app. `off:<offset>` for file entries (stable:
// the file is append-only so a byte offset never moves); `ram:<i>` for entries
// served from the in-RAM tail (only the newest page ever contains them).

/**
 * Plan/128 (review C3) — serve one backward page STRICTLY BELOW the capped
 * index floor by streaming the transcript from offset 0. Used only when
 * `INDEX_MAX` has dropped the oldest metadata (`olderDropped`) and the cursor
 * points at/below the retained window, so the advertised durable full-history
 * behavior holds even past the cap. O(bytes up to the cursor) time, O(limit)
 * memory — the common path stays index-based; this only runs on the rare deep
 * pagination into the cap-dropped region.
 *
 * Returns the `limit` entries strictly older than the cursor's byte offset,
 * whether even-older entries remain (`hasMore`), the cursor of the page's
 * oldest entry (`nextBefore`), and the ts of the most-recent `user` entry
 * before the page (so the caller can seed the mapper with a stable reply id —
 * review C2). Returns null on a read error (caller falls back to the RAM tail).
 */
export async function streamPageBefore(
  path: string,
  before: Cursor,
  limit: number,
): Promise<{
  entries: FileIndexEntry[];
  hasMore: boolean;
  nextBefore?: Cursor;
  precedingUserTs: number | null;
} | null> {
  const targetOffset = before.kind === "off" ? before.offset : Number.POSITIVE_INFINITY;
  const window: FileIndexEntry[] = [];
  let count = 0;
  // Last `user` ts among entries shifted out of the window (i.e. strictly
  // older than the page) — the reply target for an assistant at the page start.
  let precedingUserTs: number | null = null;
  const STOP = new Error("streamPageBefore:stop");
  try {
    await scanLines(path, 0, (offset, line) => {
      if (offset >= targetOffset) throw STOP; // reached the cursor — done
      const e = parseLine(offset, line);
      if (!e) return;
      if (window.length >= limit) {
        const shifted = window.shift()!;
        if (shifted.role === "user") precedingUserTs = shifted.ts;
      }
      window.push(e);
      count++;
    });
  } catch (e) {
    if (e !== STOP) return null; // real read error → caller falls back
  }
  const hasMore = count > limit;
  const nextBefore = window.length > 0 ? { kind: "off" as const, offset: window[0]!.byteOffset } : undefined;
  return { entries: window, hasMore, nextBefore, precedingUserTs };
}

export type Cursor = { kind: "off"; offset: number } | { kind: "ram"; index: number };

export function encodeCursor(c: Cursor): string {
  return c.kind === "off" ? `off:${c.offset}` : `ram:${c.index}`;
}

export function decodeCursor(s: string | undefined | null): Cursor | null {
  if (!s) return null;
  if (s.startsWith("off:")) {
    const n = Number(s.slice(4));
    return Number.isFinite(n) ? { kind: "off", offset: n } : null;
  }
  if (s.startsWith("ram:")) {
    const n = Number(s.slice(4));
    return Number.isFinite(n) ? { kind: "ram", index: Math.floor(n) } : null;
  }
  return null;
}
