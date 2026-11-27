import { describe, expect, test, vi, beforeEach } from "vitest";

// Plan/167 — headless spawn branch of `_spawnWorktreeSession`. Isolated file:
// the module-level mocks here (open_terminal, client, local_config) apply
// only to this test file's module registry, leaving extension.test.ts's
// broader main.ts coverage untouched.

const wt = vi.hoisted(() => ({
  createWorktree: vi.fn(),
  openTerminalTab: vi.fn(),
}));
const sv = vi.hoisted(() => ({
  callSupervisor: vi.fn(),
}));
const cfg = vi.hoisted(() => ({
  loadLocalConfig: vi.fn(),
}));

vi.mock("./actions/open_terminal.js", async (importOriginal) => {
  const orig = await importOriginal<typeof import("./actions/open_terminal.js")>();
  return { ...orig, createWorktree: wt.createWorktree, openTerminalTab: wt.openTerminalTab };
});

// Keep the REAL SupervisorOfflineError (importOriginal spread) so
// `instanceof` in main.ts stays true; only callSupervisor is fake.
vi.mock("./daemon/client.js", async (importOriginal) => {
  const orig = await importOriginal<typeof import("./daemon/client.js")>();
  return { ...orig, callSupervisor: sv.callSupervisor };
});

vi.mock("./session/local_config.js", async (importOriginal) => {
  const orig = await importOriginal<typeof import("./session/local_config.js")>();
  return { ...orig, loadLocalConfig: cfg.loadLocalConfig };
});

// Plan/173 — the AGY catalogue is asked before an AGY worktree is created;
// stubbed so this file never starts agy.
const agy = vi.hoisted(() => ({
  agyModelIds: vi.fn(),
}));
vi.mock("./actions/agent_models.js", () => ({
  agyModelIds: agy.agyModelIds,
  listAgyModels: vi.fn(),
  probeAgy: vi.fn(),
}));

const { _spawnWorktreeSession } = await import("./main.js");

const WT_PATH = "C:\\proj_w167";
const WT_BRANCH = "work/167";

beforeEach(() => {
  wt.createWorktree.mockReset().mockReturnValue({
    ok: true,
    entry: { path: WT_PATH, branch: WT_BRANCH },
    message: `created ${WT_BRANCH}`,
  });
  wt.openTerminalTab.mockReset().mockResolvedValue({ ok: true, message: "Opened terminal tab" });
  sv.callSupervisor.mockReset().mockResolvedValue({
    id: "abcd1234", cwd: WT_PATH, room_id: "r", started: true,
  });
  cfg.loadLocalConfig.mockReset().mockReturnValue({ agent_name: "remote_pi_agents" });
});

describe("plan/167 _spawnWorktreeSession — headless branch", () => {
  test("headless:true → start_transient with seeded agent_name; no terminal; mesh hints in message", async () => {
    const r = await _spawnWorktreeSession({ branch: "work/167", headless: true });
    expect(r.ok).toBe(true);
    expect(sv.callSupervisor).toHaveBeenCalledWith({
      op: "start_transient",
      cwd: WT_PATH,
      name: "remote_pi_agents",
    });
    expect(wt.openTerminalTab).not.toHaveBeenCalled();
    expect(r.message).toContain("headless worker");
    expect(r.message).toContain(`${WT_PATH}@remote_pi_agents`);
    expect(r.message).toContain("agent_send");
    expect(r.message).toContain("session_shutdown");
    expect(r.path).toBe(WT_PATH);
    expect(r.branch).toBe(WT_BRANCH);
  });

  test("headless:true + provider/model_id → joined model reaches start_transient", async () => {
    const r = await _spawnWorktreeSession({
      headless: true,
      provider: "anthropic",
      model_id: "claude-opus-4-7",
    });
    expect(r.ok).toBe(true);
    expect(sv.callSupervisor).toHaveBeenCalledWith({
      op: "start_transient",
      cwd: WT_PATH,
      name: "remote_pi_agents",
      model: "anthropic/claude-opus-4-7",
    });
  });

  test("invalid model token is rejected before createWorktree (headless)", async () => {
    const r = await _spawnWorktreeSession({
      headless: true,
      provider: "anthropic",
      model_id: "bad id with spaces",
    });
    expect(r.ok).toBe(false);
    expect(r.message).toContain("invalid model identifier");
    expect(wt.createWorktree).not.toHaveBeenCalled();
    expect(sv.callSupervisor).not.toHaveBeenCalled();
  });

  test("started:false (already running) → ok with already-running note", async () => {
    sv.callSupervisor.mockResolvedValue({
      id: "abcd1234", cwd: WT_PATH, room_id: "r", started: false,
    });
    const r = await _spawnWorktreeSession({ headless: true });
    expect(r.ok).toBe(true);
    expect(r.message).toContain("already running");
  });

  test("supervisor offline → honest error with hint + kept worktree, NO terminal fallback", async () => {
    sv.callSupervisor.mockImplementation(async () => {
      const { SupervisorOfflineError } = await import("./daemon/client.js");
      throw new SupervisorOfflineError("sock");
    });
    const r = await _spawnWorktreeSession({ headless: true });
    expect(r.ok).toBe(false);
    expect(r.message).toContain("Piper Supervisor is not running");
    expect(r.message).toContain("headless");
    expect(r.message).toContain(WT_PATH);
    expect(wt.openTerminalTab).not.toHaveBeenCalled();
  });

  test("supervisor error reply (ok:false → thrown Error) surfaces the error + kept worktree (ai-review #113 M2)", async () => {
    sv.callSupervisor.mockRejectedValue(new Error("pipe busy"));
    const r = await _spawnWorktreeSession({ headless: true });
    expect(r.ok).toBe(false);
    expect(r.message).toContain("pipe busy");
    expect(r.message).toContain("Worktree kept");
    expect(r.message).toContain(WT_PATH);
  });

  test("headless omitted → visible path unchanged (openTerminalTab)", async () => {
    const r = await _spawnWorktreeSession({ branch: "work/167" });
    expect(r.ok).toBe(true);
    expect(wt.openTerminalTab).toHaveBeenCalledWith(WT_PATH, "pi");
    expect(sv.callSupervisor).not.toHaveBeenCalled();
  });
});

describe("plan/173 _spawnWorktreeSession — model and agent", () => {
  beforeEach(() => {
    agy.agyModelIds.mockReset().mockResolvedValue(null);
  });

  test("null model halves — what the Pi tool and the control envelope send — mean no model", async () => {
    // Regression: `null !== undefined` used to trip the both-or-neither
    // check, so a model-less spawn through either caller was refused.
    const r = await _spawnWorktreeSession({
      base: null, branch: null, provider: null, model_id: null, headless: false, agent: null,
    });
    expect(r.ok).toBe(true);
    expect(wt.openTerminalTab).toHaveBeenCalledWith(WT_PATH, "pi");
  });

  test("a model starts pi with --model provider/id", async () => {
    const r = await _spawnWorktreeSession({ provider: "zai", model_id: "glm-5.3-flash" });
    expect(r.ok).toBe(true);
    expect(wt.openTerminalTab).toHaveBeenCalledWith(WT_PATH, "pi --model zai/glm-5.3-flash");
  });

  test("agent:'agy' runs `remote-pi agy` in the worktree, with a canvas up front", async () => {
    const r = await _spawnWorktreeSession({ agent: "agy" });
    expect(r.ok).toBe(true);
    expect(wt.openTerminalTab).toHaveBeenCalledWith(WT_PATH, "remote-pi agy", {
      size: { cols: 210, rows: 50 },
    });
  });

  test("AGY cannot be headless, and nothing is created for it", async () => {
    const r = await _spawnWorktreeSession({ agent: "agy", headless: true });
    expect(r.ok).toBe(false);
    expect(r.message).toMatch(/cannot start AGY headless/);
    expect(wt.createWorktree).not.toHaveBeenCalled();
  });

  test("an unknown agent is refused before a worktree is created", async () => {
    const r = await _spawnWorktreeSession({ agent: "copilot" });
    expect(r.ok).toBe(false);
    expect(r.message).toMatch(/unknown agent "copilot"/);
    expect(wt.createWorktree).not.toHaveBeenCalled();
  });

  test("an AGY model this device does not offer is refused before a worktree is created", async () => {
    agy.agyModelIds.mockResolvedValue(["gemini-4-neon-high"]);
    const r = await _spawnWorktreeSession({ agent: "agy", provider: "google", model_id: "nope" });
    expect(r.ok).toBe(false);
    expect(r.message).toMatch(/not one of AGY's models/);
    expect(wt.createWorktree).not.toHaveBeenCalled();
  });
});
