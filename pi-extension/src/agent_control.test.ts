/**
 * Plan/173 — the agent selector on the `$rp_control` mesh path: an unknown
 * agent is refused at the envelope, `list_models {agent:"agy"}` answers the
 * Antigravity CLI's catalogue, and `spawn_worktree` refuses AGY headless
 * before it touches git. Same recording fake peer as session_control.test.ts;
 * `agy models` is mocked, so no agy is started.
 */
import { afterAll, beforeAll, beforeEach, describe, expect, test, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

vi.mock("./actions/agent_models.js", () => ({
  listAgyModels: vi.fn(),
  agyModelIds: vi.fn(),
  probeAgy: vi.fn(),
}));

import { listAgyModels } from "./actions/agent_models.js";

type MainModule = typeof import("./main.js");

let main: MainModule;
let testHome: string;
let cwd: string;
const homesToClean: string[] = [];

const AGY_MODELS = [
  {
    id: "gemini-4-neon-high",
    name: "Gemini 4 Neon (High)",
    provider: "google",
    reasoning: false,
    context_window: 0,
    vision: false,
  },
];

beforeAll(async () => {
  testHome = mkdtempSync(join(tmpdir(), "pi-agyctl-"));
  homesToClean.push(testHome);
  process.env["REMOTE_PI_HOME"] = testHome;
  main = await import("./main.js");
});

beforeEach(() => {
  cwd = mkdtempSync(join(tmpdir(), "pi-agyctl-cwd-"));
  homesToClean.push(cwd);
  vi.mocked(listAgyModels).mockReset();
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

const ENV = { from: "pc2:C:\\proj@lead", id: "env-173", body: null };

function flush() {
  return new Promise((r) => setImmediate(r));
}

async function run(ctrl: unknown, settle = false) {
  const peer = makeFakePeer();
  await main._handleControlEnvelope(peer, ENV, ctrl as never, cwd);
  if (settle) await flush();
  return peer;
}

function lastReply(peer: { sent: SentCall[] }) {
  expect(peer.sent.length).toBe(1);
  const last = peer.sent[peer.sent.length - 1]!;
  return { re: last.re, body: last.body as { rp_control_result: Record<string, unknown> } };
}

describe("plan/173 agent selector on $rp_control", () => {
  test("an unknown agent is refused at the envelope, before any op runs", async () => {
    main._setPiForTest({ stub: true });
    const peer = await run({ op: "list_models", agent: "copilot" });
    const r = lastReply(peer);
    expect(r.re).toBe(ENV.id);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(r.body.rp_control_result.action).toBe("list_models");
    expect(String(r.body.rp_control_result.error)).toMatch(/unknown agent "copilot"/);
  });

  test("_synthesizeSessionAction carries the agent only when it is AGY", () => {
    expect(main._synthesizeSessionAction({ op: "list_models", agent: "agy" }, "env-7")).toEqual({
      type: "list_models",
      id: "env-7",
      agent: "agy",
    });
    expect(main._synthesizeSessionAction({ op: "list_models" }, "env-7")).toEqual({
      type: "list_models",
      id: "env-7",
    });
  });

  test("list_models {agent:'agy'} answers the AGY catalogue of this device", async () => {
    main._setPiForTest({ stub: true });
    vi.mocked(listAgyModels).mockResolvedValue({ ok: true, models: AGY_MODELS });
    const peer = await run({ op: "list_models", agent: "agy" }, true);
    const r = lastReply(peer);
    expect(listAgyModels).toHaveBeenCalledTimes(1);
    expect(r.body.rp_control_result).toMatchObject({ ok: true, action: "list_models", models: AGY_MODELS });
  });

  test("a failing `agy models` answers ok:false with AGY's words, never a hang", async () => {
    main._setPiForTest({ stub: true });
    vi.mocked(listAgyModels).mockResolvedValue({ ok: false, message: "Please sign in" });
    const peer = await run({ op: "list_models", agent: "agy" }, true);
    const r = lastReply(peer);
    expect(r.body.rp_control_result).toMatchObject({ ok: false, action: "list_models" });
    expect(String(r.body.rp_control_result.error)).toBe("Please sign in");
  });

  test("a throwing `agy models` call still answers: an error, never a hang", async () => {
    main._setPiForTest({ stub: true });
    vi.mocked(listAgyModels).mockRejectedValue(new Error("boom"));
    const peer = await run({ op: "list_models", agent: "agy" }, true);
    const r = lastReply(peer);
    expect(r.body.rp_control_result).toMatchObject({ ok: false, action: "list_models" });
    expect(String(r.body.rp_control_result.error)).toBe("boom");
  });

  test("spawn_worktree refuses AGY headless before it touches git", async () => {
    main._setPiForTest({ stub: true });
    const peer = await run({ op: "spawn_worktree", agent: "agy", headless: true });
    const r = lastReply(peer);
    expect(r.body.rp_control_result.ok).toBe(false);
    expect(String(r.body.rp_control_result.error)).toMatch(/cannot start AGY headless/);
  });
});
