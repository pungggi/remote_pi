import { afterAll, beforeAll, beforeEach, describe, expect, test, vi } from "vitest";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadLocalConfig, saveLocalConfig } from "./session/local_config.js";

/**
 * Plan/161 — receiving side of the `$rp_control` mesh envelopes:
 * `_handleControlEnvelope` in main.ts. All probes use a recording fake
 * peer; nothing touches the network or the SDK beyond what the handlers'
 * error paths exercise (no-session-ctx → typed action_error), which is
 * exactly the pipeline an out-of-the-box peer exhibits.
 */

type MainModule = typeof import("./main.js");

let main: MainModule;
let testHome: string;
let cwd: string;
const homesToClean: string[] = [];

beforeAll(async () => {
  testHome = mkdtempSync(join(tmpdir(), "pi-ctl-"));
  homesToClean.push(testHome);
  process.env["REMOTE_PI_HOME"] = testHome;
  main = await import("./main.js");
});

beforeEach(() => {
  cwd = mkdtempSync(join(tmpdir(), "pi-ctl-cwd-"));
  homesToClean.push(cwd);
});

afterAll(() => {
  delete process.env["REMOTE_PI_HOME"];
  for (const h of homesToClean) {
    try { rmSync(h, { recursive: true, force: true }); } catch { /* best effort */ }
  }
});

interface SentCall {
  to: string | string[];
  body: unknown;
  re: string | null | undefined;
}

function makeFakePeer() {
  const sent: SentCall[] = [];
  const peer = {
    send: vi.fn((to: string | string[], body: unknown, re?: string | null) => {
      sent.push({ to, body, re });
      return Promise.resolve();
    }),
    sent,
  };
  return peer;
}

const ENV = { from: "pc2:C:\\proj@lead", id: "env-42", body: null };

async function run(ctrl: unknown, peer = makeFakePeer()) {
  await main._handleControlEnvelope(peer, ENV, ctrl as never, cwd);
  return peer;
}

function lastReply(peer: { sent: SentCall[] }) {
  // Single-reply invariant (ai-review #107 r2): every control request must
  // produce EXACTLY one correlated envelope — a second would confuse the
  // sender's pending map.
  expect(peer.sent.length).toBe(1);
  const last = peer.sent[peer.sent.length - 1]!;
  return { to: last.to, re: last.re, body: last.body as { rp_control_result: Record<string, unknown> } };
}

/** Plan/171 — the per-room ext log (`_relayLog`) inside this file's sandbox
 *  REMOTE_PI_HOME: never the developer's real `~/.pi/piper` tree. */
function roomLog(roomId: string): string {
  return readFileSync(join(process.env["REMOTE_PI_HOME"]!, ".pi", "piper", `ext-${roomId}.log`), "utf8");
}

describe("plan/161 $rp_control receiving side", () => {
  test("kill-switch off → typed refused reply, re = envelope id", async () => {
    main._setPiForTest({ stub: true });
    saveLocalConfig(cwd, { allow_remote_session_control: false });
    const peer = await run({ op: "session_compact" });
    const r = lastReply(peer);
    expect(r.to).toBe(ENV.from);
    expect(r.re).toBe(ENV.id);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("allow_remote_session_control");
  });

  test("kill-switch present but mistyped → fails CLOSED (disabled), ai-review #107 r3", async () => {
    main._setPiForTest({ stub: true });
    const dir = join(cwd, ".pi", "remote-pi");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "config.json"), JSON.stringify({ allow_remote_session_control: "false" }));
    expect(loadLocalConfig(cwd).allow_remote_session_control).toBe(false);
    // And the envelope path honors it (refused, not just parse-level):
    const peer = await run({ op: "session_compact" });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("allow_remote_session_control");
  });

  test("kill-switch off also refuses spawn_worktree — gate precedes the op switch (ai-review #107 r6)", async () => {
    main._setPiForTest({ stub: true });
    saveLocalConfig(cwd, { allow_remote_session_control: false });
    const peer = await run({ op: "spawn_worktree", branch: "work/probe" });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("allow_remote_session_control");
  });

  test("self-addressed envelope → refused with typed error (ai-review #107 r4)", async () => {
    main._setPiForTest({ stub: true });
    const base = makeFakePeer();
    const peer = { ...base, address: () => ENV.from, name: () => "pc2:C:\\proj@lead" };
    await main._handleControlEnvelope(peer as never, ENV, { op: "session_compact" } as never, cwd);
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("self-addressed");
  });

  test("dead peer on reply (remote reset rebuilt it) → no crash, no unhandled rejection (live-run PR #107)", async () => {
    main._setPiForTest({ stub: true });
    // LIVE-RUN regression: remote session_reset tears down the mesh peer
    // before the deferred action_ok; peer.send then throws SYNCHRONOUSLY.
    // void does not catch sync throws — before the fix this crashed pi.
    const peer = makeFakePeer();
    peer.send = vi.fn(() => {
      throw new Error("session peer not connected");
    });
    // Must resolve instead of throwing/rejecting.
    await expect(main._handleControlEnvelope(peer, ENV, { op: "session_compact" } as never, cwd))
      .resolves.toBeUndefined();
  });

  test("no active Pi session → explicit error, not silence", async () => {
    main._setPiForTest(null);
    const peer = await run({ op: "session_compact" });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("no active Pi session");
  });

  test("unknown op → typed error reply", async () => {
    main._setPiForTest({ stub: true });
    // thinking_set stays app-only (plan/166 made session_shutdown legal —
    // the old placeholder op for this test); anything outside RpControlOp
    // must keep hitting the default branch.
    const peer = await run({ op: "thinking_set" });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("unknown op");
  });

  test("session_compact without a session ctx → action_error piped through", async () => {
    main._setPiForTest({ stub: true });
    const peer = await run({ op: "session_compact" });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(r.body.rp_control_result.action).toBe("session_compact");
    expect(String(r.body.rp_control_result.error)).toContain("compact unavailable");
  });

  test("model_set without provider/model_id → typed payload error", async () => {
    main._setPiForTest({ stub: true });
    const peer = await run({ op: "model_set", model_id: "x" });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("provider and model_id");
  });

  test("spawn_worktree provider-only → rejected before touching git", async () => {
    main._setPiForTest({ stub: true });
    const peer = await run({ op: "spawn_worktree", provider: "anthropic" });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("both provider and model_id");
  });

  // ── plan/166: session_shutdown on the mesh surface ─────────────────────

  test("kill-switch off also refuses session_shutdown — same gate as every op", async () => {
    main._setPiForTest({ stub: true });
    saveLocalConfig(cwd, { allow_remote_session_control: false });
    const peer = await run({ op: "session_shutdown" });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("allow_remote_session_control");
  });

  test("session_shutdown routes to the handler (plan/166) — no session ctx → typed action_error", async () => {
    main._setPiForTest({ stub: true });
    const peer = await run({ op: "session_shutdown" });
    const r = lastReply(peer);
    // Not "unknown op" anymore: the op reaches handleSessionShutdown and
    // its no-ctx error is piped through the sink verbatim.
    expect(r.body.rp_control_result.action).toBe("session_shutdown");
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("shutdown unavailable");
  });

  test("_synthesizeSessionAction: shutdown op synthesizes defer_if_busy (plan/166)", () => {
    const msg = main._synthesizeSessionAction({ op: "session_shutdown" }, "env-7");
    expect(msg).toEqual({ type: "session_shutdown", id: "env-7", defer_if_busy: true });
  });
});

describe("plan/170 $rp_control ask_notice", () => {
  test("project session (non-device room) → typed refusal, nothing broadcast", async () => {
    main._setPiForTest({ stub: true });
    main._setRoomIdForTest("abc123room");
    const peer = await run({ op: "ask_notice", open: true, room_id: "abc123room", flow_id: "tool:tc_1" });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("device daemon");
    main._setRoomIdForTest(null);
  });

  test("device room + valid fields → ok reply + pending_ask broadcast to owners", async () => {
    main._setPiForTest({ stub: true });
    main._setRoomIdForTest("device");
    const sent: Array<Record<string, unknown>> = [];
    const { ext: extState } = await import("./extension-state.js");
    // Plan/171 — a started session makes the broadcast ledger-stamped; the
    // receipt (seq/epoch) is what the sender logs.
    const prevStartedAt = extState.sessionStartedAt;
    extState.sessionStartedAt = 1763900000000;
    extState.activePeers.set("phone", {
      send: (m: unknown) => {
        sent.push(m as Record<string, unknown>);
      },
    });
    const peer = await run({
      op: "ask_notice",
      open: true,
      room_id: "sess-room-9",
      flow_id: "tool:tc_7",
      title: "Direction",
      question_count: 2,
    });
    const r = lastReply(peer);
    expect(r.body.rp_control_result).toMatchObject({ ok: true, action: "ask_notice", recipients: 1 });
    expect(typeof r.body.rp_control_result.seq).toBe("number");
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({
      type: "pending_ask",
      room_id: "sess-room-9",
      flow_id: "tool:tc_7",
      open: true,
      title: "Direction",
      question_count: 2,
    });
    expect(typeof sent[0]!["ts"]).toBe("number");
    // Plan/171 — the receipt matches the frame actually sent, and the room
    // log carries the audit line.
    expect(sent[0]!["seq"]).toBe(r.body.rp_control_result.seq);
    expect(sent[0]!["epoch"]).toBe(1763900000000);
    expect(roomLog("device")).toContain(
      `pending_ask out open=true room=sess-room-9 flow=tool:tc_7 seq=${String(r.body.rp_control_result.seq)} epoch=1763900000000 recipients=1`,
    );
    extState.activePeers.clear();
    extState.sessionStartedAt = prevStartedAt;
    main._setRoomIdForTest(null);
  });

  test("missing room_id/flow_id → typed validation error", async () => {
    main._setPiForTest({ stub: true });
    main._setRoomIdForTest("device");
    const peer = await run({ op: "ask_notice", open: true, flow_id: "tool:tc_1" });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("room_id and flow_id");
    main._setRoomIdForTest(null);
  });

  test("kill-switch off refuses ask_notice too (gate precedes the op switch)", async () => {
    main._setPiForTest({ stub: true });
    saveLocalConfig(cwd, { allow_remote_session_control: false });
    main._setRoomIdForTest("device");
    const peer = await run({ op: "ask_notice", open: true, room_id: "r", flow_id: "f" });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("allow_remote_session_control");
    main._setRoomIdForTest(null);
  });

  test("plan/171 — a refusal is audited in the receiving room's ext log", async () => {
    main._setPiForTest({ stub: true });
    main._setRoomIdForTest("abc123room");
    await run({ op: "ask_notice", open: true, room_id: "abc123room", flow_id: "tool:tc_1" });
    expect(roomLog("abc123room")).toContain(
      'ask_notice refused open=true room=abc123room flow=tool:tc_1 reason="ask_notice is only served by the device daemon (device room)"',
    );
    main._setRoomIdForTest(null);
  });
});

describe("plan/171 ask_notice audit trail (sender side)", () => {
  function fakeMeshNode(request: (to: string, body: unknown) => Promise<unknown>) {
    return { peer: () => ({ request }) } as never;
  }
  const flow = (phase: "open" | "close") => ({
    phase,
    flowId: "tool:tc_7",
    toolCallId: "tc_7",
    title: "Direction",
    questionCount: 2,
  });
  const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 30));

  async function withMesh(request: (to: string, body: unknown) => Promise<unknown>, body: () => Promise<void>) {
    const { ext: extState } = await import("./extension-state.js");
    const prevNode = extState.meshNode;
    extState.meshNode = fakeMeshNode(request);
    main._setRoomIdForTest("asker-room");
    try {
      await body();
    } finally {
      extState.meshNode = prevNode;
      main._setRoomIdForTest(null);
    }
  }

  test("logs the daemon receipt (ledger seq + owners reached)", async () => {
    const request = vi.fn(async () => ({
      body: { rp_control_result: { ok: true, action: "ask_notice", seq: 12, epoch: 7, recipients: 1 } },
    }));
    await withMesh(request, async () => {
      main._fanoutAskNotice(flow("open"));
      await settle();
      expect(request).toHaveBeenCalledWith(
        "device",
        {
          $rp_control: {
            op: "ask_notice",
            open: true,
            room_id: "asker-room",
            flow_id: "tool:tc_7",
            title: "Direction",
            question_count: 2,
          },
        },
        expect.any(Number),
      );
      expect(roomLog("asker-room")).toContain("ask_notice sent open=true flow=tool:tc_7 seq=12 recipients=1");
    });
  });

  test("logs a typed refusal from the daemon", async () => {
    await withMesh(
      async () => ({ body: { rp_control_result: { ok: false, action: "ask_notice", error: "nope" } } }),
      async () => {
        main._fanoutAskNotice(flow("close"));
        await settle();
        expect(roomLog("asker-room")).toContain('ask_notice refused open=false flow=tool:tc_7 reason="nope"');
      },
    );
  });

  test("logs a transport failure and warns exactly once", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      await withMesh(
        async () => {
          throw new Error("peer timeout");
        },
        async () => {
          main._fanoutAskNotice(flow("open"));
          await settle();
          expect(roomLog("asker-room")).toContain('ask_notice failed open=true flow=tool:tc_7 error="peer timeout"');
          expect(warn).toHaveBeenCalledTimes(1);
        },
      );
    } finally {
      warn.mockRestore();
    }
  });
});
