/**
 * Plan/173 A2 — `handleStartSession` honors `agent` and the one-session
 * model, plus the two small seams the start handlers share.
 *
 * `openTerminalTab` is mocked (start_session.ts imports it), so no terminal
 * opens; `agyModelIds` is mocked, so no agy is started. `handleOpenTerminal`
 * is covered in `open_terminal_agent.test.ts` at the process boundary,
 * because it calls the launcher through its own module's internal binding.
 */
import { beforeEach, describe, expect, test, vi } from "vitest";
import { execFileSync } from "node:child_process";

vi.mock("node:child_process", () => ({ execFileSync: vi.fn(), spawn: vi.fn() }));
vi.mock("./cwd_policy.js", () => ({ remoteCwdAllowed: vi.fn(() => true) }));
vi.mock("./worktree_registry.js", () => ({
  addWorktree: vi.fn(),
  listWorktrees: vi.fn(() => []),
  forgetWorktree: vi.fn(),
}));
vi.mock("../session/local_config.js", () => ({
  saveLocalConfig: vi.fn(),
  loadLocalConfigFile: vi.fn(() => ({})),
  loadLocalConfig: vi.fn(() => ({})),
}));
vi.mock("../rooms.js", () => ({ roomIdFor: vi.fn(() => "room-1") }));
vi.mock("../session/rooms_registry.js", () => ({ readRoomsRegistry: vi.fn(() => new Map()) }));
vi.mock("../termux.js", () => ({ isTermux: vi.fn(() => false) }));
vi.mock("./agent_models.js", () => ({ agyModelIds: vi.fn(), listAgyModels: vi.fn(), probeAgy: vi.fn() }));
vi.mock("./open_terminal.js", async (importOriginal) => ({
  ...await importOriginal<typeof import("./open_terminal.js")>(),
  openTerminalTab: vi.fn(),
}));

import {
  AGY_START_CHECK_TIMEOUT_MS,
  AGY_TMUX_SIZE,
  _resetLauncherCachesForTests,
  readStartSelection,
  startModelProblem,
  terminalKindHere,
} from "./open_terminal.js";
import { openTerminalTab } from "./open_terminal.js";
import { handleStartSession } from "./start_session.js";
import { agyModelIds } from "./agent_models.js";
import { readRoomsRegistry } from "../session/rooms_registry.js";
import type { ClientMessage, ServerMessage } from "../protocol/types.js";

type StartMsg = Extract<ClientMessage, { type: "start_session_request" }>;

function fakeSender() {
  const sent: ServerMessage[] = [];
  return { send: (m: ServerMessage) => sent.push(m), sent };
}

function flush() {
  return new Promise((r) => setImmediate(r));
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(openTerminalTab).mockReset();
  vi.mocked(openTerminalTab).mockResolvedValue({ ok: true, message: "Opened terminal window at: x", method: "wt" });
  vi.mocked(agyModelIds).mockReset();
  vi.mocked(agyModelIds).mockResolvedValue(null);
  vi.mocked(readRoomsRegistry).mockReturnValue(new Map());
});

describe("readStartSelection", () => {
  test("no fields is Pi without a model", () => {
    expect(readStartSelection({})).toEqual({ ok: true, selection: { agent: "pi", model: null } });
  });

  test("an unknown agent is refused by name", () => {
    const r = readStartSelection({ agent: "copilot" });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/unknown agent "copilot"/);
  });
});

describe("startModelProblem", () => {
  test("Pi is never asked about a catalogue", async () => {
    expect(await startModelProblem({ agent: "pi", model: { provider: "zai", model_id: "glm" } })).toBeNull();
    expect(agyModelIds).not.toHaveBeenCalled();
  });

  test("AGY without a model is never asked", async () => {
    expect(await startModelProblem({ agent: "agy", model: null })).toBeNull();
    expect(agyModelIds).not.toHaveBeenCalled();
  });

  test("an AGY id outside the catalogue is refused", async () => {
    vi.mocked(agyModelIds).mockResolvedValue(["gemini-4-neon-high"]);
    const r = await startModelProblem({ agent: "agy", model: { provider: "google", model_id: "nope" } });
    expect(r).toBe('model "nope" is not one of AGY\'s models on this device');
  });

  test("an offered AGY id passes", async () => {
    vi.mocked(agyModelIds).mockResolvedValue(["gemini-4-neon-high"]);
    expect(
      await startModelProblem({ agent: "agy", model: { provider: "google", model_id: "gemini-4-neon-high" } }),
    ).toBeNull();
  });

  test("the check waits less than a picker would: its own deadline, then pass-through", async () => {
    // A start holds the action channel, and the app gives up on it after
    // 15 s (start_session) or 30 s (open_terminal); a picker can wait longer.
    expect(AGY_START_CHECK_TIMEOUT_MS).toBe(10_000);
    vi.mocked(agyModelIds).mockResolvedValue(null);
    expect(
      await startModelProblem({ agent: "agy", model: { provider: "google", model_id: "gemini-4-neon-high" } }),
    ).toBeNull();
    expect(agyModelIds).toHaveBeenCalledWith({ modelsTimeoutMs: AGY_START_CHECK_TIMEOUT_MS });
  });

  test("while the catalogue is unavailable the id is passed through", async () => {
    vi.mocked(agyModelIds).mockResolvedValue(null);
    expect(await startModelProblem({ agent: "agy", model: { provider: "google", model_id: "anything" } })).toBeNull();
  });
});

describe("handleStartSession with an agent (plan/173)", () => {
  test("AGY starts through the wrapper, in the room's tmux session, with a canvas", async () => {
    vi.mocked(agyModelIds).mockResolvedValue(["gemini-4-neon-high"]);
    const s = fakeSender();
    await handleStartSession(s as never, {
      type: "start_session_request",
      id: "agy-1",
      cwd: "/x",
      agent: "agy",
      provider: "google",
      model_id: "gemini-4-neon-high",
    } as StartMsg);
    await flush();
    expect(openTerminalTab).toHaveBeenCalledWith("/x", "remote-pi agy --model gemini-4-neon-high", {
      newWindow: true,
      sessionName: "room-1",
      size: { ...AGY_TMUX_SIZE },
    });
    expect(s.sent[0]).toMatchObject({
      type: "start_session_result",
      ok: true,
      room_id: "room-1",
      message: expect.stringMatching(/AGY is running .* not shown in the app/),
    });
  });

  test("AGY never resumes a stored Pi session, even when the room has one", async () => {
    vi.mocked(readRoomsRegistry).mockReturnValue(
      new Map([["room-1", { cwd: "/x", roomId: "room-1", lastSeenAt: 1, sessionId: "stored-pi-id" }]]),
    );
    await handleStartSession(fakeSender() as never, {
      type: "start_session_request",
      id: "agy-fresh",
      cwd: "/x",
      agent: "agy",
    } as StartMsg);
    await flush();
    expect(openTerminalTab).toHaveBeenCalledWith("/x", "remote-pi agy", {
      newWindow: true,
      sessionName: "room-1",
      size: { ...AGY_TMUX_SIZE },
    });
  });

  test("Pi with a model continues or resumes with `--model`", async () => {
    await handleStartSession(fakeSender() as never, {
      type: "start_session_request",
      id: "pi-1",
      cwd: "/x",
      provider: "zai",
      model_id: "glm-5.3-flash",
    } as StartMsg);
    await flush();
    expect(openTerminalTab).toHaveBeenCalledWith("/x", "pi --continue --model zai/glm-5.3-flash", {
      newWindow: true,
      sessionName: "room-1",
    });
  });

  test("an unknown agent is refused before the folder is checked", async () => {
    const s = fakeSender();
    await handleStartSession(s as never, {
      type: "start_session_request",
      id: "bad",
      cwd: "",
      agent: "copilot" as never,
    } as StartMsg);
    expect(s.sent[0]).toMatchObject({ ok: false, message: expect.stringMatching(/unknown agent/) });
    expect(openTerminalTab).not.toHaveBeenCalled();
  });

  test("an AGY model the device does not offer opens nothing", async () => {
    vi.mocked(agyModelIds).mockResolvedValue(["gemini-4-neon-high"]);
    const s = fakeSender();
    await handleStartSession(s as never, {
      type: "start_session_request",
      id: "agy-bad",
      cwd: "/x",
      agent: "agy",
      provider: "google",
      model_id: "nope",
    } as StartMsg);
    await flush();
    expect(openTerminalTab).not.toHaveBeenCalled();
    expect(s.sent[0]).toMatchObject({ ok: false, message: expect.stringMatching(/not one of AGY's models/) });
    expect(s.sent[0]).not.toHaveProperty("room_id");
  });
});

describe("terminalKindHere", () => {
  test.skipIf(process.platform !== "win32")("Windows Terminal on PATH is reported as wt", () => {
    _resetLauncherCachesForTests();
    vi.mocked(execFileSync).mockImplementation(((cmd: string) => {
      if (cmd === "where") return "C:\\Tools\\tool.exe\r\n";
      throw new Error(`unexpected command ${cmd}`);
    }) as never);
    expect(terminalKindHere()).toBe("wt");
  });

  test.skipIf(process.platform !== "win32")("without Windows Terminal the console window is reported", () => {
    _resetLauncherCachesForTests();
    vi.mocked(execFileSync).mockImplementation(((cmd: string) => {
      throw new Error(`not found: ${cmd}`);
    }) as never);
    expect(terminalKindHere()).toBe("window");
  });

  test.skipIf(process.platform === "win32")("other desktop platforms have no terminal launcher", () => {
    expect(terminalKindHere()).toBe("none");
  });
});
