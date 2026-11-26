/**
 * Plan/173 A3 — the Termux tmux launcher. tmux itself is never started here:
 * `spawn` is injected, so the argument building, the exit-code mapping and
 * the two failure shapes the phone user will actually meet (no tmux,
 * duplicate session) are plain unit tests.
 */
import { EventEmitter } from "node:events";
import { describe, expect, test } from "vitest";
import type { ChildProcess } from "node:child_process";
import {
  envWithoutDaemonIdentity,
  startTermuxSession,
  termuxShellCommand,
  tmuxFailureMessage,
  tmuxNewSessionArgs,
  tmuxSessionNameOk,
} from "./termux.js";
import { launcherKind } from "./open_terminal.js";

/** Minimal child double: stderr pipe + error/close events, like spawn's. */
function fakeChild() {
  const child = new EventEmitter() as unknown as ChildProcess & {
    stderr: EventEmitter;
    unref: () => void;
    kill: (signal: string) => boolean;
  };
  child.stderr = new EventEmitter();
  child.unref = () => undefined;
  child.kill = () => true;
  return child;
}

type SpawnCall = { cmd: string; args: string[]; options: Record<string, unknown> };

describe("tmux session name + arguments", () => {
  test("room ids (12 base64url chars) are valid tmux names; tmux-hostile ones are not", () => {
    expect(tmuxSessionNameOk("AbC_012-xYZ9ab")).toBe(true);
    expect(tmuxSessionNameOk("device")).toBe(true);
    expect(tmuxSessionNameOk("a.b")).toBe(false);
    expect(tmuxSessionNameOk("a:b")).toBe(false);
    expect(tmuxSessionNameOk("two words")).toBe(false);
    expect(tmuxSessionNameOk("")).toBe(false);
    expect(tmuxSessionNameOk("x".repeat(65))).toBe(false);
  });

  test("new-session: detached, named after the room, in the folder, command last", () => {
    expect(tmuxNewSessionArgs({ session: "AbC_012-xYZ9ab", cwd: "/data/home/source/demo", command: "pi --continue" })).toEqual([
      "new-session", "-d", "-s", "AbC_012-xYZ9ab", "-c", "/data/home/source/demo",
      "unset REMOTE_PI_DIRECT_CONFIG REMOTE_PI_DAEMON; pi --continue",
    ]);
  });

  test("optional -x/-y set the detached window size (TUIs that draw before attach)", () => {
    expect(tmuxNewSessionArgs({ session: "s", cwd: "/x", command: "agy", cols: 210.7, rows: 50 })).toEqual([
      "new-session", "-d", "-s", "s", "-c", "/x", "-x", "210", "-y", "50",
      "unset REMOTE_PI_DIRECT_CONFIG REMOTE_PI_DAEMON; agy",
    ]);
    // Zero / negative sizes are dropped rather than passed to tmux.
    expect(tmuxNewSessionArgs({ session: "s", cwd: "/x", cols: 0, rows: -3 })).not.toContain("-x");
  });

  test("a bad session name is refused before anything is spawned", () => {
    expect(() => tmuxNewSessionArgs({ session: "a.b", cwd: "/x" })).toThrow(/tmux session name/);
  });

  test("the daemon identity is unset in front of the command; no command opens a login shell", () => {
    expect(termuxShellCommand("pi --session 'id'")).toBe("unset REMOTE_PI_DIRECT_CONFIG REMOTE_PI_DAEMON; pi --session 'id'");
    expect(termuxShellCommand(undefined)).toBe(
      "unset REMOTE_PI_DIRECT_CONFIG REMOTE_PI_DAEMON; exec \"${SHELL:-/data/data/com.termux/files/usr/bin/bash}\" -l",
    );
  });

  test("envWithoutDaemonIdentity drops exactly the two daemon variables", () => {
    const out = envWithoutDaemonIdentity({
      PATH: "/x", REMOTE_PI_DIRECT_CONFIG: "{\"room_id\":\"device\"}", REMOTE_PI_DAEMON: "1", REMOTE_PI_RELAY: "http://pc:3000",
    });
    expect(out).toEqual({ PATH: "/x", REMOTE_PI_RELAY: "http://pc:3000" });
  });
});

describe("tmuxFailureMessage", () => {
  test("duplicate session tells the user how to attach instead of failing blind", () => {
    const m = tmuxFailureMessage("room", "duplicate session: room\n");
    expect(m).toContain("already open");
    expect(m).toContain("tmux attach -t room");
  });

  test("any other stderr is passed through, trimmed and bounded", () => {
    expect(tmuxFailureMessage("room", "  no space left on device \n ")).toBe("tmux failed: no space left on device");
    expect(tmuxFailureMessage("room", "")).toBe("tmux failed");
    expect(tmuxFailureMessage("room", "x".repeat(1000))).toHaveLength("tmux failed: ".length + 300);
  });
});

describe("startTermuxSession", () => {
  test("spawns tmux with a scrubbed env and reports success on exit 0", async () => {
    const calls: SpawnCall[] = [];
    const child = fakeChild();
    const pending = startTermuxSession(
      { session: "room", cwd: "/x", command: "pi --continue" },
      {
        spawn: ((cmd: string, args: string[], options: Record<string, unknown>) => {
          calls.push({ cmd, args, options });
          return child;
        }) as never,
      },
    );
    child.stderr.emit("data", "");
    child.emit("close", 0);
    const outcome = await pending;

    expect(outcome.ok).toBe(true);
    expect(outcome.method).toBe("tmux");
    expect(outcome.session).toBe("room");
    expect(outcome.message).toContain("tmux attach -t room");
    expect(calls).toHaveLength(1);
    expect(calls[0]!.cmd).toBe("tmux");
    expect(calls[0]!.args[0]).toBe("new-session");
    expect(calls[0]!.options).toMatchObject({ cwd: "/x", detached: true });
    const env = calls[0]!.options["env"] as Record<string, string>;
    expect(env["REMOTE_PI_DIRECT_CONFIG"]).toBeUndefined();
    expect(env["REMOTE_PI_DAEMON"]).toBeUndefined();
  });

  test("missing tmux (ENOENT) names the package to install", async () => {
    const child = fakeChild();
    const pending = startTermuxSession({ session: "room", cwd: "/x" }, { spawn: (() => child) as never });
    child.emit("error", Object.assign(new Error("spawn tmux ENOENT"), { code: "ENOENT" }));
    const outcome = await pending;
    expect(outcome.ok).toBe(false);
    expect(outcome.method).toBe("none");
    expect(outcome.message).toContain("pkg install tmux");
  });

  test("a non-zero exit with 'duplicate session' is reported as already open", async () => {
    const child = fakeChild();
    const pending = startTermuxSession({ session: "room", cwd: "/x", command: "pi" }, { spawn: (() => child) as never });
    child.stderr.emit("data", Buffer.from("duplicate session: room\n"));
    child.emit("close", 1);
    const outcome = await pending;
    expect(outcome.ok).toBe(false);
    expect(outcome.message).toContain("already open");
  });

  test("a hang is cut off after the timeout and reported", async () => {
    const child = fakeChild();
    const pending = startTermuxSession({ session: "room", cwd: "/x" }, { spawn: (() => child) as never, timeoutMs: 20 });
    const outcome = await pending;
    expect(outcome.ok).toBe(false);
    expect(outcome.message).toContain("did not answer");
  });

  test("a bad session name never reaches spawn", async () => {
    let spawned = 0;
    const outcome = await startTermuxSession(
      { session: "not.ok", cwd: "/x" },
      { spawn: (() => { spawned += 1; return fakeChild(); }) as never },
    );
    expect(outcome.ok).toBe(false);
    expect(spawned).toBe(0);
  });
});

describe("launcherKind (openTerminalTab dispatch)", () => {
  test("Termux wins over the linux platform it reports", () => {
    expect(launcherKind(true, "linux")).toBe("termux");
  });

  test("Windows keeps its launcher and is never mistaken for Termux", () => {
    expect(launcherKind(false, "win32")).toBe("windows");
    expect(launcherKind(false, "linux")).toBe("none");
    expect(launcherKind(false, "darwin")).toBe("none");
  });
});
