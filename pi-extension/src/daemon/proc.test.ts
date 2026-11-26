import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  findGuardPids,
  findPidsMatching,
  findSupervisorPids,
  isGuardArgv,
  isPidAlive,
  isSupervisorArgv,
  listPids,
  readCmdline,
} from "./proc.js";

/**
 * Plan/173 — `/proc` lookups the Termux guard relies on, exercised against a
 * fake process table: one directory per pid holding a NUL-separated
 * `cmdline`, exactly like the kernel exposes it.
 */

let proc: string;

/** Registers a fake process; `argv[0]` is the executable. */
function fakeProc(pid: number, argv: string[]): string {
  const dir = join(proc, String(pid));
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "cmdline"), argv.join("\0") + "\0");
  return dir;
}

beforeEach(() => {
  proc = mkdtempSync(join(tmpdir(), "pi-proc-"));
  // Non-numeric entries exist in a real /proc and must be ignored.
  mkdirSync(join(proc, "self"));
  mkdirSync(join(proc, "irq"));
});

afterEach(() => {
  rmSync(proc, { recursive: true, force: true });
});

describe("argv predicates", () => {
  test("the supervisor is recognised by its script, also through the symlink", () => {
    expect(isSupervisorArgv(["/usr/bin/node", "/x/remote-pi/dist/bin/supervisord.js"])).toBe(true);
    expect(isSupervisorArgv(["/usr/bin/node", "/home/u/.local/bin/pi-supervisord"])).toBe(true);
  });

  test("node itself, the CLI and a daemon child are not the supervisor", () => {
    expect(isSupervisorArgv(["/usr/bin/supervisord", "/x/index.js"])).toBe(false);
    expect(isSupervisorArgv(["/usr/bin/node", "/x/remote-pi/dist/index.js", "doctor"])).toBe(false);
    expect(isSupervisorArgv(["pi", "--mode", "rpc", "-e", "/x/remote-pi/dist/index.js"])).toBe(false);
  });

  test("the guard is `node …/index.js guard run` with both words as positionals", () => {
    expect(isGuardArgv(["/usr/bin/node", "/x/dist/index.js", "guard", "run"])).toBe(true);
    expect(isGuardArgv(["/usr/bin/node", "/home/u/.local/bin/remote-pi", "guard", "run"])).toBe(true);
    expect(isGuardArgv(["/usr/bin/node", "/x/dist/index.js", "guard", "status"])).toBe(false);
    expect(isGuardArgv(["/usr/bin/node", "/x/dist/index.js", "daemon", "send", "run", "guard"])).toBe(false);
    expect(isGuardArgv(["pi", "explain", "the", "guard", "run"])).toBe(false);
  });
});

describe("readCmdline / listPids / isPidAlive", () => {
  test("argv is NUL-split without the trailing empty piece; unreadable → null", () => {
    fakeProc(42, ["/bin/node", "/x/dist/index.js"]);
    expect(readCmdline(proc, 42)).toEqual(["/bin/node", "/x/dist/index.js"]);
    expect(readCmdline(proc, 999)).toBeNull();
  });

  test("listPids keeps numbers only and can exclude the caller", () => {
    fakeProc(7, ["a"]);
    fakeProc(8, ["b"]);
    expect(listPids(proc).sort((a, b) => a - b)).toEqual([7, 8]);
    expect(listPids(proc, 7)).toEqual([8]);
    expect(listPids(join(proc, "nope"))).toEqual([]);
  });

  test("isPidAlive is a directory check", () => {
    fakeProc(7, ["a"]);
    expect(isPidAlive(7, proc)).toBe(true);
    expect(isPidAlive(8, proc)).toBe(false);
  });
});

describe("findPidsMatching / findSupervisorPids / findGuardPids", () => {
  test("finds exactly the matching processes and skips the excluded pid", () => {
    fakeProc(100, ["/bin/node", "/x/remote-pi/dist/bin/supervisord.js"]);
    fakeProc(101, ["/bin/node", "/x/remote-pi/dist/index.js", "guard", "run"]);
    fakeProc(102, ["pi", "--mode", "rpc", "-e", "/x/remote-pi/dist/index.js", "--name", "supervisord.js"]);
    fakeProc(103, ["/bin/node", "/home/u/.local/bin/pi-supervisord"]);
    fakeProc(104, ["/bin/node", "/x/remote-pi/dist/index.js", "daemon", "status"]);

    expect(findSupervisorPids(proc).sort((a, b) => a - b)).toEqual([100, 103]);
    expect(findGuardPids(proc)).toEqual([101]);
    // `excludePid` is always dropped, even when its argv matches.
    expect(findPidsMatching(isSupervisorArgv, proc, 100).sort((a, b) => a - b)).toEqual([103]);
  });

  test("an unreadable table answers with an empty list, never a throw", () => {
    expect(findSupervisorPids(join(proc, "missing"))).toEqual([]);
  });
});
