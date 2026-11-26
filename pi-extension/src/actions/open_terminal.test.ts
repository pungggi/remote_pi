import { beforeEach, describe, expect, test, vi } from "vitest";

vi.mock("node:child_process", () => ({
  execFileSync: vi.fn(),
  spawn: vi.fn(),
}));

import { execFileSync, spawn } from "node:child_process";
import { openTerminalTab } from "./open_terminal.js";
import { isTermux } from "../termux.js";

function fakeChild() {
  return {
    on: vi.fn(),
    unref: vi.fn(),
  };
}

function finishWithClose(child: ReturnType<typeof fakeChild>, code = 0): void {
  const close = child.on.mock.calls.find((call) => call[0] === "close")?.[1] as
    | ((code: number | null) => void)
    | undefined;
  if (!close) throw new Error("close listener not registered");
  close(code);
}

// Off Windows (and off Termux, which has its own tmux branch in
// termux.test.ts) openTerminalTab answers "unsupported" and must not spawn
// anything. This runs on the Linux CI legs, where the wt.exe block above is
// skipped, so the non-Windows branch keeps its own coverage there (review on
// #128).
describe.skipIf(process.platform === "win32" || isTermux())("openTerminalTab off Windows", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  test("answers ok:false unsupported, method none, and spawns nothing", async () => {
    const outcome = await openTerminalTab("/home/me/project", "pi");
    expect(outcome.ok).toBe(false);
    expect(outcome.method).toBe("none");
    expect(outcome.message).toMatch(/only supported on Windows/);
    expect(spawn).not.toHaveBeenCalled();
    expect(execFileSync).not.toHaveBeenCalled();
  });
});

// The wt.exe path only exists on win32; everywhere else openTerminalTab
// answers "unsupported" without spawning (the Termux branch is covered in
// termux.test.ts), so these spawn-shape assertions cannot hold off Windows.
describe.skipIf(process.platform !== "win32")("openTerminalTab window visibility", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // resolveShell() and resolveWt() both use `where`; a single fake hit is
    // enough to satisfy both and no real terminal is spawned by these tests.
    vi.mocked(execFileSync).mockReturnValue("C:\\tool.exe\r\n" as never);
  });

  test("exact-resume mode requests a NEW visible Windows Terminal window", async () => {
    const child = fakeChild();
    vi.mocked(spawn).mockReturnValue(child as never);

    const pending = openTerminalTab("C:\\proj", "pi --session 'saved-id'", { newWindow: true });
    finishWithClose(child);
    const outcome = await pending;

    expect(outcome.ok).toBe(true);
    const [command, , options] = vi.mocked(spawn).mock.calls[0]!;
    expect(command).toContain("-w new new-tab");
    expect(options).toMatchObject({ windowsHide: false });
    expect(outcome.message).toContain("Opened terminal window");
  });

  test("default worktree flow keeps the legacy MRU tab behavior", async () => {
    const child = fakeChild();
    vi.mocked(spawn).mockReturnValue(child as never);

    const pending = openTerminalTab("C:\\proj", "pi");
    finishWithClose(child);
    const outcome = await pending;

    expect(outcome.ok).toBe(true);
    const [command, , options] = vi.mocked(spawn).mock.calls[0]!;
    expect(command).toContain("-w 0 new-tab");
    expect(options).toMatchObject({ windowsHide: true });
    expect(outcome.message).toContain("Opened terminal tab");
  });
});
