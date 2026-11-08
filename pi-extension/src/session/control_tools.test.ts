import { describe, expect, test, vi } from "vitest";
import { registerSessionControlTools, type SessionControlDeps } from "./control_tools.js";
import type { ServerMessage } from "../protocol/types.js";
import type { ToolDefinition } from "@earendil-works/pi-coding-agent";

/** Captures tools registered via pi.registerTool (same harness as tools.test.ts). */
function makeMockPi() {
  const tools = new Map<string, ToolDefinition>();
  const pi = {
    registerTool(t: ToolDefinition) {
      tools.set(t.name, t);
    },
  };
  return { pi: pi as unknown as Parameters<typeof registerSessionControlTools>[0], tools };
}

function makeMockPeer() {
  return {
    name: () => "lead",
    address: () => "C:\\proj@lead",
    request: vi.fn().mockResolvedValue({
      from: "other", to: "lead", id: "uuid-reply", re: "uuid-orig",
      body: { rp_control_result: { ok: true, action: "session_compact" } },
    }),
  };
}

function makeDeps(overrides: Partial<SessionControlDeps> = {}): SessionControlDeps {
  return {
    getPeer: () => makeMockPeer(),
    dispatchLocal: vi.fn().mockResolvedValue({
      type: "action_ok", in_reply_to: "x", action: "session_compact",
    } as ServerMessage),
    spawnWorktreeLocal: vi.fn().mockResolvedValue({
      ok: true, message: "Opened terminal tab", path: "C:\\proj_work", branch: "work/x",
    }),
    ...overrides,
  };
}

const TOOL_CALL_ID = "tc_test";
const call = (tool: ToolDefinition, params: unknown) =>
  tool.execute(TOOL_CALL_ID, params, undefined, undefined, {} as never);

describe("plan/161 session-control tools — local path", () => {
  test("session_compact (no target) → dispatchLocal session_compact, ok", async () => {
    const { pi, tools } = makeMockPi();
    const deps = makeDeps();
    registerSessionControlTools(pi, deps);
    const r = await call(tools.get("session_compact")!, {});
    expect(deps.dispatchLocal).toHaveBeenCalledWith(expect.objectContaining({ type: "session_compact" }));
    expect((r.content as { text: string }[])[0].text).toContain("OK");
    expect(r.details).toEqual({ ok: true });
  });

  test("session_reset (no target) → dispatches session_new (fresh context, same process)", async () => {
    const { pi, tools } = makeMockPi();
    const deps = makeDeps();
    registerSessionControlTools(pi, deps);
    await call(tools.get("session_reset")!, {});
    expect(deps.dispatchLocal).toHaveBeenCalledWith(expect.objectContaining({ type: "session_new" }));
  });

  test("local action_error surfaces as FAILED", async () => {
    const { pi, tools } = makeMockPi();
    const deps = makeDeps({
      dispatchLocal: vi.fn().mockResolvedValue({
        type: "action_error", in_reply_to: "x", action: "model_set", error: "not in registry",
      } as ServerMessage),
    });
    registerSessionControlTools(pi, deps);
    const r = await call(tools.get("model_set")!, { provider: "anthropic", model_id: "nope" });
    expect((r.content as { text: string }[])[0].text).toContain("FAILED");
    expect((r.content as { text: string }[])[0].text).toContain("not in registry");
    expect(r.details).toEqual({ ok: false });
  });

  test("list_models local formats models + current marker", async () => {
    const { pi, tools } = makeMockPi();
    const m = (id: string) => ({
      id, name: `Model ${id}`, provider: "anthropic", reasoning: false, context_window: 1000,
    });
    const deps = makeDeps({
      dispatchLocal: vi.fn().mockResolvedValue({
        type: "models_list", in_reply_to: "x",
        models: [m("a"), m("b")], current: m("b"),
      } as unknown as ServerMessage),
    });
    registerSessionControlTools(pi, deps);
    const r = await call(tools.get("list_models")!, {});
    const text = (r.content as { text: string }[])[0].text;
    expect(text).toContain("anthropic/a");
    expect(text).toContain("anthropic/b — Model b  ← current");
  });

  test("model_set local passes provider + model_id", async () => {
    const { pi, tools } = makeMockPi();
    const deps = makeDeps();
    registerSessionControlTools(pi, deps);
    await call(tools.get("model_set")!, { provider: "openai", model_id: "gpt-x" });
    expect(deps.dispatchLocal).toHaveBeenCalledWith(
      expect.objectContaining({ type: "model_set", provider: "openai", model_id: "gpt-x" }),
    );
  });

  test("spawn_worktree local returns path/branch + mesh hint", async () => {
    const { pi, tools } = makeMockPi();
    const deps = makeDeps();
    registerSessionControlTools(pi, deps);
    const r = await call(tools.get("spawn_worktree")!, { branch: "feat/x" });
    expect(deps.spawnWorktreeLocal).toHaveBeenCalledWith(
      expect.objectContaining({ branch: "feat/x" }),
    );
    const text = (r.content as { text: string }[])[0].text;
    expect(text).toContain("C:\\proj_work");
    expect(text).toContain("work/x");
    expect(text).toContain("list_peers");
    expect(r.details).toEqual({ ok: true, path: "C:\\proj_work", branch: "work/x" });
  });

  test("spawn_worktree provider without model_id is refused before spawning", async () => {
    const { pi, tools } = makeMockPi();
    const deps = makeDeps();
    registerSessionControlTools(pi, deps);
    const r = await call(tools.get("spawn_worktree")!, { provider: "anthropic" });
    expect(deps.spawnWorktreeLocal).not.toHaveBeenCalled();
    expect((r.content as { text: string }[])[0].text).toContain("both provider and model_id");
  });
});

describe("plan/161 session-control tools — remote path", () => {
  test("session_compact with target → $rp_control envelope via peer.request", async () => {
    const { pi, tools } = makeMockPi();
    const peer = makeMockPeer();
    const deps = makeDeps({ getPeer: () => peer });
    registerSessionControlTools(pi, deps);
    const r = await call(tools.get("session_compact")!, { target: "other-pc:C:\\p@worker" });
    expect(peer.request).toHaveBeenCalledWith(
      "other-pc:C:\\p@worker",
      { $rp_control: { op: "session_compact" } },
      30_000,
    );
    expect((r.content as { text: string }[])[0].text).toContain("OK");
    expect(deps.dispatchLocal).not.toHaveBeenCalled();
  });

  test("remote failure reply formats as FAILED on target", async () => {
    const { pi, tools } = makeMockPi();
    const peer = makeMockPeer();
    peer.request.mockResolvedValue({
      body: { rp_control_result: { ok: false, action: "model_set", error: "not in registry" } },
    });
    registerSessionControlTools(pi, makeDeps({ getPeer: () => peer }));
    const r = await call(tools.get("model_set")!, {
      provider: "p", model_id: "m", target: "t@w",
    });
    expect((r.content as { text: string }[])[0].text).toContain("FAILED");
    expect((r.content as { text: string }[])[0].text).toContain("t@w");
    expect((r.content as { text: string }[])[0].text).toContain("not in registry");
  });

  test("remote spawn result includes path/branch + mesh hint", async () => {
    const { pi, tools } = makeMockPi();
    const peer = makeMockPeer();
    peer.request.mockResolvedValue({
      body: {
        rp_control_result: {
          ok: true, action: "spawn_worktree",
          message: "Opened terminal tab", path: "/home/u/proj_x", branch: "work/y",
        },
      },
    });
    registerSessionControlTools(pi, makeDeps({ getPeer: () => peer }));
    const r = await call(tools.get("spawn_worktree")!, { branch: "work/y", target: "pc2:/p@w" });
    const text = (r.content as { text: string }[])[0].text;
    expect(text).toContain("/home/u/proj_x");
    expect(text).toContain("list_peers");
  });

  test("self-address target is refused (omit target instead)", async () => {
    const { pi, tools } = makeMockPi();
    const peer = makeMockPeer(); // address "C:\proj@lead"
    const deps = makeDeps({ getPeer: () => peer });
    registerSessionControlTools(pi, deps);
    const r = await call(tools.get("session_reset")!, { target: "C:\\proj@lead" });
    expect((r.content as { text: string }[])[0].text).toContain("your own address");
    expect(peer.request).not.toHaveBeenCalled();
    expect(deps.dispatchLocal).not.toHaveBeenCalled();
  });

  test("target without a mesh peer → NOT_IN_SESSION", async () => {
    const { pi, tools } = makeMockPi();
    const deps = makeDeps({ getPeer: () => null });
    registerSessionControlTools(pi, deps);
    const r = await call(tools.get("session_compact")!, { target: "t@w" });
    expect((r.content as { text: string }[])[0].text).toContain("Not in a session");
  });

  test("transport failure (timeout) formats without throwing", async () => {
    const { pi, tools } = makeMockPi();
    const peer = makeMockPeer();
    peer.request.mockRejectedValue(new Error("request to t@w timed out after 30000ms"));
    registerSessionControlTools(pi, makeDeps({ getPeer: () => peer }));
    const r = await call(tools.get("list_models")!, { target: "t@w" });
    expect((r.content as { text: string }[])[0].text).toContain("Remote control failed");
    expect(r.details).toEqual({ ok: false });
  });
});
