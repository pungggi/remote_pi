import { afterAll, beforeAll, beforeEach, describe, expect, test, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
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

  test("no active Pi session → explicit error, not silence", async () => {
    main._setPiForTest(null);
    const peer = await run({ op: "session_compact" });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toContain("no active Pi session");
  });

  test("unknown op → typed error reply", async () => {
    main._setPiForTest({ stub: true });
    const peer = await run({ op: "session_shutdown" }); // deliberately out of scope
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
});
