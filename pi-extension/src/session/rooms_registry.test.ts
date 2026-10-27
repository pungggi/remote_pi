import { describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  pruneRooms,
  readRoomsRegistry,
  roomsRegistryPath,
  upsertRoom,
  upsertRoomMeta,
} from "./rooms_registry.js";

function tempPath(): string {
  return join(mkdtempSync(join(tmpdir(), "rooms-reg-")), "rooms.json");
}

describe("rooms_registry (plan/140)", () => {
  it("reads an empty registry when the file is missing", () => {
    const p = tempPath();
    expect(readRoomsRegistry(p).size).toBe(0);
  });

  it("upserts and reads back entries keyed by roomId", () => {
    const p = tempPath();
    upsertRoom({ cwd: "C:\\proj", roomId: "roomAAA", lastSeenAt: 1000 }, p);
    upsertRoom({ cwd: "C:\\other", roomId: "roomBBB", lastSeenAt: 2000 }, p);
    const map = readRoomsRegistry(p);
    expect(map.size).toBe(2);
    expect(map.get("roomAAA")).toEqual({ cwd: "C:\\proj", roomId: "roomAAA", lastSeenAt: 1000 });
  });

  it("upsert never moves lastSeenAt backwards", () => {
    const p = tempPath();
    upsertRoom({ cwd: "C:\\proj", roomId: "roomAAA", lastSeenAt: 5000 }, p);
    upsertRoom({ cwd: "C:\\proj", roomId: "roomAAA", lastSeenAt: 1000 }, p);
    expect(readRoomsRegistry(p).get("roomAAA")!.lastSeenAt).toBe(5000);
  });

  it("prunes entries older than the age window and persists the change", () => {
    const p = tempPath();
    upsertRoom({ cwd: "C:\\old", roomId: "oldRoom", lastSeenAt: 1 }, p);
    upsertRoom({ cwd: "C:\\new", roomId: "newRoom", lastSeenAt: Date.now() }, p);
    const removed = pruneRooms(60_000, p);
    expect(removed).toBe(1);
    const map = readRoomsRegistry(p);
    expect(map.has("oldRoom")).toBe(false);
    expect(map.has("newRoom")).toBe(true);
  });

  it("caps stored entries at the 200 newest (plan/140 C)", () => {
    const p = tempPath();
    const base = 1_000_000;
    for (let i = 0; i < 205; i++) {
      upsertRoom({ cwd: `C:\\p${i}`, roomId: `r${i}`, lastSeenAt: base + i }, p);
    }
    const map = readRoomsRegistry(p);
    expect(map.size).toBe(200);
    // Oldest five evicted, newest kept.
    expect(map.has("r0")).toBe(false);
    expect(map.has("r4")).toBe(false);
    expect(map.has("r5")).toBe(true);
    expect(map.has("r204")).toBe(true);
  });

  it("survives a corrupt file (empty registry, no throw)", () => {
    const dir = mkdtempSync(join(tmpdir(), "rooms-corrupt-"));
    const corrupt = join(dir, "rooms.json");
    writeFileSync(corrupt, "{not json", "utf8");
    expect(readRoomsRegistry(corrupt).size).toBe(0);
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("rooms_registry plan/152 exact session identity", () => {
  it("round-trips sessionId, preserves it on metadata writes, and replaces it on a new session", () => {
    const p = tempPath();
    upsertRoom({
      cwd: "C:\\proj",
      roomId: "roomAAA",
      lastSeenAt: 1000,
      sessionId: "session-old",
    }, p);
    expect(readRoomsRegistry(p).get("roomAAA")?.sessionId).toBe("session-old");

    upsertRoomMeta("roomAAA", { stats: { turns: 2, user_msgs: 3 } }, p);
    upsertRoom({ cwd: "C:\\proj", roomId: "roomAAA", lastSeenAt: 2000 }, p);
    expect(readRoomsRegistry(p).get("roomAAA")?.sessionId).toBe("session-old");

    upsertRoom({
      cwd: "C:\\proj",
      roomId: "roomAAA",
      lastSeenAt: 3000,
      sessionId: "session-new",
    }, p);
    expect(readRoomsRegistry(p).get("roomAAA")?.sessionId).toBe("session-new");
  });

  it("ignores blank or non-string persisted IDs", () => {
    const dir = mkdtempSync(join(tmpdir(), "rooms-session-id-corrupt-"));
    const p = join(dir, "rooms.json");
    writeFileSync(p, JSON.stringify({
      blank: { cwd: "C:\\proj", roomId: "blank", lastSeenAt: 1, sessionId: "  " },
      wrong: { cwd: "C:\\proj", roomId: "wrong", lastSeenAt: 1, sessionId: 42 },
    }), "utf8");
    const map = readRoomsRegistry(p);
    expect(map.get("blank")?.sessionId).toBeUndefined();
    expect(map.get("wrong")?.sessionId).toBeUndefined();
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("rooms_registry plan/149 fields (gh_ref / stats)", () => {
  it("round-trips ghRef and stats through the file", () => {
    const p = tempPath();
    upsertRoom(
      {
        cwd: "C:\proj",
        roomId: "roomAAA",
        lastSeenAt: 1000,
        ghRef: { pr: { number: 45, url: "https://github.com/o/r/pull/45", state: "open" }, source: "manual" },
        stats: { turns: 3, user_msgs: 7 },
      },
      p,
    );
    const e = readRoomsRegistry(p).get("roomAAA")!;
    expect(e.ghRef).toEqual({
      pr: { number: 45, url: "https://github.com/o/r/pull/45", state: "open" },
      issue: null,
      source: "manual",
    });
    expect(e.stats).toEqual({ turns: 3, user_msgs: 7 });
  });

  it("drops corrupt gh_ref / stats shapes instead of throwing", () => {
    const dir = mkdtempSync(join(tmpdir(), "rooms-meta-corrupt-"));
    const p = join(dir, "rooms.json");
    writeFileSync(
      p,
      JSON.stringify({
        roomAAA: { cwd: "C:\proj", roomId: "roomAAA", lastSeenAt: 1, ghRef: { pr: { number: "nope" } }, stats: { turns: "x" } },
      }),
      "utf8",
    );
    const e = readRoomsRegistry(p).get("roomAAA")!;
    expect(e.ghRef).toBeUndefined();
    expect(e.stats).toBeUndefined();
    rmSync(dir, { recursive: true, force: true });
  });

  it("upsertRoomMeta merges ONLY the plan/149 fields (cwd + lastSeenAt preserved)", () => {
    const p = tempPath();
    upsertRoom({ cwd: "C:\proj", roomId: "roomAAA", lastSeenAt: 5000 }, p);
    const updated = upsertRoomMeta("roomAAA", { stats: { turns: 4, user_msgs: 9 } }, p)!;
    expect(updated.cwd).toBe("C:\proj");
    expect(updated.lastSeenAt).toBe(5000);
    expect(updated.stats).toEqual({ turns: 4, user_msgs: 9 });
    expect(updated.ghRef ?? null).toBeNull();

    // A plain re-register (upsertRoom without the fields) preserves them.
    upsertRoom({ cwd: "C:\proj", roomId: "roomAAA", lastSeenAt: 9000 }, p);
    const after = readRoomsRegistry(p).get("roomAAA")!;
    expect(after.lastSeenAt).toBe(9000);
    expect(after.stats).toEqual({ turns: 4, user_msgs: 9 });
  });

  it("upsertRoomMeta unknown room → null; with ensureCwd it creates a fresh keeper-eligible entry", () => {
    const p = tempPath();
    expect(upsertRoomMeta("ghost", { ghRef: null }, p)).toBeNull();

    const created = upsertRoomMeta(
      "legacyRoom",
      { ghRef: { issue: { number: 12, url: "https://github.com/o/r/issues/12", state: null }, source: "manual" } },
      p,
      "C:\legacy",
    )!;
    expect(created.cwd).toBe("C:\legacy");
    expect(created.ghRef!.issue!.number).toBe(12);
    // Fresh lastSeenAt: not pruned as ancient on the next sweep.
    expect(created.lastSeenAt).toBeGreaterThan(Date.now() - 60_000);
  });

  it("clears ghRef via an explicit null patch", () => {
    const p = tempPath();
    upsertRoom(
      { cwd: "C:\proj", roomId: "roomAAA", lastSeenAt: 1, ghRef: { issue: { number: 12 }, source: "manual" } },
      p,
    );
    const updated = upsertRoomMeta("roomAAA", { ghRef: null }, p)!;
    expect(updated.ghRef ?? null).toBeNull();
  });
});
