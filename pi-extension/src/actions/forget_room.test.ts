/**
 * Plan/158 — forget_room handler tests.
 *
 * The handler is the PC-side half of "Clean up session": prune the rooms.json
 * entry (the keeper then releases the room on its next sweep, so the phone
 * tile never resurrects) and optionally delete the chat-history transcripts.
 * These tests pin the reply contract + the deletion precision rules:
 *  - known sessionId → only that session's transcript file disappears;
 *  - unknown sessionId → the folder's top-level transcripts disappear;
 *  - missing folder / missing file → honest "kept: …" notes, never a failure;
 *  - unknown room + delete_history → ok:true with a registry/history note;
 *  - registry write failure → ok:false, nothing else claimed.
 */
import { afterEach, describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ServerMessage } from "../protocol/types.js";
import type { ActionReplySender } from "./handlers.js";
import { deleteRoomHistory, handleForgetRoom } from "./forget_room.js";
import { roomsRegistryPath, upsertRoom } from "../session/rooms_registry.js";

// ── isolated $HOME per test (rooms.json + transcripts both live under it) ──
let home = "";
const prevEnv: Record<string, string | undefined> = {};

function isolateHome(): string {
  home = mkdtempSync(join(tmpdir(), "forget-room-"));
  prevEnv["REMOTE_PI_HOME"] = process.env["REMOTE_PI_HOME"];
  prevEnv["PI_CODING_AGENT_DIR"] = process.env["PI_CODING_AGENT_DIR"];
  process.env["REMOTE_PI_HOME"] = home;
  // sessionsRoot() = $PI_CODING_AGENT_DIR ?? <home>/.pi/agent + /sessions.
  process.env["PI_CODING_AGENT_DIR"] = join(home, ".pi", "agent");
  return home;
}

afterEach(() => {
  if (prevEnv["REMOTE_PI_HOME"] === undefined) delete process.env["REMOTE_PI_HOME"];
  else process.env["REMOTE_PI_HOME"] = prevEnv["REMOTE_PI_HOME"];
  if (prevEnv["PI_CODING_AGENT_DIR"] === undefined) delete process.env["PI_CODING_AGENT_DIR"];
  else process.env["PI_CODING_AGENT_DIR"] = prevEnv["PI_CODING_AGENT_DIR"];
  if (home) {
    try {
      rmSync(home, { recursive: true, force: true });
    } catch {
      /* Windows file-lock races in CI — ignore */
    }
    home = "";
  }
});

/** Records every reply so tests assert on the last one. */
function recorder(): ActionReplySender & { sent: ServerMessage[] } {
  const sent: ServerMessage[] = [];
  return { send: (m) => sent.push(m), sent };
}

/** encodeCwd port (the test must not depend on the module under test). */
function enc(cwd: string): string {
  return `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
}

describe("deleteRoomHistory (plan/158)", () => {
  it("deletes exactly the sessionId's transcript when known", () => {
    const root = isolateHome();
    const dir = join(root, ".pi", "agent", "sessions", enc("C:\\proj"));
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "2026-11-01T10-00-00-000Z_s-abc.jsonl"), "{}\n");
    writeFileSync(join(dir, "2026-11-02T10-00-00-000Z_s-other.jsonl"), "{}\n");

    const res = deleteRoomHistory("C:\\proj", "s-abc");
    expect(res.removed).toBe(true);
    expect(res.note).toContain("1 transcript");
    // The OTHER session's transcript survives — the whole point of the
    // sessionId-precise path.
    expect(dirListing(dir)).toEqual(["2026-11-02T10-00-00-000Z_s-other.jsonl"]);
  });

  it("falls back to all top-level transcripts when sessionId is unknown", () => {
    const root = isolateHome();
    const dir = join(root, ".pi", "agent", "sessions", enc("C:\\legacy"));
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "a.jsonl"), "{}\n");
    writeFileSync(join(dir, "b.jsonl"), "{}\n");
    writeFileSync(join(dir, "not-a-transcript.txt"), "x");

    const res = deleteRoomHistory("C:\\legacy", undefined);
    expect(res.removed).toBe(true);
    expect(dirListing(dir)).toEqual(["not-a-transcript.txt"]);
  });

  it("reports honest notes when nothing is there", () => {
    isolateHome();
    expect(deleteRoomHistory("C:\\missing", "s-1").note).toContain("no chat history folder");
    const root = join(process.env["PI_CODING_AGENT_DIR"]!);
    const dir = join(root, "sessions", enc("C:\\empty"));
    mkdirSync(dir, { recursive: true });
    expect(deleteRoomHistory("C:\\empty", "s-none").note).toContain("not found");
    expect(deleteRoomHistory("C:\\empty", undefined).note).toContain("no transcript files");
  });
});

/** Directory listing helper (sorted, for stable asserts). */
function dirListing(dir: string): string[] {
  return readdirSync(dir).sort();
}

describe("handleForgetRoom (plan/158)", () => {
  it("prunes the registry entry and reports it", () => {
    isolateHome();
    const p = roomsRegistryPath();
    upsertRoom({ cwd: "C:\\proj", roomId: "roomDel", lastSeenAt: 1, sessionId: "s-1" }, p);
    const sender = recorder();
    handleForgetRoom(sender, { type: "forget_room_request", id: "r1", room_id: "roomDel" });
    const reply = sender.sent[0] as Extract<ServerMessage, { type: "forget_room_result" }>;
    expect(reply.ok).toBe(true);
    expect(reply.registry_removed).toBe(true);
    expect(reply.history_removed).toBeUndefined();
    expect(reply.history_note).toBeUndefined();
  });

  it("with delete_history: exact sessionId deletion + note", () => {
    const root = isolateHome();
    const p = roomsRegistryPath();
    upsertRoom({ cwd: "C:\\proj", roomId: "roomDel", lastSeenAt: 1, sessionId: "s-xyz" }, p);
    const dir = join(root, ".pi", "agent", "sessions", enc("C:\\proj"));
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "t_s-xyz.jsonl"), "{}\n");

    const sender = recorder();
    handleForgetRoom(sender, {
      type: "forget_room_request",
      id: "r2",
      room_id: "roomDel",
      delete_history: true,
    });
    const reply = sender.sent[0] as Extract<ServerMessage, { type: "forget_room_result" }>;
    expect(reply.ok).toBe(true);
    expect(reply.registry_removed).toBe(true);
    expect(reply.history_removed).toBe(true);
    expect(reply.history_note).toContain("deleted");
  });

  it("unknown room + delete_history: ok:true, honest note (idempotent retry)", () => {
    isolateHome();
    const sender = recorder();
    handleForgetRoom(sender, {
      type: "forget_room_request",
      id: "r3",
      room_id: "ghost",
      delete_history: true,
    });
    const reply = sender.sent[0] as Extract<ServerMessage, { type: "forget_room_result" }>;
    expect(reply.ok).toBe(true);
    expect(reply.registry_removed).toBe(false);
    expect(reply.history_removed).toBe(false);
    expect(reply.history_note).toContain("never registered");
  });

  it("already-forgotten room without history: ok:true, registry_removed:false", () => {
    isolateHome();
    const sender = recorder();
    handleForgetRoom(sender, { type: "forget_room_request", id: "r4", room_id: "ghost" });
    const reply = sender.sent[0] as Extract<ServerMessage, { type: "forget_room_result" }>;
    expect(reply.ok).toBe(true);
    expect(reply.registry_removed).toBe(false);
  });
});
