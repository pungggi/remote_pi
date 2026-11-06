/**
 * Plan/158 — chunked agent_file fetch + history merge tests.
 *
 * Drives `_routeClientMessageFrom` with fake channels (delivery-ledger test
 * discipline — no relay/pairing harness). Covers:
 *   - happy path: chunked serving, offset echo, `total`/`more`, byte-exact data
 *   - errors: not_found / gone / changed (mtime+size guard) / offset past EOF
 *   - busy: one in-flight fetch per channel; other channels unaffected
 *   - ledger: refs are stamped+journaled broadcasts; payload replies are not
 *   - history merge: registry refs interleaved by ts, metadata only
 *
 * "Unpaired sender rejected" is structural: pairing terminates upstream of
 * `_routeClientMessageFrom` (unknown epks never become channels), the same
 * way `report_seq`/`session_sync` rely on it.
 */
import { afterAll, afterEach, describe, expect, beforeEach, test, vi } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { ext, resetExtensionState } from "./extension-state.js";
import {
  _broadcastToActive,
  _routeClientMessageFrom,
  _setSessionStartedAtForTest,
  _getJournalSeqsForTest,
} from "./main.js";
import { appendRegistryEntry, registryTargetForCwd, AGENT_FILE_CHUNK_RAW_BYTES } from "./session/file_registry.js";
import { encodeCwd } from "./session/file_index.js";
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

function route(sender: PlainPeerChannel, msg: ClientMessage): void {
  const ctx = { abort: vi.fn() } as unknown as Parameters<typeof _routeClientMessageFrom>[2];
  void _routeClientMessageFrom(sender, msg, ctx);
}

function fetchMsg(fileId: string, offset: number, id = `f_${offset}`): ClientMessage {
  return { type: "agent_file_fetch", id, fileId, offset };
}

// ── sandboxed agent dir (fresh sessions tree per test) ──────────────────────

const savedAgentDir = process.env.PI_CODING_AGENT_DIR;
const tmpAgentDir = mkdtempSync(join(tmpdir(), "pi-agent-file-fetch-"));
process.env.PI_CODING_AGENT_DIR = tmpAgentDir;

afterAll(() => {
  if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
  rmSync(tmpAgentDir, { recursive: true, force: true });
});

beforeEach(() => {
  resetExtensionState();
  rmSync(join(tmpAgentDir, "sessions"), { recursive: true, force: true });
});

afterEach(() => {
  vi.restoreAllMocks();
  resetExtensionState();
});

/** Seed a transcript (so the registry binds to a real session) + a data file. */
function seedSession(): { sessionPath: string; registryPath: string } {
  const stamp = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
  const sessionsDir = join(tmpAgentDir, "sessions", encodeCwd(process.cwd()));
  mkdirSync(sessionsDir, { recursive: true });
  const sessionPath = join(sessionsDir, `${stamp}.jsonl`);
  writeFileSync(sessionPath, "");
  return { sessionPath, registryPath: registryTargetForCwd(process.cwd()) };
}

function pushRef(
  registryPath: string,
  fileId: string,
  absPath: string,
  bytes: number,
  ts = 1700000000000,
): void {
  appendRegistryEntry(registryPath, {
    fileId,
    ts,
    kind: "pdf",
    mime: "application/pdf",
    name: `${fileId}.pdf`,
    bytes,
    absPath,
    // Match the real file so fetch serves; history-merge-only entries may
    // reference files that never existed (stat guard never runs for them).
    mtimeMs: existsSync(absPath) ? statSync(absPath).mtimeMs : 0,
  });
}

describe("agent_file_fetch (plan/158)", () => {
  test("serves a two-chunk file byte-exactly with echo fields", async () => {
    const { sessionPath, registryPath } = seedSession();
    const bytes = Buffer.concat([Buffer.alloc(AGENT_FILE_CHUNK_RAW_BYTES, 0x61), Buffer.from("tail-bytes")]);
    const file = join(tmpdir(), `af-${stamp()}.pdf`);
    writeFileSync(file, bytes);
    pushRef(registryPath, "doc_a", file, bytes.length);
    expect(sessionPath).toBeTruthy();

    const peer = fakePeer();
    route(peer.ch, fetchMsg("doc_a", 0));
    await vi.waitFor(() => expect(peer.sent).toHaveLength(1));
    const first = peer.sent[0] as {
      type: string; in_reply_to: string; fileId: string; offset: number;
      total: number; data: string; more: boolean; seq?: number; epoch?: number;
    };
    expect(first.type).toBe("agent_file_payload");
    expect(first.in_reply_to).toBe("f_0");
    expect(first.fileId).toBe("doc_a");
    expect(first.offset).toBe(0);
    expect(first.total).toBe(bytes.length);
    expect(first.more).toBe(true);
    expect(Buffer.from(first.data, "base64").equals(bytes.subarray(0, AGENT_FILE_CHUNK_RAW_BYTES))).toBe(true);
    // Per-sender query answer: NEVER ledger-stamped (plan/145 rule).
    expect(first).not.toHaveProperty("seq");
    expect(first).not.toHaveProperty("epoch");

    route(peer.ch, fetchMsg("doc_a", AGENT_FILE_CHUNK_RAW_BYTES));
    await vi.waitFor(() => expect(peer.sent).toHaveLength(2));
    const second = peer.sent[1] as typeof first;
    expect(second.offset).toBe(AGENT_FILE_CHUNK_RAW_BYTES);
    expect(second.more).toBe(false);
    expect(Buffer.from(second.data, "base64").equals(bytes.subarray(AGENT_FILE_CHUNK_RAW_BYTES))).toBe(true);
    unlinkSync(file);
  });

  test("unknown fileId → not_found", async () => {
    seedSession();
    const peer = fakePeer();
    route(peer.ch, fetchMsg("doc_missing", 0));
    await vi.waitFor(() => expect(peer.sent).toHaveLength(1));
    expect(peer.sent[0]).toMatchObject({ type: "agent_file_error", code: "not_found", fileId: "doc_missing" });
  });

  test("deleted file → gone", async () => {
    const { registryPath } = seedSession();
    const file = join(tmpdir(), `af-${stamp()}.pdf`);
    writeFileSync(file, "data");
    pushRef(registryPath, "doc_gone", file, 4);
    unlinkSync(file);

    const peer = fakePeer();
    route(peer.ch, fetchMsg("doc_gone", 0));
    await vi.waitFor(() => expect(peer.sent).toHaveLength(1));
    expect(peer.sent[0]).toMatchObject({ type: "agent_file_error", code: "gone" });
  });

  test("modified file → changed (mtime/size staleness guard)", async () => {
    const { registryPath } = seedSession();
    const file = join(tmpdir(), `af-${stamp()}.pdf`);
    writeFileSync(file, Buffer.alloc(10, 0x62));
    pushRef(registryPath, "doc_mod", file, 10);
    // Touch: same size, different mtime.
    const { utimesSync } = await import("node:fs");
    const t = new Date(Date.now() + 5000);
    utimesSync(file, t, t);

    const peer = fakePeer();
    route(peer.ch, fetchMsg("doc_mod", 0));
    await vi.waitFor(() => expect(peer.sent).toHaveLength(1));
    expect(peer.sent[0]).toMatchObject({ type: "agent_file_error", code: "changed" });
    unlinkSync(file);
  });

  test("offset past EOF → changed", async () => {
    const { registryPath } = seedSession();
    const file = join(tmpdir(), `af-${stamp()}.pdf`);
    writeFileSync(file, Buffer.alloc(8, 0x63));
    pushRef(registryPath, "doc_eof", file, 8);

    const peer = fakePeer();
    route(peer.ch, fetchMsg("doc_eof", 999999));
    await vi.waitFor(() => expect(peer.sent).toHaveLength(1));
    expect(peer.sent[0]).toMatchObject({ type: "agent_file_error", code: "changed" });
    unlinkSync(file);
  });

  test("concurrent fetch on one channel → busy; payload reply still lands", async () => {
    const { registryPath } = seedSession();
    const file = join(tmpdir(), `af-${stamp()}.pdf`);
    writeFileSync(file, Buffer.alloc(AGENT_FILE_CHUNK_RAW_BYTES + 10, 0x64));
    pushRef(registryPath, "doc_busy", file, AGENT_FILE_CHUNK_RAW_BYTES + 10);

    const peer = fakePeer();
    // Route twice WITHOUT awaiting the first: the handler registers itself in
    // the in-flight WeakSet synchronously, before its first await.
    route(peer.ch, fetchMsg("doc_busy", 0, "b1"));
    route(peer.ch, fetchMsg("doc_busy", 0, "b2"));
    await vi.waitFor(() => expect(peer.sent).toHaveLength(2));
    const codes = peer.sent.map((m) => (m as { type: string }).type).sort();
    expect(codes).toEqual(["agent_file_error", "agent_file_payload"]);
    const err = peer.sent.find((m) => (m as { type: string }).type === "agent_file_error") as { code: string; in_reply_to: string };
    expect(err.code).toBe("busy");
    expect(err.in_reply_to).toBe("b2");
    unlinkSync(file);
  });

  test("different channels never collide (window=1 is per channel)", async () => {
    const { registryPath } = seedSession();
    const file = join(tmpdir(), `af-${stamp()}.pdf`);
    writeFileSync(file, Buffer.alloc(16, 0x65));
    pushRef(registryPath, "doc_par", file, 16);

    const a = fakePeer();
    const b = fakePeer();
    route(a.ch, fetchMsg("doc_par", 0));
    route(b.ch, fetchMsg("doc_par", 0));
    await vi.waitFor(() => expect(a.sent).toHaveLength(1));
    await vi.waitFor(() => expect(b.sent).toHaveLength(1));
    expect(a.sent[0]).toMatchObject({ type: "agent_file_payload" });
    expect(b.sent[0]).toMatchObject({ type: "agent_file_payload" });
    unlinkSync(file);
  });
});

describe("agent_file_ref ledger + history merge (plan/158)", () => {
  test("refs are stamped + journaled broadcasts", () => {
    _setSessionStartedAtForTest(1111);
    const ref: ServerMessage = {
      type: "agent_file_ref",
      id: "doc_x",
      in_reply_to: "",
      fileId: "doc_x",
      ts: 1700000000000,
      kind: "markdown",
      name: "a.md",
      bytes: 12,
    };
    _broadcastToActive(ref);
    expect(_getJournalSeqsForTest()).toEqual([1]);
  });

  test("session_history merges registry refs by ts, metadata only", async () => {
    const { sessionPath, registryPath } = seedSession();
    // Transcript: user@1000, assistant@3000.
    const lines = [
      { type: "message", message: { role: "user", timestamp: 1000, content: "hello" } },
      { type: "message", message: { role: "assistant", timestamp: 3000, content: [{ type: "text", text: "hi there" }] } },
    ];
    writeFileSync(sessionPath, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
    // Refs at 2000 and 4000 → must interleave between/after the transcript rows.
    pushRef(registryPath, "doc_r1", join(tmpdir(), "r1.pdf"), 100, 2000);
    pushRef(registryPath, "doc_r2", join(tmpdir(), "r2.pdf"), 200, 4000);

    _setSessionStartedAtForTest(1111);
    const peer = fakePeer();
    route(peer.ch, { type: "session_sync", id: "s1", limit: 50 });
    // _handleSessionSync first sends queued_message_state, then the history.
    await vi.waitFor(() => expect(peer.sent).toHaveLength(2));
    const reply = peer.sent[1] as { type: string; events: Array<Record<string, unknown>> };
    expect(reply.type).toBe("session_history");
    const kinds = reply.events.map((e) => e.type);
    expect(kinds).toEqual(["user_input", "agent_file_ref", "agent_message", "agent_file_ref"]);
    const ref1 = reply.events[1] as Record<string, unknown>;
    expect(ref1.fileId).toBe("doc_r1");
    expect(ref1.name).toBe("doc_r1.pdf");
    expect(ref1.bytes).toBe(100);
    // No base64 payload anywhere in any history event (plan/158 invariant).
    const json = JSON.stringify(reply.events);
    expect(json).not.toContain("data");
  });
});

function stamp(): string {
  return `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}
