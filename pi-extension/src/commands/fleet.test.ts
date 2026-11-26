/**
 * Plan/173 review — `remote-pi daemon status` must FAIL (non-zero exit) when
 * the supervisor does not answer. On the phone an exit-code-based health probe
 * read a wedged supervisor ("supervisor reply timeout") as healthy because the
 * command only printed the error and exited 0.
 *
 * `cmdDaemonStatus` is tested directly with the supervisor client mocked, and
 * the CLI mapping (`process.exitCode = 1`) through `runCli` with the same mock.
 */
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

vi.mock("../daemon/client.js", () => ({
  callSupervisor: vi.fn(),
  supervisorOnline: vi.fn(async () => false),
  SupervisorOfflineError: class SupervisorOfflineError extends Error {
    constructor(public readonly sockPath: string) {
      super(`Supervisor is not running. UDS not responding at ${sockPath}.`);
      this.name = "SupervisorOfflineError";
    }
  },
}));

import { callSupervisor, SupervisorOfflineError } from "../daemon/client.js";
import { cmdDaemonStatus } from "./fleet.js";
import { runCli } from "../main.js";

interface Notify {
  level: "info" | "warning" | "error";
  text: string;
}

function ctx(): { ui: { notify: (text: string, level?: Notify["level"]) => void }; sent: Notify[] } {
  const sent: Notify[] = [];
  return { ui: { notify: (text, level = "info") => { sent.push({ level, text }); } }, sent };
}

beforeEach(() => {
  vi.mocked(callSupervisor).mockReset();  process.exitCode = undefined as unknown as typeof process.exitCode;
});

afterEach(() => {
  process.exitCode = undefined as unknown as typeof process.exitCode;
});

describe("cmdDaemonStatus — exit-code truth (plan/173 review)", () => {
  test("answers true and prints the fleet when the supervisor replies", async () => {
    vi.mocked(callSupervisor).mockResolvedValue({
      daemons: [{ id: "device", cwd: "/home", name: "device", state: "running", pid: 42, uptime_s: 5 }],
    } as never);
    const c = ctx();
    expect(await cmdDaemonStatus(c as never)).toBe(true);
    expect(c.sent).toHaveLength(1);
    expect(c.sent[0]!.text).toContain("[remote-pi] Fleet status:");
  });

  test("a reply timeout (wedged supervisor) answers false instead of a clean 0", async () => {
    vi.mocked(callSupervisor).mockRejectedValue(new Error("supervisor reply timeout"));
    const c = ctx();
    expect(await cmdDaemonStatus(c as never)).toBe(false);
    expect(c.sent[0]).toMatchObject({ level: "error" });
    expect(c.sent[0]!.text).toContain("status failed: Error: supervisor reply timeout");
  });

  test("offline answers false too", async () => {
    vi.mocked(callSupervisor).mockRejectedValue(new SupervisorOfflineError("/x/supervisor.sock"));
    const c = ctx();
    expect(await cmdDaemonStatus(c as never)).toBe(false);
    expect(c.sent[0]!.level).toBe("warning");
  });
});

describe("remote-pi daemon status — the CLI maps 'no answer' to a non-zero exit", () => {
  test("reply timeout → exit code 1", async () => {
    vi.mocked(callSupervisor).mockRejectedValue(new Error("supervisor reply timeout"));
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    try {
      await runCli(["node", "dist/index.js", "daemon", "status"]);
    } finally {
      log.mockRestore();
    }
    expect(process.exitCode).toBe(1);
  });

  test("a real reply leaves the exit code alone", async () => {
    vi.mocked(callSupervisor).mockResolvedValue({ daemons: [] } as never);
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    try {
      await runCli(["node", "dist/index.js", "daemon", "status"]);
    } finally {
      log.mockRestore();
    }
    expect(process.exitCode).toBeUndefined();
  });
});
