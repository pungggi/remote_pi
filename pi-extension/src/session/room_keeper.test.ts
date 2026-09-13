import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RoomKeeper, sessionStartedAtFromFileName, type KeeperRelayClient } from "./room_keeper.js";
import { encodeCwd } from "./file_index.js";
import { upsertRoom } from "./rooms_registry.js";
import { generateEd25519Keypair } from "../pairing/crypto.js";
import { RoomAlreadyOpenError } from "../transport/relay_client.js";

/**
 * Plan/140 A — room keeper. All relay/storage surfaces are faked; only the
 * paging (file_index) + mapper (dynamic import) run for real against a temp
 * transcript.
 */

const PHONE_PEER = "phone-peer-id";

class FakeRelay implements KeeperRelayClient {
  readonly messageListeners = new Set<(line: string) => void>();
  readonly closeListeners = new Set<() => void>();
  readonly sent: string[] = [];
  connectCalls: Array<{ roomId?: string; roomMeta?: Record<string, unknown> }> = [];
  failWith: Error | null = null;
  closed = false;

  async connect(options?: { roomId?: string; roomMeta?: Record<string, unknown> }): Promise<void> {
    this.connectCalls.push(options ?? {});
    if (this.failWith) throw this.failWith;
  }

  send(line: string): void {
    this.sent.push(line);
  }

  close(): void {
    this.closed = true;
    this.closeListeners.forEach((f) => f());
  }

  emitMessage(line: string): void {
    this.messageListeners.forEach((f) => f(line));
  }

  on(event: "message" | "close", fn: never): unknown {
    if (event === "message") this.messageListeners.add(fn as unknown as (line: string) => void);
    else this.closeListeners.add(fn as unknown as () => void);
    return this;
  }

  off(_event: string, fn: (...args: never[]) => void): unknown {
    this.messageListeners.delete(fn as unknown as (line: string) => void);
    this.closeListeners.delete(fn as unknown as () => void);
    return this;
  }
}

function outerLine(peer: string, payload: unknown): string {
  return JSON.stringify({ peer, room: "keptRoom", ct: Buffer.from(JSON.stringify(payload)).toString("base64") });
}

function decodeSent(sent: string): Record<string, unknown> {
  const outer = JSON.parse(sent) as { ct: string };
  return JSON.parse(Buffer.from(outer.ct, "base64").toString("utf8")) as Record<string, unknown>;
}

const cleanups: Array<() => void> = [];
afterEach(() => {
  for (const fn of cleanups.splice(0)) fn();
});

function makeKeeper(over: Partial<ConstructorParameters<typeof RoomKeeper>[0]> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "keeper-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const cwd = join(dir, "proj");
  const agentDir = join(dir, "agent-home");
  // sessionsRoot() reads PI_CODING_AGENT_DIR at CALL time.
  process.env["PI_CODING_AGENT_DIR"] = agentDir;
  cleanups.push(() => { delete process.env["PI_CODING_AGENT_DIR"]; });

  const registryPath = join(dir, "rooms.json");
  const fake = new FakeRelay();
  const keeper = new RoomKeeper({
    relayUrl: "http://127.0.0.1:3000",
    keypair: generateEd25519Keypair(),
    registryPath,
    listPairedPeers: async () => [PHONE_PEER],
    makeClient: () => fake as unknown as KeeperRelayClient,
    log: (line) => console.error("[keeper-test]", line),
    ...over,
  });
  return { keeper, fake, dir, cwd, registryPath };
}

function writeTranscript(agentDir: string, cwd: string): void {
  const sessDir = join(agentDir, "sessions", encodeCwd(cwd));
  mkdirSync(sessDir, { recursive: true });
  const file = join(sessDir, "2026-09-05T13-24-04-555Z_testsession.jsonl");
  const lines = [
    JSON.stringify({ type: "message", message: { timestamp: 1000, role: "user", content: "hello" } }),
    JSON.stringify({ type: "message", message: { timestamp: 2000, role: "assistant", content: [{ type: "text", text: "world" }] } }),
    "",
  ].join("\n");
  writeFileSync(file, lines, "utf8");
}

describe("sessionStartedAtFromFileName", () => {
  it("parses the session-start epoch from a transcript file name", () => {
    const ms = sessionStartedAtFromFileName("2026-09-05T13-24-04-555Z_uuid.jsonl");
    expect(ms).toBe(Date.UTC(2026, 8, 5, 13, 24, 4, 555));
  });
  it("returns 0 for unparsable names", () => {
    expect(sessionStartedAtFromFileName("whatever.jsonl")).toBe(0);
  });
});

describe("RoomKeeper (plan/140)", () => {
  it("holds a fresh registry room and answers session_sync from the durable transcript with offline:true", async () => {
    const { keeper, fake, dir, cwd, registryPath } = makeKeeper();
    const agentDir = process.env["PI_CODING_AGENT_DIR"]!;
    writeTranscript(agentDir, cwd);
    upsertRoom({ cwd, roomId: "keptRoom", lastSeenAt: Date.now() }, registryPath);

    await keeper.start();
    expect(fake.connectCalls.length).toBe(1);
    expect(fake.connectCalls[0]!.roomId).toBe("keptRoom");
    expect(fake.connectCalls[0]!.roomMeta).toMatchObject({ cwd });

    // Phone asks for history (unsigned frame — ratchet empty, legacy path).
    // The mapper's dynamic import loads the whole ext module — warm it first
    // (mirrors RoomKeeper.start's own pre-warm) and allow real-world latency.
    await import("../index.js");
    fake.emitMessage(outerLine(PHONE_PEER, { type: "session_sync", id: "sync-1" }));
    await new Promise((r) => setTimeout(r, 1000)); // serve is async (import + disk)

    expect(fake.sent.length).toBeGreaterThan(0);
    const reply = decodeSent(fake.sent[fake.sent.length - 1]!);
    expect(reply["type"]).toBe("session_history");
    expect(reply["in_reply_to"]).toBe("sync-1");
    expect(reply["offline"]).toBe(true);
    // File-derived start time (NOT the keeper's clock) — the app's
    // new-session guard must never wipe the chat on keeper takeover.
    expect(reply["session_started_at"]).toBe(Date.UTC(2026, 8, 5, 13, 24, 4, 555));
    const events = reply["events"] as Array<{ type?: string }>;
    expect(events.length).toBeGreaterThanOrEqual(2);
    expect(events[0]!.type).toBe("user_input");
    void dir;
    await keeper.stop();
  });

  it("ignores envelopes from unpaired senders", async () => {
    const { keeper, fake, cwd, registryPath } = makeKeeper();
    upsertRoom({ cwd, roomId: "keptRoom", lastSeenAt: Date.now() }, registryPath);
    await keeper.start();
    fake.emitMessage(outerLine("stranger", { type: "session_sync", id: "s" }));
    await new Promise((r) => setTimeout(r, 100));
    expect(fake.sent.length).toBe(0);
    await keeper.stop();
  });

  it("backs off (no retry storm) when the room is held — RoomAlreadyOpen", async () => {
    const { keeper, fake, cwd, registryPath } = makeKeeper({ retryMs: 10_000 });
    upsertRoom({ cwd, roomId: "keptRoom", lastSeenAt: Date.now() }, registryPath);
    fake.failWith = new RoomAlreadyOpenError("keptRoom");
    await keeper.start();
    expect(fake.connectCalls.length).toBe(1);
    await new Promise((r) => setTimeout(r, 50));
    expect(fake.connectCalls.length).toBe(1); // single attempt, timer armed
    await keeper.stop();
  });

  it("holds at most maxRooms dark rooms, newest first (plan/140 C)", async () => {
    const { keeper, fake, registryPath } = makeKeeper({ maxRooms: 2 });
    const now = Date.now();
    upsertRoom({ cwd: "C:\\a", roomId: "roomA", lastSeenAt: now - 3000 }, registryPath);
    upsertRoom({ cwd: "C:\\b", roomId: "roomB", lastSeenAt: now - 2000 }, registryPath);
    upsertRoom({ cwd: "C:\\c", roomId: "roomC", lastSeenAt: now - 1000 }, registryPath);
    await keeper.start();
    // The two NEWEST are held; the oldest is not.
    const heldRooms = fake.connectCalls.map((c) => c.roomId).sort();
    expect(heldRooms).toEqual(["roomB", "roomC"]);
    // The keeper marker rides the hello so the relay can announce the room
    // as a durable-history mirror (app badges it "Pi offline / archive").
    expect(fake.connectCalls[0]!.roomMeta).toMatchObject({ keeper: true });
    await keeper.stop();
  });

  it("maxRooms 0 disables holding entirely", async () => {
    const { keeper, fake, registryPath } = makeKeeper({ maxRooms: 0 });
    upsertRoom({ cwd: "C:\\a", roomId: "roomA", lastSeenAt: Date.now() }, registryPath);
    await keeper.start();
    expect(fake.connectCalls.length).toBe(0);
    await keeper.stop();
  });

  it("dropRoom releases the connection and reports it held the room", async () => {
    const { keeper, fake, cwd, registryPath } = makeKeeper();
    upsertRoom({ cwd, roomId: "keptRoom", lastSeenAt: Date.now() }, registryPath);
    await keeper.start();
    expect(keeper.dropRoom("keptRoom")).toBe(true);
    expect(fake.closed).toBe(true);
    expect(keeper.dropRoom("keptRoom")).toBe(false);
    await keeper.stop();
  });

  it("releases stale rooms on sweep", async () => {
    const { keeper, fake, cwd, registryPath } = makeKeeper({ sweepIntervalMs: 30 });
    upsertRoom({ cwd, roomId: "keptRoom", lastSeenAt: Date.now() }, registryPath);
    await keeper.start();
    expect(fake.connectCalls.length).toBe(1);
    // Age the entry out of the window.
    const aged: Record<string, unknown> = {
      keptRoom: { cwd, roomId: "keptRoom", lastSeenAt: 1 },
    };
    writeFileSync(registryPath, JSON.stringify(aged), "utf8");
    await new Promise((r) => setTimeout(r, 80));
    expect(fake.closed).toBe(true);
    await keeper.stop();
  });
});
