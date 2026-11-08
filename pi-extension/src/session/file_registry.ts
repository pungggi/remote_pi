/**
 * Plan/158 — per-session agent_file registry sidecar.
 *
 * Every `show_file` push appends one metadata line here; the sidecar is the
 * source of truth for (a) `agent_file_ref` history merges in `session_sync`
 * and (b) `agent_file_fetch` byte serving. Lives NEXT TO the transcript:
 * `sessions/<encodeCwd(cwd)>/<session>.files.jsonl` — one line per push:
 *
 *   {fileId, ts, kind, mime?, name?, bytes, caption?, allowNetwork?, absPath, mtimeMs}
 *
 * Design rules (plan/158 fixed decisions #2/#5):
 * - Metadata only. `absPath` is the ONE field that identifies the file, and it
 *   NEVER crosses the wire — the app only ever sees the opaque `fileId`.
 * - No content hash: TCP guarantees wire integrity, and staleness is caught by
 *   the `mtimeMs` + `bytes` guard re-checked against `stat()` on every chunk.
 *   Hashing would re-introduce the full file read the metadata-only flip
 *   removed.
 * - Append-only + tolerant parse: a corrupt/partial line is skipped, never
 *   thrown (same discipline as the plan/128 transcript index).
 */
import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { encodeCwd, resolveCurrentSessionFile, sessionsRoot } from "./file_index.js";
export interface AgentFileRegistryEntry {
  /** Opaque UUID (`doc_...`). The only file handle the app ever holds. */
  fileId: string;
  /** Push time (ms) — orders the ref inside session history. */
  ts: number;
  /** Viewer kind (markdown/text/pdf/html/mermaid) or save/share-only binary
   *  (file, plan/162). */
  kind: string;
  mime?: string;
  /** Basename for display + save-as name on the phone. */
  name?: string;
  /** Raw byte size at push time (staleness guard + progress total). */
  bytes: number;
  caption?: string;
  /** HTML only: the WebView sandbox may load remote resources. */
  allowNetwork?: boolean;
  /** Absolute PC path. NEVER serialized onto the wire. */
  absPath: string;
  /** mtimeMs at push time (staleness guard). */
  mtimeMs: number;
}

/** `<session>.jsonl` → `<session>.files.jsonl` (sibling of the transcript). */
export function registryPathForSession(sessionFilePath: string): string {
  return sessionFilePath.replace(/\.jsonl$/i, "") + ".files.jsonl";
}

/**
 * Registry file backing the CURRENT session of `cwd`.
 *
 * Normal case: the sibling sidecar of the live transcript (newest `.jsonl`,
 * same resolution as the plan/128 index — the cwd-lock guarantees newest ==
 * live). Fallback when NO transcript exists yet (fresh pi before the first
 * commit, bare test harness): a deterministic per-cwd `.pending.files.jsonl`.
 * The pending sidecar is intentionally NOT merged into session history (no
 * transcript = no synced history), and a fetch against it 404s once a real
 * transcript appears — an early push without any attached owner is simply
 * lost, exactly like the pre-158 "shown but no peer connected" path.
 *
 * appendRegistryEntry / loadRegistryEntries take THIS path verbatim (no
 * further mapping) — one resolution, shared by every caller.
 */
export function registryTargetForCwd(cwd: string): string {
  const ref = resolveCurrentSessionFile(cwd);
  if (ref) return registryPathForSession(ref.path);
  return join(sessionsRoot(), encodeCwd(cwd), ".pending.files.jsonl");
}

/**
 * Append one push record to the REGISTRY PATH (as resolved by
 * `registryTargetForCwd` — taken verbatim, no further mapping). Sync + tiny:
 * one `stat` + one appendFileSync per show_file — the whole point of the
 * metadata-only flip is that a push costs no meaningful I/O. Registry write
 * failure FAILS the push (the tool reports an error): a ref without a
 * registry line would advertise bytes the fetch handler could never serve.
 */
export function appendRegistryEntry(registryPath: string, entry: AgentFileRegistryEntry): void {
  // The transcript's dir exists by construction; defensive mkdir for direct
  // callers in tests (and exotic races where the transcript was just removed).
  mkdirSync(dirname(registryPath), { recursive: true });
  appendFileSync(registryPath, JSON.stringify(entry) + "\n", "utf8");
}

function asString(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}
function asNumber(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

/** Parse one sidecar line; null when malformed (skip, never throw). */
function parseEntry(line: string): AgentFileRegistryEntry | null {
  if (!line.trim()) return null;
  let obj: unknown;
  try {
    obj = JSON.parse(line);
  } catch {
    return null;
  }
  if (!obj || typeof obj !== "object") return null;
  const o = obj as Record<string, unknown>;
  const fileId = asString(o.fileId);
  const kind = asString(o.kind);
  const absPath = asString(o.absPath);
  if (!fileId || !kind || !absPath) return null;
  const entry: AgentFileRegistryEntry = {
    fileId,
    ts: asNumber(o.ts),
    kind,
    bytes: asNumber(o.bytes),
    absPath,
    mtimeMs: asNumber(o.mtimeMs),
  };
  const mime = asString(o.mime);
  if (mime) entry.mime = mime;
  const name = asString(o.name);
  if (name) entry.name = name;
  const caption = asString(o.caption);
  if (caption) entry.caption = caption;
  if (o.allowNetwork === true) entry.allowNetwork = true;
  return entry;
}

/** Load every entry of one REGISTRY file (path verbatim), oldest first. Missing file → []. */
export function loadRegistryEntries(registryPath: string): AgentFileRegistryEntry[] {
  let raw: string;
  try {
    raw = readFileSync(registryPath, "utf8");
  } catch {
    return []; // no pushes yet (or transcript predates plan/158)
  }
  const out: AgentFileRegistryEntry[] = [];
  for (const line of raw.split("\n")) {
    const e = parseEntry(line);
    if (e) out.push(e);
  }
  return out;
}

/** Raw chunk size for `agent_file_payload` replies (plan/158 decision #3). */
export const AGENT_FILE_CHUNK_RAW_BYTES = 1024 * 1024;
