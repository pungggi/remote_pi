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

export interface RoomsRegistryEntry {
  /** Absolute cwd of the pi session that owns the room. */
  cwd: string;
  /** 12-char base64url room id (rooms.ts roomIdFor) — key of the map. */
  roomId: string;
  /** Epoch ms of the last relay connect that held this room. */
  lastSeenAt: number;
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
      out.set(roomId, { cwd: e.cwd, roomId, lastSeenAt });
    }
  }
  return out;
}

/** Upserts one entry and persists (best-effort; returns the entry). */
export function upsertRoom(
  entry: RoomsRegistryEntry,
  path: string = roomsRegistryPath(),
): RoomsRegistryEntry {
  const map = readRoomsRegistry(path);
  map.set(entry.roomId, { ...entry, lastSeenAt: Math.max(entry.lastSeenAt, map.get(entry.roomId)?.lastSeenAt ?? 0) });
  writeRoomsRegistry(map, path);
  return map.get(entry.roomId)!;
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
