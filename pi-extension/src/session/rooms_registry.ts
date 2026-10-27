/**
 * Plan/140 — rooms registry (`~/.pi/piper/rooms.json`).
 *
 * Every extension instance (interactive session or daemon) records the
 * (cwd → relay room) mapping here once its relay connection is up. The
 * supervisor's room-keeper (plan/140 A) reads this list to decide which
 * dark rooms deserve a keeper connection serving durable history to
 * paired phones.
 *
 * Design notes:
 *  - The registry is *observational*, not authoritative: entries carry a
 *    `lastSeenAt` and are pruned by age. Nothing breaks when the file is
 *    missing/corrupt — the keeper then simply has nothing to keep.
 *  - Writes are best-effort, synchronous, whole-file (small list, low
 *    churn: one write per relay connect per session).
 *  - No decoded-cwd guessing anywhere: the extension KNOWS its cwd and
 *    room id, so the mapping is exact (session-folder names are not
 *    reversible — `:`/`\`/`/` all encode to `-`).
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { WireGhRef, WireSessionStats } from "../protocol/types.js";

export interface RoomsRegistryEntry {
  /** Absolute cwd of the pi session that owns the room. */
  cwd: string;
  /** 12-char base64url room id (rooms.ts roomIdFor) — key of the map. */
  roomId: string;
  /** Epoch ms of the last relay connect that held this room. */
  lastSeenAt: number;
  /** Plan/152 — exact Pi session ID used to resume this room after it goes
   *  offline. Kept PC-side; the phone only supplies the room's cwd + name. */
  sessionId?: string;
  /** Plan/149 — GitHub ref linked to the session (manual/gh-sourced).
   *  Durable source of truth for offline + keeper tiles. */
  ghRef?: WireGhRef | null;
  /** Plan/149 — activity counters (turns / user_msgs). Updated at turn
   *  boundaries by the live session; served by the keeper while dark. */
  stats?: WireSessionStats | null;
}

/** Mirror of the on-disk shape: a plain object keyed by roomId. */
type RoomsRegistryFile = Record<string, RoomsRegistryEntry>;

export function piperHomeDir(): string {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  return join(root, ".pi", "piper");
}

export function roomsRegistryPath(): string {
  return join(piperHomeDir(), "rooms.json");
}

/** Reads the registry; missing/corrupt file → empty map (never throws). */
export function readRoomsRegistry(path: string = roomsRegistryPath()): Map<string, RoomsRegistryEntry> {
  if (!existsSync(path)) return new Map();
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return new Map();
  }
  let obj: unknown;
  try {
    obj = JSON.parse(raw);
  } catch {
    return new Map();
  }
  const out = new Map<string, RoomsRegistryEntry>();
  if (obj && typeof obj === "object") {
    for (const [roomId, v] of Object.entries(obj as Record<string, unknown>)) {
      if (!v || typeof v !== "object") continue;
      const e = v as Partial<RoomsRegistryEntry>;
      if (typeof e.cwd !== "string" || typeof e.roomId !== "string") continue;
      const lastSeenAt = typeof e.lastSeenAt === "number" ? e.lastSeenAt : 0;
      const out2: RoomsRegistryEntry = { cwd: e.cwd, roomId, lastSeenAt };
      if (typeof e.sessionId === "string" && e.sessionId.trim()) {
        out2.sessionId = e.sessionId.trim();
      }
      const ghRef = sanitizeGhRef(e.ghRef);
      const stats = sanitizeStats(e.stats);
      if (ghRef) out2.ghRef = ghRef;
      if (stats) out2.stats = stats;
      out.set(roomId, out2);
    }
  }
  return out;
}

/** Best-effort shape guard for a registry-loaded ref (corrupt file → null). */
function sanitizeGhRef(v: unknown): WireGhRef | null {
  if (!v || typeof v !== "object") return null;
  const r = v as Partial<WireGhRef>;
  const pr = sanitizeSlot(r.pr);
  const issue = sanitizeSlot(r.issue);
  if (!pr && !issue) return null;
  return {
    pr,
    issue,
    source: typeof r.source === "string" ? r.source : null,
  };
}

function sanitizeSlot(v: unknown): WireGhRef["pr"] {
  if (!v || typeof v !== "object") return null;
  const s = v as { number?: unknown; url?: unknown; state?: unknown };
  if (typeof s.number !== "number" || !Number.isFinite(s.number)) return null;
  return {
    number: s.number,
    url: typeof s.url === "string" ? s.url : null,
    state: typeof s.state === "string" ? s.state : null,
  };
}

/** Best-effort shape guard for registry-loaded stats (corrupt file → null). */
function sanitizeStats(v: unknown): WireSessionStats | null {
  if (!v || typeof v !== "object") return null;
  const s = v as { turns?: unknown; user_msgs?: unknown };
  if (typeof s.turns !== "number" || typeof s.user_msgs !== "number") return null;
  return { turns: s.turns, user_msgs: s.user_msgs };
}

/** Upserts one entry and persists (best-effort; returns the entry). */
export function upsertRoom(
  entry: RoomsRegistryEntry,
  path: string = roomsRegistryPath(),
): RoomsRegistryEntry {
  const map = readRoomsRegistry(path);
  const prev = map.get(entry.roomId);
  map.set(entry.roomId, {
    ...entry,
    lastSeenAt: Math.max(entry.lastSeenAt, prev?.lastSeenAt ?? 0),
    sessionId: entry.sessionId !== undefined ? entry.sessionId : prev?.sessionId,
    ghRef: entry.ghRef !== undefined ? entry.ghRef : prev?.ghRef ?? null,
    stats: entry.stats !== undefined ? entry.stats : prev?.stats ?? null,
  });
  writeRoomsRegistry(map, path);
  return map.get(entry.roomId)!;
}

/** Plan/149 — merge ONLY the gh_ref / stats fields into an existing entry
 *  (creating a bare entry when `ensureCwd` is given and the room was never
 *  registered — e.g. a manual link from the device daemon for a room whose
 *  last connect predates the registry write). `lastSeenAt` and `cwd` of an
 *  existing entry are preserved: only the plan/149 fields move. Returns null
 *  when the room is unknown and no `ensureCwd` was provided (caller decides). */
export function upsertRoomMeta(
  roomId: string,
  patch: { ghRef?: WireGhRef | null; stats?: WireSessionStats | null },
  path: string = roomsRegistryPath(),
  ensureCwd?: string,
): RoomsRegistryEntry | null {
  const map = readRoomsRegistry(path);
  const prev = map.get(roomId);
  if (!prev) {
    if (!ensureCwd) return null;
    const created: RoomsRegistryEntry = {
      cwd: ensureCwd,
      roomId,
      // A user-linked room is worth keeping: a fresh lastSeenAt makes it
      // keeper-eligible (durable history + the ref while dark) instead of
      // being pruned as ancient on the next sweep.
      lastSeenAt: Date.now(),
      ghRef: patch.ghRef !== undefined ? patch.ghRef : null,
      stats: patch.stats !== undefined ? patch.stats : null,
    };
    map.set(roomId, created);
    writeRoomsRegistry(map, path);
    return created;
  }
  const next: RoomsRegistryEntry = {
    ...prev,
    ghRef: patch.ghRef !== undefined ? patch.ghRef : prev.ghRef,
    stats: patch.stats !== undefined ? patch.stats : prev.stats,
  };
  map.set(roomId, next);
  writeRoomsRegistry(map, path);
  return next;
}

/** Drops entries older than `maxAgeMs` (by lastSeenAt). Persists when changed. */
export function pruneRooms(maxAgeMs: number, path: string = roomsRegistryPath()): number {
  const map = readRoomsRegistry(path);
  const cutoff = Date.now() - maxAgeMs;
  let removed = 0;
  for (const [roomId, e] of map) {
    if (e.lastSeenAt < cutoff) {
      map.delete(roomId);
      removed++;
    }
  }
  if (removed > 0) writeRoomsRegistry(map, path);
  return removed;
}

/** Hard cap on stored rooms (newest by lastSeenAt kept). Bounds the file
 *  and the keeper's candidate pool — the 2026-09-08 fleet registered 207
 *  rooms in ONE day, and an unbounded registry would keep growing. */
const MAX_REGISTRY_ENTRIES = 200;

function writeRoomsRegistry(map: Map<string, RoomsRegistryEntry>, path: string): void {
  try {
    mkdirSync(dirname(path), { recursive: true });
    if (map.size > MAX_REGISTRY_ENTRIES) {
      const sorted = [...map.values()].sort((a, b) => b.lastSeenAt - a.lastSeenAt);
      const keep = new Set(sorted.slice(0, MAX_REGISTRY_ENTRIES).map((e) => e.roomId));
      for (const roomId of [...map.keys()]) {
        if (!keep.has(roomId)) map.delete(roomId);
      }
    }
    const file: RoomsRegistryFile = {};
    for (const [roomId, e] of map) file[roomId] = e;
    writeFileSync(path, JSON.stringify(file, null, 2) + "\n", "utf8");
  } catch {
    // Best-effort by design: an unwritable home must never take down a
    // session's relay connect path.
  }
}
