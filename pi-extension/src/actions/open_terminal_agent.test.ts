/**
 * Plan/173 A2 — `handleOpenTerminal` honors `agent` and the one-session
 * model, observed at the process boundary.
 *
 * The module's own `openTerminalTab` cannot be swapped out from outside (the
 * handler calls the module-internal binding), so these tests drive the real
 * launcher with a mocked `child_process`: git never runs and `tmux` is a fake
 * child. Termux detection is forced on, so the tmux branch runs on every
 * platform and the command the handler built is visible as tmux's last
 * argument. `agyModelIds` is mocked, so no agy is started.
 */
import { afterAll, beforeEach, describe, expect, test, vi } from "vitest";
import { EventEmitter } from "node:events";
import { execFileSync, spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";

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
vi.mock("../termux.js", () => ({ isTermux: vi.fn(() => true) }));
vi.mock("./agent_models.js", () => ({ agyModelIds: vi.fn(), listAgyModels: vi.fn(), probeAgy: vi.fn() }));

import { handleOpenTerminal, AGY_TMUX_SIZE } from "./open_terminal.js";
import { TERMUX_DAEMON_SCRUB } from "./termux.js";
import { agyModelIds } from "./agent_models.js";
import type { ClientMessage, ServerMessage } from "../protocol/types.js";

type OpenMsg = Extract<ClientMessage, { type: "open_terminal_request" }>;

/** A real folder: the handler checks that the base project exists. */
const PROJ = mkdtempSync(join(tmpdir(), "rp-173-a2-"));
afterAll(() => {
  rmSync(PROJ, { recursive: true, force: true });
});

function fakeSender() {
  const sent: ServerMessage[] = [];
  return { send: (m: ServerMessage) => sent.push(m), sent };
}

function flush() {
  return new Promise((r) => setImmediate(r));
}

function fakeChild(): ChildProcess {
  const child = new EventEmitter() as unknown as ChildProcess;
  (child as unknown as { stdout: EventEmitter }).stdout = new EventEmitter();
  (child as unknown as { stderr: EventEmitter }).stderr = new EventEmitter();
  (child as unknown as { kill: () => void }).kill = vi.fn();
  (child as unknown as { unref: () => void }).unref = vi.fn();
  return child;
}

/** The worktree folder `createWorktree` reports for `base`: a sibling named
 *  `<base>_work_<stamp>` (branch `work/<stamp>`). */
function worktreeFolderOf(base: string): string {
  return join(dirname(base), `${basename(base)}_work_`);
}

/** Run the request to the point where tmux was started, let tmux answer 0,
 *  and return what the handler replied plus tmux's argument vector. */
async function start(msg: OpenMsg): Promise<{ sent: ServerMessage[]; tmuxArgs: string[] | null }> {
  const s = fakeSender();
  const done = handleOpenTerminal(s as never, msg, null);
  await flush();
  const call = vi.mocked(spawn).mock.calls.at(-1);
  if (!call) {
    await done;
    return { sent: s.sent, tmuxArgs: null };
  }
  const child = (spawn as unknown as { mock: { results: unknown[] } }).mock.results.at(-1)?.value as ChildProcess;
  child.emit("close", 0);
  await done;
  return { sent: s.sent, tmuxArgs: call[1] as string[] };
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(spawn).mockReset();
  vi.mocked(spawn).mockImplementation((() => fakeChild()) as never);
  vi.mocked(agyModelIds).mockReset();
  vi.mocked(agyModelIds).mockResolvedValue(null);
});

describe("handleOpenTerminal with an agent (plan/173)", () => {
  test("an untouched request behaves exactly as before: pi in a tmux session named after the room", async () => {
    const { sent, tmuxArgs } = await start({ type: "open_terminal_request", id: "plain", cwd: PROJ });
    expect(tmuxArgs).not.toBeNull();
    expect(tmuxArgs).toEqual([
      "new-session",
      "-d",
      "-s",
      "room-1",
      "-c",
      expect.stringContaining(worktreeFolderOf(PROJ)),
      `${TERMUX_DAEMON_SCRUB}; pi`,
    ]);
    expect(sent[0]).toMatchObject({
      type: "open_terminal_result",
      ok: true,
      method: "tmux",
      worktree: expect.objectContaining({ base: PROJ }),
    });
    expect(agyModelIds).not.toHaveBeenCalled();
  });

  test("an unknown agent is refused before a worktree is created", async () => {
    const { sent, tmuxArgs } = await start({
      type: "open_terminal_request",
      id: "bad-agent",
      cwd: PROJ,
      agent: "copilot" as never,
    });
    expect(tmuxArgs).toBeNull();
    expect(sent[0]).toMatchObject({
      type: "open_terminal_result",
      ok: false,
      method: "none",
      message: expect.stringMatching(/unknown agent "copilot"/),
    });
    expect(execFileSync).not.toHaveBeenCalled();
  });

  test("a model half alone is refused", async () => {
    const { sent, tmuxArgs } = await start({
      type: "open_terminal_request",
      id: "half",
      cwd: PROJ,
      model_id: "glm-5.3-flash",
    });
    expect(tmuxArgs).toBeNull();
    expect(sent[0]).toMatchObject({ ok: false, message: expect.stringMatching(/both provider and model_id/) });
    expect(execFileSync).not.toHaveBeenCalled();
  });

  test("a plain shell cannot start AGY", async () => {
    const { sent, tmuxArgs } = await start({
      type: "open_terminal_request",
      id: "shell-agy",
      cwd: PROJ,
      runPi: false,
      agent: "agy",
    });
    expect(tmuxArgs).toBeNull();
    expect(sent[0]).toMatchObject({ ok: false, message: expect.stringMatching(/cannot start agy/) });
    expect(execFileSync).not.toHaveBeenCalled();
  });

  test("an AGY model the device does not offer is refused, and no worktree is left behind", async () => {
    vi.mocked(agyModelIds).mockResolvedValue(["gemini-4-neon-high"]);
    const { sent, tmuxArgs } = await start({
      type: "open_terminal_request",
      id: "agy-bad-model",
      cwd: PROJ,
      agent: "agy",
      provider: "google",
      model_id: "nope",
    });
    expect(tmuxArgs).toBeNull();
    expect(sent[0]).toMatchObject({
      type: "open_terminal_result",
      ok: false,
      message: expect.stringMatching(/not one of AGY's models/),
    });
    expect(execFileSync).not.toHaveBeenCalled();
    expect(spawn).not.toHaveBeenCalled();
  });

  test("AGY with a model runs `remote-pi agy --model <id>` with a canvas up front", async () => {
    vi.mocked(agyModelIds).mockResolvedValue(["gemini-4-neon-high", "claude-opus-5-5-high"]);
    const { sent, tmuxArgs } = await start({
      type: "open_terminal_request",
      id: "agy-ok",
      cwd: PROJ,
      agent: "agy",
      provider: "google",
      model_id: "gemini-4-neon-high",
    });
    // The display provider the app sent never reaches the command line.
    expect(tmuxArgs?.at(-1)).toBe(`${TERMUX_DAEMON_SCRUB}; remote-pi agy --model gemini-4-neon-high`);
    expect(tmuxArgs).toEqual(expect.arrayContaining(["-x", String(AGY_TMUX_SIZE.cols), "-y", String(AGY_TMUX_SIZE.rows)]));
    expect(sent[0]).toMatchObject({ ok: true, method: "tmux", message: expect.stringContaining("remote-pi agy") });
  });

  test("AGY without a model runs the bare wrapper", async () => {
    const { tmuxArgs } = await start({
      type: "open_terminal_request",
      id: "agy-plain",
      cwd: PROJ,
      agent: "agy",
    });
    expect(tmuxArgs?.at(-1)).toBe(`${TERMUX_DAEMON_SCRUB}; remote-pi agy`);
  });

  test("Pi with a model runs `pi --model provider/id`, sized by the first attach", async () => {
    const { tmuxArgs } = await start({
      type: "open_terminal_request",
      id: "pi-model",
      cwd: PROJ,
      provider: "zai",
      model_id: "glm-5.3-flash",
    });
    expect(tmuxArgs?.at(-1)).toBe(`${TERMUX_DAEMON_SCRUB}; pi --model zai/glm-5.3-flash`);
    expect(tmuxArgs).not.toContain("-x");
    expect(agyModelIds).not.toHaveBeenCalled();
  });
});
