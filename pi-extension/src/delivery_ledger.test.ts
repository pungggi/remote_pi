/**
 * Plan/145 — delivery ledger unit tests.
 *
 * Covers the pi-extension half of the ledger:
 *   - `_broadcastToActive` stamps every broadcast with (epoch, seq) and
 *     journals it (also while NO owner is attached — late attach catch-up).
 *   - Per-sender query answers (session_history, attach-time queued state)
 *     are never stamped and never consume seq.
 *   - `report_seq` replays exactly the missing journal range, in order, with
 *     the original stamps; epoch mismatch / ring overflow → `sync_needed`.
 *   - Replay bursts are rate-limited per channel; pending reports collapse
 *     to the latest.
 *   - `_resetSessionForNew` restamps the epoch and restarts the ledger.
 *
 * Unlike extension.test.ts this drives `_broadcastToActive` /
 * `_routeClientMessageFrom` directly with fake channels — no relay/pairing
 * harness needed (the ledger logic lives entirely below PlainPeerChannel).
 */
import { describe, test, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ext, resetExtensionState } from "./extension-state.js";
import {
  _broadcastToActive,
  _routeClientMessageFrom,
  _setSessionStartedAtForTest,
  _getRoomSeqForTest,
  _getJournalSeqsForTest,
  _resetSessionForNewForTest,
} from "./main.js";
import type { PlainPeerChannel } from "./transport/peer_channel.js";
import type { ClientMessage, ServerMessage } from "./protocol/types.js";

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

function chunk(delta: string): ServerMessage {
  return { type: "agent_chunk", in_reply_to: "t1", delta };
}

function report(sender: PlainPeerChannel, seq: number, epoch: number): void {
  const msg: ClientMessage = { type: "report_seq", id: `r${seq}`, seq, epoch };
  const ctx = { abort: vi.fn() } as unknown as Parameters<typeof _routeClientMessageFrom>[2];
  void _routeClientMessageFrom(sender, msg, ctx);
}

const EPOCH = 1111;

beforeEach(() => {
  resetExtensionState();
  vi.unstubAllEnvs();
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  resetExtensionState();
});

describe("delivery ledger — stamping + journal", () => {
  test("broadcasts are stamped monotonically and journaled (even with no peers)", () => {
    _setSessionStartedAtForTest(EPOCH);
    const a = fakePeer();
    const b = fakePeer();
    ext.activePeers.set("a", a.ch);
    ext.activePeers.set("b", b.ch);

    _broadcastToActive(chunk("h"));
    _broadcastToActive(chunk("i"));

    expect(a.sent[0]).toMatchObject({ type: "agent_chunk", delta: "h", seq: 1, epoch: EPOCH });
    expect(a.sent[1]).toMatchObject({ seq: 2, epoch: EPOCH });
    expect(b.sent[1]).toMatchObject({ seq: 2, epoch: EPOCH });
    expect(_getRoomSeqForTest()).toBe(2);
    expect(_getJournalSeqsForTest()).toEqual([1, 2]);

    // No owner attached: still stamped + journaled (late-attach catch-up).
    ext.activePeers.clear();
    _broadcastToActive(chunk("x"));
    expect(_getRoomSeqForTest()).toBe(3);
    expect(_getJournalSeqsForTest()).toEqual([1, 2, 3]);
  });

  test("no stamp, no journal before the session started (graceful idle)", () => {
    const a = fakePeer();
    ext.activePeers.set("a", a.ch);
    _broadcastToActive(chunk("h"));
    expect(a.sent[0]).toMatchObject({ type: "agent_chunk" });
    expect(a.sent[0]).not.toHaveProperty("seq");
    expect(a.sent[0]).not.toHaveProperty("epoch");
    expect(_getRoomSeqForTest()).toBe(0);
    expect(_getJournalSeqsForTest()).toEqual([]);
  });

  test("journal is a bounded ring (REMOTE_PI_JOURNAL_MAX)", () => {
    vi.stubEnv("REMOTE_PI_JOURNAL_MAX", "3");
    _setSessionStartedAtForTest(EPOCH);
    for (const d of ["a", "b", "c", "d", "e"]) _broadcastToActive(chunk(d));
    expect(_getRoomSeqForTest()).toBe(5);
    expect(_getJournalSeqsForTest()).toEqual([3, 4, 5]);
  });

  test("stamping never mutates the caller's message object", () => {
    _setSessionStartedAtForTest(EPOCH);
    const msg = chunk("h");
    _broadcastToActive(msg);
    expect(msg).not.toHaveProperty("seq");
    expect(msg).not.toHaveProperty("epoch");
  });

  test("session reset restamps the epoch and restarts the ledger", () => {
    _setSessionStartedAtForTest(EPOCH);
    const a = fakePeer();
    ext.activePeers.set("a", a.ch);
    _broadcastToActive(chunk("h"));
    _broadcastToActive(chunk("i"));

    _resetSessionForNewForTest("req1");

    // The reset fans out: queued state (old epoch, seq 3) then the empty
    // session_history (new epoch, seq 1).
    const types = a.sent.map((m) => m.type);
    expect(types).toEqual([
      "agent_chunk",
      "agent_chunk",
      "queued_message_state",
      "session_history",
    ]);
    const hist = a.sent[3]!;
    expect(hist).toMatchObject({ type: "session_history", in_reply_to: "req1", seq: 1 });
    expect(hist["epoch"]).not.toBe(EPOCH);
    expect(_getRoomSeqForTest()).toBe(1);
    expect(_getJournalSeqsForTest()).toEqual([1]);
  });
});

describe("delivery ledger — per-sender answers stay unstamped", () => {
  test("session_sync reply carries current_seq but no ledger stamp", async () => {
    // Hermetic history: no real .jsonl under a fresh tmp cwd.
    const cwd = mkdtempSync(join(tmpdir(), "pi-ledger-"));
    vi.spyOn(process, "cwd").mockReturnValue(cwd);
    try {
      _setSessionStartedAtForTest(EPOCH);
      const a = fakePeer();
      ext.activePeers.set("a", a.ch);
      _broadcastToActive(chunk("h"));
      _broadcastToActive(chunk("i"));

      const s = fakePeer();
      const ctx = { abort: vi.fn() } as unknown as Parameters<typeof _routeClientMessageFrom>[2];
      await _routeClientMessageFrom(
        s.ch,
        { type: "session_sync", id: "s1" },
        ctx,
      );

      const hist = s.sent.find((m) => m.type === "session_history");
      expect(hist).toBeDefined();
      expect(hist).toMatchObject({ in_reply_to: "s1", current_seq: 2 });
      expect(hist).not.toHaveProperty("seq");
      expect(hist).not.toHaveProperty("epoch");

      const queued = s.sent.find((m) => m.type === "queued_message_state");
      expect(queued).toBeDefined();
      expect(queued).not.toHaveProperty("seq");

      // The sync path consumed no seq.
      expect(_getRoomSeqForTest()).toBe(2);
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });
});

describe("delivery ledger — report_seq replay", () => {
  function seedJournal(count: number): void {
    _setSessionStartedAtForTest(EPOCH);
    for (let i = 0; i < count; i++) _broadcastToActive(chunk(`d${i + 1}`));
  }

  test("replays exactly the missing range, in order, with original stamps", () => {
    seedJournal(4);
    const b = fakePeer();
    report(b.ch, 2, EPOCH);
    expect(b.sent.map((m) => m.seq)).toEqual([3, 4]);
    expect(b.sent.map((m) => m.delta)).toEqual(["d3", "d4"]);
    expect(b.sent.every((m) => m.epoch === EPOCH)).toBe(true);
    // Replays are not re-stamped (no new stream members).
    expect(_getRoomSeqForTest()).toBe(4);
  });

  test("already-current report is a no-op", () => {
    seedJournal(3);
    const b = fakePeer();
    report(b.ch, 3, EPOCH);
    report(b.ch, 99, EPOCH);
    expect(b.sent).toEqual([]);
  });

  test("gap underflowing the ring → sync_needed overflow", () => {
    vi.stubEnv("REMOTE_PI_JOURNAL_MAX", "3");
    seedJournal(5); // journal holds 3,4,5
    const b = fakePeer();
    report(b.ch, 1, EPOCH); // needs 2.. — 2 fell out of the ring
    expect(b.sent).toEqual([{ type: "sync_needed", reason: "overflow" }]);
  });

  test("report exactly at the ring's oldest frame still replays", () => {
    vi.stubEnv("REMOTE_PI_JOURNAL_MAX", "3");
    seedJournal(5); // journal holds 3,4,5
    const b = fakePeer();
    report(b.ch, 3, EPOCH);
    expect(b.sent.map((m) => m.seq)).toEqual([4, 5]);
  });

  test("epoch mismatch → sync_needed epoch", () => {
    seedJournal(2);
    const b = fakePeer();
    report(b.ch, 0, 9999);
    expect(b.sent).toEqual([{ type: "sync_needed", reason: "epoch" }]);
  });

  test("idle extension never replies to reports", () => {
    const b = fakePeer();
    report(b.ch, 0, EPOCH);
    expect(b.sent).toEqual([]);
  });

  test("burst rate limit collapses pending reports to the latest", async () => {
    vi.useFakeTimers();
    seedJournal(5);
    const b = fakePeer();

    report(b.ch, 1, EPOCH); // immediate burst: 2,3,4,5
    expect(b.sent.map((m) => m.seq)).toEqual([2, 3, 4, 5]);

    report(b.ch, 2, EPOCH); // inside the window → deferred
    report(b.ch, 3, EPOCH); // collapses: only the latest survives
    expect(b.sent).toHaveLength(4);

    await vi.advanceTimersByTimeAsync(2_000);
    // One deferred burst, covering seq > 3.
    expect(b.sent.map((m) => m.seq)).toEqual([2, 3, 4, 5, 4, 5]);

    await vi.advanceTimersByTimeAsync(10_000); // nothing further scheduled
    expect(b.sent).toHaveLength(6);
  });

  test("rate limiting is per channel", async () => {
    vi.useFakeTimers();
    seedJournal(3);
    const b = fakePeer();
    const c = fakePeer();
    report(b.ch, 1, EPOCH);
    report(c.ch, 1, EPOCH); // different channel: not throttled
    expect(b.sent.map((m) => m.seq)).toEqual([2, 3]);
    expect(c.sent.map((m) => m.seq)).toEqual([2, 3]);
  });
});
