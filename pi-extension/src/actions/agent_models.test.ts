/**
 * Plan/173 A2 — `agy models` parsing and probing, with a fake child process
 * (no real agy is ever started here).
 */
import { beforeEach, describe, expect, test, vi } from "vitest";
import { EventEmitter } from "node:events";
import type { ChildProcess } from "node:child_process";
import {
  AGY_CACHE_MS,
  _resetAgyCacheForTests,
  agyModelIds,
  agyProviderForId,
  agySpawnSpec,
  listAgyModels,
  parseAgyModels,
  probeAgy,
} from "./agent_models.js";

/** Verbatim `agy models` stdout of an AGY 1.5.18 install (2026-11-27). */
const REAL_OUTPUT = [
  "gemini-4-neon-high\tGemini 4 Neon (High)",
  "gemini-4-neon-xhigh\tGemini 4 Neon (XHigh)",
  "gemini-4-carbon-medium\tGemini 4 Carbon (Medium)",
  "gemini-pro-orchestrator\tOrchestrator (Carbon)",
  "gemini-3.8-flash-high\tGemini 3.8 Flash (High)",
  "claude-opus-5-5-low\tClaude Opus 5.5 (Low)",
  "claude-sonnet-5-5-high\tClaude Sonnet 5.5 (High)",
  "gpt-oss-120b-medium\tGPT-OSS 120B (Medium)",
  "",
].join("\n");

describe("parseAgyModels", () => {
  test("parses the real catalogue: id, name and a display provider per line", () => {
    const models = parseAgyModels(REAL_OUTPUT);
    expect(models).toHaveLength(8);
    expect(models[0]).toEqual({
      id: "gemini-4-neon-high",
      name: "Gemini 4 Neon (High)",
      provider: "google",
      reasoning: false,
      context_window: 0,
      vision: false,
    });
    expect(models.find((m) => m.id === "claude-opus-5-5-low")?.provider).toBe("anthropic");
    expect(models.find((m) => m.id === "gpt-oss-120b-medium")?.provider).toBe("openai");
    expect(models.find((m) => m.id === "gemini-pro-orchestrator")?.name).toBe("Orchestrator (Carbon)");
  });

  test("CRLF line endings and surrounding blanks are tolerated", () => {
    const models = parseAgyModels("\r\n  gemini-3.8-flash-low\tGemini 3.8 Flash (Low)  \r\n\r\n");
    expect(models.map((m) => m.id)).toEqual(["gemini-3.8-flash-low"]);
  });

  test("a line without a tab uses the id as the name", () => {
    expect(parseAgyModels("gemini-3.8-flash-low")).toEqual([
      expect.objectContaining({ id: "gemini-3.8-flash-low", name: "gemini-3.8-flash-low" }),
    ]);
  });

  test("chatter, unsafe ids and duplicates are dropped", () => {
    const out = [
      "Fetching available models...",
      "--help\tNot a model",
      "a b\tSpace id",
      "a/../../x\tPath id",
      "gemini-3.8-flash-low\tGemini 3.8 Flash (Low)",
      "gemini-3.8-flash-low\tGemini 3.8 Flash (Low) again",
    ].join("\n");
    expect(parseAgyModels(out).map((m) => m.id)).toEqual(["gemini-3.8-flash-low"]);
  });

  test("display provider families", () => {
    expect(agyProviderForId("claude-sonnet-5-5-high")).toBe("anthropic");
    expect(agyProviderForId("Claude-Up")).toBe("anthropic");
    expect(agyProviderForId("gemini-4-neon-high")).toBe("google");
    expect(agyProviderForId("gpt-oss-120b-medium")).toBe("openai");
    expect(agyProviderForId("something-else")).toBe("agy");
  });
});

describe("agySpawnSpec", () => {
  test("Windows resolves the CLI through the shell (agy.exe or an agy.cmd shim)", () => {
    expect(agySpawnSpec("win32")).toEqual({ cmd: "agy", shell: true });
  });

  test("other platforms spawn the binary directly", () => {
    expect(agySpawnSpec("linux")).toEqual({ cmd: "agy", shell: false });
    expect(agySpawnSpec("android" as NodeJS.Platform)).toEqual({ cmd: "agy", shell: false });
  });
});

// ── fake child process ───────────────────────────────────────────────────────

type Reply = { code: number | null; stdout?: string; stderr?: string; error?: NodeJS.ErrnoException; hang?: boolean };

let replies: Reply[] = [];

function fakeSpawn() {
  const spawnFn = vi.fn(() => {
    const r = replies.shift() ?? { code: 0 };
    const child = new EventEmitter() as unknown as ChildProcess;
    (child as unknown as { stdout: EventEmitter }).stdout = new EventEmitter();
    (child as unknown as { stderr: EventEmitter }).stderr = new EventEmitter();
    (child as unknown as { kill: () => void }).kill = vi.fn();
    if (r.hang) return child;
    setImmediate(() => {
      if (r.error) {
        child.emit("error", r.error);
        return;
      }
      if (r.stdout) child.stdout?.emit("data", Buffer.from(r.stdout));
      if (r.stderr) child.stderr?.emit("data", Buffer.from(r.stderr));
      child.emit("close", r.code);
    });
    return child;
  });
  return spawnFn as unknown as typeof import("node:child_process").spawn;
}

describe("listAgyModels", () => {
  beforeEach(() => {
    _resetAgyCacheForTests();
    replies = [];
  });

  test("returns the parsed catalogue and runs `agy models` once while cached", async () => {
    replies = [{ code: 0, stdout: REAL_OUTPUT, stderr: "Fetching available models...\n" }];
    const spawnFn = fakeSpawn();
    const first = await listAgyModels({ spawn: spawnFn, now: () => 1_000_000 });
    expect(first.ok).toBe(true);
    if (first.ok) expect(first.models).toHaveLength(8);
    await listAgyModels({ spawn: spawnFn, now: () => 1_000_000 + AGY_CACHE_MS - 1 });
    expect(spawnFn).toHaveBeenCalledTimes(1);
    expect(spawnFn).toHaveBeenCalledWith("agy", ["models"], expect.objectContaining({ stdio: ["ignore", "pipe", "pipe"] }));
    // After the cache expires agy is asked again.
    replies = [{ code: 0, stdout: REAL_OUTPUT }];
    await listAgyModels({ spawn: spawnFn, now: () => 1_000_000 + AGY_CACHE_MS + 1 });
    expect(spawnFn).toHaveBeenCalledTimes(2);
  });

  test("a missing CLI is named, never shown as an empty catalogue", async () => {
    replies = [{ code: null, error: Object.assign(new Error("spawn agy ENOENT"), { code: "ENOENT" }) }];
    const r = await listAgyModels({ spawn: fakeSpawn(), now: () => 1 });
    expect(r).toEqual({ ok: false, message: "agy is not installed on this device" });
  });

  test("a failing call yields AGY's own words as the message", async () => {
    replies = [{ code: 1, stderr: "Error: not signed in\n" }];
    const r = await listAgyModels({ spawn: fakeSpawn(), now: () => 1 });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toBe("Error: not signed in");
  });

  test("exit 0 with no usable rows is the signed-out shape, not an empty list", async () => {
    replies = [{ code: 0, stdout: "Please sign in to view available models. Launch the CLI without arguments to sign in.\n" }];
    const r = await listAgyModels({ spawn: fakeSpawn(), now: () => 1 });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/Please sign in/);
  });

  test("a hanging call is cut off and reported", async () => {
    replies = [{ code: null, hang: true }];
    const r = await listAgyModels({ spawn: fakeSpawn(), now: () => 1, modelsTimeoutMs: 20 });
    expect(r).toEqual({ ok: false, message: "agy models did not answer within 20 ms" });
  }, 10_000);

  test("a failure is not cached: the next call asks again", async () => {
    replies = [{ code: 1, stderr: "boom" }, { code: 0, stdout: REAL_OUTPUT }];
    const spawnFn = fakeSpawn();
    const a = await listAgyModels({ spawn: spawnFn, now: () => 5 });
    const b = await listAgyModels({ spawn: spawnFn, now: () => 6 });
    expect(a.ok).toBe(false);
    expect(b.ok).toBe(true);
    expect(spawnFn).toHaveBeenCalledTimes(2);
  });
});

describe("probeAgy", () => {
  beforeEach(() => {
    _resetAgyCacheForTests();
    replies = [];
  });

  test("true when `agy --version` exits 0, asked once while cached", async () => {
    replies = [{ code: 0, stdout: "1.5.18\n" }];
    const spawnFn = fakeSpawn();
    expect(await probeAgy({ spawn: spawnFn, now: () => 10 })).toBe(true);
    expect(await probeAgy({ spawn: spawnFn, now: () => 11 })).toBe(true);
    expect(spawnFn).toHaveBeenCalledTimes(1);
    expect(spawnFn).toHaveBeenCalledWith("agy", ["--version"], expect.anything());
  });

  test("false when the CLI is missing, and not cached", async () => {
    replies = [
      { code: null, error: Object.assign(new Error("ENOENT"), { code: "ENOENT" }) },
      { code: 0, stdout: "1.5.18\n" },
    ];
    const spawnFn = fakeSpawn();
    expect(await probeAgy({ spawn: spawnFn, now: () => 10 })).toBe(false);
    expect(await probeAgy({ spawn: spawnFn, now: () => 11 })).toBe(true);
    expect(spawnFn).toHaveBeenCalledTimes(2);
  });
});

describe("agyModelIds", () => {
  beforeEach(() => {
    _resetAgyCacheForTests();
    replies = [];
  });

  test("the ids when the catalogue is available, null when it is not", async () => {
    replies = [{ code: 0, stdout: REAL_OUTPUT }, { code: 1, stderr: "nope" }];
    const spawnFn = fakeSpawn();
    _resetAgyCacheForTests();
    expect(await agyModelIds({ spawn: spawnFn, now: () => 1 })).toContain("gemini-4-neon-high");
    _resetAgyCacheForTests();
    expect(await agyModelIds({ spawn: spawnFn, now: () => 2 })).toBeNull();
  });
});
