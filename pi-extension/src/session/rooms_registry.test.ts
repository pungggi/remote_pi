import { describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  pruneRooms,
  readRoomsRegistry,
  roomsRegistryPath,
  upsertRoom,
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

  it("survives a corrupt file (empty registry, no throw)", () => {
    const dir = mkdtempSync(join(tmpdir(), "rooms-corrupt-"));
    const corrupt = join(dir, "rooms.json");
    writeFileSync(corrupt, "{not json", "utf8");
    expect(readRoomsRegistry(corrupt).size).toBe(0);
    rmSync(dir, { recursive: true, force: true });
  });
});
