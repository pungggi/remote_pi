/**
 * Plan/172 — Pi-clock timestamps on the live chat frames.
 *
 * The app used to stamp live rows with the PHONE's clock at frame arrival while
 * replayed rows carried the Pi's clock, so a transcript could mix two clocks.
 * These tests pin the sender half of the fix:
 *   - every live chat frame carries `ts` (epoch ms, Pi clock);
 *   - `tool_request` also names the LLM reply that issued the call (`reply_ts`);
 *   - `tool_result` carries the SDK's `duration_ms`, and so does its replay;
 *   - a key that cannot be trusted (NaN / negative / missing) never travels.
 *
 * Drives the exported handlers directly with a fake owner channel — no relay
 * or pairing harness (the handlers live entirely below PlainPeerChannel).
 */
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { ext, resetExtensionState } from "./extension-state.js";
import {
  _deliverMeshMessageToAgentForTest,
  _getCurrentTurnIdForTest,
  _mapAgentMessagesToEvents,
  _setCurrentTurnIdForTest,
  onInputRest,
  onMessageUpdate,
  onToolExecutionEnd,
  onToolExecutionStart,
} from "./main.js";
import type { PlainPeerChannel } from "./transport/peer_channel.js";
import type { ServerMessage } from "./protocol/types.js";

type Sent = Record<string, unknown>;

function fakePeer(): { ch: PlainPeerChannel; sent: Sent[] } {
  const sent: Sent[] = [];
  const ch = {
    send: (m: ServerMessage) => {
      sent.push(m as unknown as Sent);
    },
  } as unknown as PlainPeerChannel;
  return { ch, sent };
}

const REPLY_TS = 1716234600000;
/** Vitest's fake clock starts at 0 → pin it so `Date.now()` is readable. */
const NOW = 1716234612345;

function ofType<T extends Sent>(sent: Sent[], type: string): T[] {
  return sent.filter((m) => m["type"] === type) as T[];
}

beforeEach(() => {
  resetExtensionState();
  vi.useFakeTimers();
  vi.setSystemTime(NOW);
  vi.spyOn(console, "error").mockImplementation(() => undefined);
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  resetExtensionState();
});

describe("plan/172 — user input mirror", () => {
  test("terminal input is broadcast with the Pi-clock accept time", () => {
    const a = fakePeer();
    ext.activePeers.set("a", a.ch);

    onInputRest({ text: "list the changed files", source: "interactive" } as never);

    const [frame] = ofType(a.sent, "user_input");
    expect(frame).toMatchObject({ type: "user_input", text: "list the changed files" });
    expect(frame).toHaveProperty("ts", NOW);
  });

  test("no owner attached → nothing is sent (peers gate unchanged)", () => {
    onInputRest({ text: "hello", source: "interactive" } as never);
    // The handler returns before seeding the turn id, so no turn exists.
    expect(_getCurrentTurnIdForTest()).toBeNull();
  });
});

describe("plan/172 — agent_chunk reply start", () => {
  test("every chunk of one LLM message carries that message's timestamp", () => {
    const a = fakePeer();
    ext.activePeers.set("a", a.ch);
    _setCurrentTurnIdForTest("t1");

    // Two deltas of the SAME assistant message: one coalescing window.
    onMessageUpdate(deltaEvent("Hel", REPLY_TS));
    onMessageUpdate(deltaEvent("lo", REPLY_TS));
    vi.advanceTimersByTime(60);
    // A later LLM message (after a tool round-trip) starts a new window.
    onMessageUpdate(deltaEvent(" world", REPLY_TS + 9000));
    vi.advanceTimersByTime(60);

    const chunks = ofType<{ delta: string; ts?: number }>(a.sent, "agent_chunk");
    expect(chunks.map((c) => c.delta)).toEqual(["Hello", " world"]);
    expect(chunks.map((c) => c.ts)).toEqual([REPLY_TS, REPLY_TS + 9000]);
    // The reply-start time is remembered for the next tool frame.
    expect(ext.assistantMsgTs).toBe(REPLY_TS + 9000);
  });

  test("a message without a usable timestamp sends no `ts` (never NaN/null)", () => {
    const a = fakePeer();
    ext.activePeers.set("a", a.ch);
    _setCurrentTurnIdForTest("t1");

    onMessageUpdate(deltaEvent("hmm", Number.NaN));
    vi.advanceTimersByTime(60);

    const [chunk] = ofType(a.sent, "agent_chunk");
    expect(chunk).toHaveProperty("delta", "hmm");
    expect(chunk).not.toHaveProperty("ts");
    expect(ext.assistantMsgTs).toBeNull();
  });
});

describe("plan/172 — tool frames", () => {
  test("tool_request: execution start + the reply that issued the call", () => {
    const a = fakePeer();
    ext.activePeers.set("a", a.ch);
    _setCurrentTurnIdForTest("t1");
    onMessageUpdate(deltaEvent("running it", REPLY_TS));

    // A tool boundary flushes the coalesced text BEFORE the tool frame, so the
    // phone's timeline stays chronological.
    onToolExecutionStart({
      type: "tool_execution_start",
      toolCallId: "tc_1",
      toolName: "Bash",
      args: { command: "ls" },
    } as never);

    const [req] = ofType(a.sent, "tool_request");
    expect(req).toMatchObject({ type: "tool_request", tool_call_id: "tc_1", tool: "Bash" });
    expect(req).toHaveProperty("ts", NOW);
    expect(req).toHaveProperty("reply_ts", REPLY_TS);
    // Flushed first, stamped with the same reply start.
    const [chunk] = ofType(a.sent, "agent_chunk");
    expect(a.sent[0]).toBe(chunk);
    expect(chunk).toHaveProperty("ts", REPLY_TS);
  });

  test("tool_request without a streaming reply omits `reply_ts`", () => {
    const a = fakePeer();
    ext.activePeers.set("a", a.ch);

    onToolExecutionStart({
      type: "tool_execution_start",
      toolCallId: "tc_2",
      toolName: "Bash",
      args: { command: "ls" },
    } as never);

    const [req] = ofType(a.sent, "tool_request");
    expect(req).toHaveProperty("ts", NOW);
    expect(req).not.toHaveProperty("reply_ts");
  });

  test("tool_result: end time + the SDK's wall time, on both outcome branches", () => {
    const a = fakePeer();
    ext.activePeers.set("a", a.ch);

    onToolExecutionEnd({
      type: "tool_execution_end",
      toolCallId: "tc_ok",
      toolName: "Bash",
      result: { content: [{ type: "text", text: "file" }], details: {} },
      isError: false,
      durationMs: 6821.4,
    } as never);
    vi.setSystemTime(NOW + 1000);
    onToolExecutionEnd({
      type: "tool_execution_end",
      toolCallId: "tc_err",
      toolName: "Bash",
      result: { content: [{ type: "text", text: "boom" }], details: {} },
      isError: true,
      durationMs: 40,
    } as never);

    const [ok, err] = ofType(a.sent, "tool_result");
    expect(ok).toMatchObject({ tool_call_id: "tc_ok", result: "file" });
    expect(ok).toHaveProperty("ts", NOW);
    expect(ok).toHaveProperty("duration_ms", 6821); // rounded, not 6821.4
    expect(err).toMatchObject({ tool_call_id: "tc_err", error: "boom" });
    expect(err).toHaveProperty("ts", NOW + 1000);
    expect(err).toHaveProperty("duration_ms", 40);
  });

  test("tool_result: an unusable duration sends no `duration_ms` key", () => {
    const a = fakePeer();
    ext.activePeers.set("a", a.ch);
    const base = { type: "tool_execution_end", toolName: "Bash", isError: false } as const;

    onToolExecutionEnd({ ...base, toolCallId: "a", result: {} } as never); // absent
    onToolExecutionEnd({ ...base, toolCallId: "b", result: {}, durationMs: Number.NaN } as never);
    onToolExecutionEnd({ ...base, toolCallId: "c", result: {}, durationMs: -5 } as never);

    const results = ofType(a.sent, "tool_result");
    expect(results.map((r) => r["tool_call_id"])).toEqual(["a", "b", "c"]);
    for (const r of results) {
      expect(r).toHaveProperty("ts", NOW);
      expect(r).not.toHaveProperty("duration_ms");
    }
  });
});

describe("plan/172 — replay == live", () => {
  test("history tool_result replays duration_ms when the SDK recorded one", () => {
    const [evt] = _mapAgentMessagesToEvents([
      {
        role: "toolResult",
        toolCallId: "tc_1",
        content: [{ type: "text", text: "file" }],
        timestamp: 1716234610000,
        durationMs: 6821.6,
      },
    ]);
    expect(evt).toMatchObject({
      type: "tool_result",
      tool_call_id: "tc_1",
      ts: 1716234610000,
      result: "file",
    });
    expect(evt).toHaveProperty("duration_ms", 6822);
  });

  test("legacy session (no durationMs) → same event shape as before plan/172", () => {
    const [evt] = _mapAgentMessagesToEvents([
      {
        role: "toolResult",
        toolCallId: "tc_1",
        isError: true,
        content: [{ type: "text", text: "boom" }],
        timestamp: 1716234610000,
      },
    ]);
    expect(evt).toEqual({
      type: "tool_result",
      tool_call_id: "tc_1",
      ts: 1716234610000,
      error: "boom",
    });
  });

  test("history tool_request keeps the assistant-message ts (execution start comes from the result)", () => {
    const events = _mapAgentMessagesToEvents([
      {
        role: "assistant",
        timestamp: REPLY_TS,
        content: [{ type: "toolCall", id: "tc_1", name: "Bash", arguments: { command: "ls" } }],
      },
      {
        role: "toolResult",
        toolCallId: "tc_1",
        content: [{ type: "text", text: "file" }],
        timestamp: REPLY_TS + 9000,
        durationMs: 2000,
      },
    ]);
    expect(events[0]).toEqual({
      ts: REPLY_TS,
      type: "tool_request",
      tool_call_id: "tc_1",
      tool: "Bash",
      args: { command: "ls" },
    });
    // start = ts − duration_ms = REPLY_TS + 7000, exactly what a live
    // tool_request.ts would have reported.
    expect(events[1]).toMatchObject({ ts: REPLY_TS + 9000, duration_ms: 2000 });
  });
});

describe("plan/172 — synthetic agent-network pair", () => {
  test("both halves are stamped on the Pi clock; no duration (nothing executed)", () => {
    const a = fakePeer();
    ext.activePeers.set("a", a.ch);

    _deliverMeshMessageToAgentForTest({
      id: "env-1",
      from: "peer-b",
      to: "me",
      body: "status?",
    } as never);

    const [req, res] = ofType(a.sent, "tool_request").concat(ofType(a.sent, "tool_result"));
    expect(req).toMatchObject({ tool: "agent-network", tool_call_id: "mesh_env-1" });
    expect(req).toHaveProperty("ts", NOW);
    expect(res).toHaveProperty("ts", NOW);
    expect(res).not.toHaveProperty("duration_ms");
  });
});

// ── helpers ──────────────────────────────────────────────────────────────────

function deltaEvent(delta: string, timestamp: number) {
  return {
    type: "message_update",
    assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta },
    message: { role: "assistant", timestamp },
  } as never;
}
