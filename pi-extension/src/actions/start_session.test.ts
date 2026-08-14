/**
 * Plan/124 — unit tests for the `start_session_request` handler.
 *
 * The handler is a thin adapter over `callSupervisor` (the supervisor UDS
 * client). We mock that client so these tests never touch a real socket and
 * run anywhere (the supervisor integration tests in `supervisor.test.ts`
 * cover the spawn/persistence behaviour, but can't run while a real
 * pi-supervisord holds the per-user pipe).
 */
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

// Mock the daemon client BEFORE importing the handler (vi.mock is hoisted).
vi.mock("../daemon/client.js", () => ({
  callSupervisor: vi.fn(),
  SupervisorOfflineError: class SupervisorOfflineError extends Error {
    constructor(public readonly sockPath: string) {
      super(`Supervisor is not running. UDS not responding at ${sockPath}.`);
      this.name = "SupervisorOfflineError";
    }
  },
}));

import { callSupervisor, SupervisorOfflineError } from "../daemon/client.js";

// Security fix 2026-08 — the handler now gates cwd against the project-roots
// policy. Unit tests here exercise the supervisor ADAPTER, not the policy
// (cwd_policy gets its own coverage below via allowedRemoteCwds tests);
// neutralize it so arbitrary fixture paths pass through.
vi.mock("./cwd_policy.js", () => ({
  remoteCwdAllowed: vi.fn(() => true),
}));

import { handleStartSession } from "./start_session.js";
import type { ClientMessage, ServerMessage } from "../protocol/types.js";

type StartMsg = Extract<ClientMessage, { type: "start_session_request" }>;

/** Minimal array-backed reply sender. */
function fakeSender() {
  const sent: ServerMessage[] = [];
  return { send: (m: ServerMessage) => sent.push(m), sent };
}

/** Flushes the handler's `void .then()/.catch()` chain. */
function flush() {
  return new Promise((r) => setImmediate(r));
}

describe("handleStartSession (plan/124)", () => {
  // Each test asserts on callSupervisor's call history — clear it between
  // tests so `not.toHaveBeenCalled` reflects only the current test.
  beforeEach(() => vi.clearAllMocks());

  test("replies ok:true + room_id on a successful transient spawn", async () => {
    vi.mocked(callSupervisor).mockResolvedValue({
      id: "deadbeef", cwd: "/x", room_id: "abc1234567", started: true,
    });
    const s = fakeSender();
    handleStartSession(s as any, { type: "start_session_request", id: "m1", cwd: "/x" } as StartMsg);
    await flush();

    expect(vi.mocked(callSupervisor)).toHaveBeenCalledWith({ op: "start_transient", cwd: "/x" });
    expect(s.sent).toEqual([
      { type: "start_session_result", in_reply_to: "m1", ok: true, room_id: "abc1234567" },
    ]);
  });

  test("forwards a custom name (scopes the room for named sessions)", async () => {
    vi.mocked(callSupervisor).mockResolvedValue({
      id: "1", cwd: "/x", room_id: "named-room", started: true,
    });
    const s = fakeSender();
    handleStartSession(s as any, {
      type: "start_session_request", id: "m2", cwd: "/x", name: "device",
    } as StartMsg);
    await flush();

    expect(vi.mocked(callSupervisor)).toHaveBeenCalledWith({
      op: "start_transient", cwd: "/x", name: "device",
    });
    expect(s.sent[0]).toMatchObject({ ok: true, room_id: "named-room" });
  });

  test("omits name when blank (→ legacy cwd-only room)", async () => {
    vi.mocked(callSupervisor).mockResolvedValue({
      id: "1", cwd: "/x", room_id: "r", started: true,
    });
    const s = fakeSender();
    handleStartSession(s as any, {
      type: "start_session_request", id: "m3", cwd: "/x", name: "   ",
    } as StartMsg);
    await flush();

    expect(vi.mocked(callSupervisor)).toHaveBeenCalledWith({ op: "start_transient", cwd: "/x" });
  });

  test("replies ok:false with an install hint when the supervisor is offline", async () => {
    vi.mocked(callSupervisor).mockRejectedValue(new SupervisorOfflineError("\\\\.\\pipe\\x"));
    const s = fakeSender();
    handleStartSession(s as any, { type: "start_session_request", id: "m4", cwd: "/x" } as StartMsg);
    await flush();

    expect(s.sent).toHaveLength(1);
    expect(s.sent[0]).toMatchObject({ type: "start_session_result", ok: false });
    expect((s.sent[0] as { message?: string }).message).toMatch(/supervisor/i);
  });

  test("replies ok:false with the error message on any other failure", async () => {
    vi.mocked(callSupervisor).mockRejectedValue(new Error("cwd does not exist"));
    const s = fakeSender();
    handleStartSession(s as any, { type: "start_session_request", id: "m5", cwd: "/missing" } as StartMsg);
    await flush();

    expect(s.sent[0]).toMatchObject({ ok: false });
    expect((s.sent[0] as { message?: string }).message).toBe("cwd does not exist");
  });

  test("replies ok:false synchronously when cwd is missing", () => {
    const s = fakeSender();
    handleStartSession(s as any, { type: "start_session_request", id: "m6", cwd: "" } as StartMsg);
    // No promise kicked off — the reply is already queued.
    expect(s.sent).toEqual([
      { type: "start_session_result", in_reply_to: "m6", ok: false, message: "cwd is required" },
    ]);
    expect(vi.mocked(callSupervisor)).not.toHaveBeenCalled();
  });
});
