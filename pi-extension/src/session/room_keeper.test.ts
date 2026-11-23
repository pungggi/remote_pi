import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RoomKeeper, sessionStartedAtFromFileName, type KeeperRelayClient } from "./room_keeper.js";
import { encodeCwd } from "./file_index.js";
import { upsertRoom, upsertRoomMeta } from "./rooms_registry.js";
import { generateEd25519Keypair } from "../pairing/crypto.js";
import { RoomAlreadyOpenError } from "../transport/relay_client.js";
import type { WireGitStatus } from "../protocol/types.js";

/**
 * Plan/140 A — room keeper. All relay/storage surfaces are faked; only the
 * paging (file_index) + mapper (dynamic import) run for real against a temp
 * transcript.
 */

const PHONE_PEER = "phone-peer-id";
const TEST_GIT: WireGitStatus = {
  branch: "main",
  repository: "pungggi/pi-reflex",
  upstream: "origin/main",
  aheadBy: 0,
  behindBy: 0,
  upstreamGone: false,
  indexAdded: 0,
  indexModified: 0,
  indexDeleted: 0,
  indexUnmerged: 0,
  workingAdded: 0,
  workingModified: 0,
  workingDeleted: 0,
  workingUnmerged: 0,
  stashCount: 0,
};

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

  /** Plan/149 — captured control frames (room_meta_update pushes). */
  readonly controlFrames: object[] = [];

  sendControl(frame: object): void {
    this.controlFrames.push(frame);
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

function outerLineIn(room: string, peer: string, payload: unknown): string {
  return JSON.stringify({ peer, room, ct: Buffer.from(JSON.stringify(payload)).toString("base64") });
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

/** Poll until `cond` passes, up to `ms`. Fixed sleeps flake under
 * full-suite/CI load when the code under test is async (dynamic import +
 * disk) — this test suite proved that the hard way during PR #107's live
 * e2e (room_keeper failed 3/3 on a busy box, green when idle). */
async function waitFor(cond: () => void, ms = 15_000, stepMs = 50): Promise<void> {
  const deadline = Date.now() + ms;
  for (;;) {
    try {
      cond();
      return;
    } catch (e) {
      if (Date.now() > deadline) throw e;
    }
    await new Promise((r) => setTimeout(r, stepMs));
  }
}

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
    // The mapper's dynamic import loads the runtime module — warm it first
    // (mirrors RoomKeeper.start's own pre-warm) and allow real-world latency.
    await import("../main.js");
    fake.emitMessage(outerLine(PHONE_PEER, { type: "session_sync", id: "sync-1" }));
    // serve is async (import + disk) — poll, don't sleep: a fixed 1 s wait
    // flaked under load (see waitFor doc above).
    await waitFor(() => {
      expect(fake.sent.length).toBeGreaterThan(0);
    });
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

  it("announces git / gh_ref / stats and pushes refreshes when they change", async () => {
    const { keeper, fake, cwd, registryPath } = makeKeeper({ sweepIntervalMs: 30 });
    upsertRoom(
      {
        cwd,
        roomId: "keptRoom",
        lastSeenAt: Date.now(),
        git: TEST_GIT,
        ghRef: { pr: { number: 45, url: "https://github.com/o/r/pull/45", state: null }, issue: null, source: "manual" },
        stats: { turns: 3, user_msgs: 7 },
      },
      registryPath,
    );
    await keeper.start();

    // The hello carries the registry's slot content…
    expect(fake.connectCalls[0]!.roomMeta).toMatchObject({
      keeper: true,
      git: { repository: "pungggi/pi-reflex" },
      gh_ref: { pr: { number: 45 } },
      stats: { turns: 3, user_msgs: 7 },
    });
    expect(fake.controlFrames.length).toBe(0); // nothing changed yet

    // …a manual link / turn counter lands in the registry while we hold the
    // room: the next sweep pushes a room_meta_update (presence, not a
    // broadcast) and re-baselines.
    upsertRoomMeta(
      "keptRoom",
      {
        git: { ...TEST_GIT, repository: "pungggi/other", aheadBy: 3 },
        ghRef: { pr: { number: 46, url: "https://github.com/o/r/pull/46", state: "OPEN" }, issue: null, source: "manual" },
        stats: { turns: 4, user_msgs: 8 },
      },
      registryPath,
    );
    await new Promise((r) => setTimeout(r, 80));
    expect(fake.controlFrames.length).toBe(1);
    const frame = fake.controlFrames[0] as { type?: string; room_id?: string; meta?: Record<string, unknown> };
    expect(frame.type).toBe("room_meta_update");
    expect(frame.room_id).toBe("keptRoom");
    expect(frame.meta!["gh_ref"]).toMatchObject({ pr: { number: 46 } });
    expect(frame.meta!["stats"]).toEqual({ turns: 4, user_msgs: 8 });
    expect(frame.meta!["git"]).toMatchObject({
      repository: "pungggi/other",
      aheadBy: 3,
    });

    // No further pushes without another change.
    await new Promise((r) => setTimeout(r, 80));
    expect(fake.controlFrames.length).toBe(1);
    await keeper.stop();
  });
});

describe("RoomKeeper — device-room control presence (plan/168)", () => {
  /** Per-room fakes: the shared makeKeeper returns ONE fake, but the device
   *  room + session rooms must each get their own connection. */
  function makeMultiKeeper(over: Partial<ConstructorParameters<typeof RoomKeeper>[0]> = {}) {
    const dir = mkdtempSync(join(tmpdir(), "keeper168-"));
    cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
    const registryPath = join(dir, "rooms.json");
    const fakes: FakeRelay[] = [];
    const keeper = new RoomKeeper({
      relayUrl: "http://127.0.0.1:3000",
      keypair: generateEd25519Keypair(),
      registryPath,
      listPairedPeers: async () => [PHONE_PEER],
      makeClient: () => {
        const f = new FakeRelay();
        fakes.push(f);
        return f as unknown as KeeperRelayClient;
      },
      log: (line) => console.error("[keeper168-test]", line),
      ...over,
    });
    /** The fake that connected as `roomId` (connectCalls[0] of that fake). */
    const fakeFor = (roomId: string): FakeRelay =>
      fakes.find((f) => f.connectCalls.some((c) => c.roomId === roomId))!;
    return { keeper, fakes, fakeFor, dir, registryPath };
  }

  it("claims the device room control-only (no roomMeta) and pinned outside maxRooms/maxAge", async () => {
    const { keeper, fakes, fakeFor, registryPath } = makeMultiKeeper({ maxRooms: 1 });
    const now = Date.now();
    upsertRoom({ cwd: "C:\\old", roomId: "roomA", lastSeenAt: now - 3000 }, registryPath);
    upsertRoom({ cwd: "C:\\new", roomId: "roomB", lastSeenAt: now - 1000 }, registryPath);
    // Stale by any session-room measure — still pinned.
    upsertRoom({ cwd: "C:\\home", roomId: "device", lastSeenAt: 1 }, registryPath);
    await keeper.start();

    const dev = fakeFor("device");
    expect(dev.connectCalls.length).toBe(1);
    expect(dev.connectCalls[0]!.roomId).toBe("device");
    // Control-only: NOTHING announced — no phantom session-shaped room.
    expect(dev.connectCalls[0]!.roomMeta).toBeUndefined();

    // Pinned outside the bound: maxRooms 1 holds newest session room + device.
    expect(() => fakeFor("device")).not.toThrow();
    expect(() => fakeFor("roomB")).not.toThrow();
    // …and NOT the older session room (device didn't consume the slot).
    expect(fakes.some((f) => f.connectCalls.some((c) => c.roomId === "roomA"))).toBe(false);
    await keeper.stop();
  });

  it("serves daemon_control restart via the supervisor callback and replies action_ok", async () => {
    const seen: Array<{ op: string; daemon?: string }> = [];
    const { keeper, fakeFor, registryPath } = makeMultiKeeper({
      onDaemonControl: async (req) => {
        seen.push(req);
        return { op: "restart", daemon: "device", restarted: true, pid: 4242 };
      },
    });
    upsertRoom({ cwd: "C:\\home", roomId: "device", lastSeenAt: Date.now() }, registryPath);
    await keeper.start();

    const dev = fakeFor("device");
    dev.emitMessage(outerLineIn("device", PHONE_PEER, { type: "daemon_control", id: "dc-1", op: "restart" }));
    await waitFor(() => {
      expect(dev.sent.length).toBeGreaterThan(0);
    });
    const reply = decodeSent(dev.sent[dev.sent.length - 1]!);
    expect(reply["type"]).toBe("action_ok");
    expect(reply["in_reply_to"]).toBe("dc-1");
    expect(reply["action"]).toBe("daemon_control");
    expect(reply["result"]).toMatchObject({ op: "restart", restarted: true, pid: 4242 });
    expect(seen).toEqual([{ op: "restart", daemon: undefined }]);
    await keeper.stop();
  });

  it("replies action_error for unknown ops, a throwing handler, and a missing handler", async () => {
    const { keeper, fakeFor, registryPath } = makeMultiKeeper({
      onDaemonControl: async () => {
        throw new Error("boom: fleet on fire");
      },
    });
    upsertRoom({ cwd: "C:\\home", roomId: "device", lastSeenAt: Date.now() }, registryPath);
    await keeper.start();
    const dev = fakeFor("device");

    dev.emitMessage(outerLineIn("device", PHONE_PEER, { type: "daemon_control", id: "dc-2", op: "explode" }));
    await waitFor(() => expect(dev.sent.length).toBe(1));
    expect(decodeSent(dev.sent[0]!)).toMatchObject({
      type: "action_error", in_reply_to: "dc-2", action: "daemon_control",
      error: expect.stringContaining("unknown daemon_control op"),
    });

    dev.emitMessage(outerLineIn("device", PHONE_PEER, { type: "daemon_control", id: "dc-3", op: "restart" }));
    await waitFor(() => expect(dev.sent.length).toBe(2));
    expect(decodeSent(dev.sent[1]!)).toMatchObject({
      type: "action_error", in_reply_to: "dc-3", action: "daemon_control",
      error: expect.stringContaining("fleet on fire"),
    });
    await keeper.stop();

    // No handler wired (standalone keeper / tests): explicit error, no silence.
    const bare = makeMultiKeeper();
    upsertRoom({ cwd: "C:\\home", roomId: "device", lastSeenAt: Date.now() }, bare.registryPath);
    await bare.keeper.start();
    const bareDev = bare.fakeFor("device");
    bareDev.emitMessage(outerLineIn("device", PHONE_PEER, { type: "daemon_control", id: "dc-4", op: "status" }));
    await waitFor(() => expect(bareDev.sent.length).toBe(1));
    expect(decodeSent(bareDev.sent[0]!)).toMatchObject({
      type: "action_error", in_reply_to: "dc-4", action: "daemon_control",
      error: expect.stringContaining("no supervisor handler"),
    });
    await bare.keeper.stop();
  });

  it("keeps session rooms read-only: daemon_control ignored there, session_sync ignored on device", async () => {
    let handlerCalls = 0;
    const { keeper, fakeFor, registryPath } = makeMultiKeeper({
      onDaemonControl: async () => {
        handlerCalls++;
        return { op: "status", daemons: [] };
      },
    });
    upsertRoom({ cwd: "C:\\proj", roomId: "keptRoom", lastSeenAt: Date.now() }, registryPath);
    upsertRoom({ cwd: "C:\\home", roomId: "device", lastSeenAt: Date.now() }, registryPath);
    await keeper.start();

    const session = fakeFor("keptRoom");
    session.emitMessage(outerLine(PHONE_PEER, { type: "daemon_control", id: "dc-x", op: "restart" }));
    await new Promise((r) => setTimeout(r, 150));
    expect(handlerCalls).toBe(0);
    expect(session.sent.length).toBe(0);

    const dev = fakeFor("device");
    dev.emitMessage(outerLineIn("device", PHONE_PEER, { type: "session_sync", id: "sync-x" }));
    await new Promise((r) => setTimeout(r, 150));
    expect(dev.sent.length).toBe(0);
    await keeper.stop();
  });
});
