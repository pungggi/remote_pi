import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  CLK_TCK,
  findGuardPids,
  findInterimGuardPids,
  findPidsMatching,
  findSupervisorPids,
  isGuardArgv,
  isInterimGuardArgv,
  isNodeExecutable,
  isPidAlive,
  isSupervisorArgv,
  listPids,
  parseBootTimeMs,
  parseStartTicks,
  processStartMs,
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

const NODE = "/data/data/com.termux/files/usr/bin/node";
const SUP = "/data/data/com.termux/files/usr/lib/node_modules/remote-pi/dist/bin/supervisord.js";

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
  test("only the node executable itself counts as node", () => {
    expect(isNodeExecutable(NODE)).toBe(true);
    expect(isNodeExecutable("/usr/bin/nodejs")).toBe(true);
    expect(isNodeExecutable("node")).toBe(true);
    expect(isNodeExecutable("C:\\Program Files\\nodejs\\node.exe")).toBe(false); // not a POSIX node
    expect(isNodeExecutable("/bin/bash")).toBe(false);
    expect(isNodeExecutable(undefined)).toBe(false);
  });

  test("the supervisor is the node process running the supervisor script, also through the symlink", () => {
    expect(isSupervisorArgv([NODE, SUP])).toBe(true);
    expect(isSupervisorArgv([NODE, "--max-old-space-size=512", SUP])).toBe(true);
    expect(isSupervisorArgv(["node", "/data/data/com.termux/files/home/.local/bin/pi-supervisord"])).toBe(true);
    expect(isSupervisorArgv(["node", "supervisord.js"])).toBe(true);
  });

  test("decoys that merely mention the name are never the supervisor (plan/173 review)", () => {
    // A launcher shell wrapping the real command.
    expect(isSupervisorArgv(["/bin/bash", "-c", `nohup ${NODE} ${SUP} >> log 2>&1 &`])).toBe(false);
    expect(isSupervisorArgv(["/system/bin/sh", "-c", `node ${SUP}`])).toBe(false);
    // An editor, a grep, a tmux command line.
    expect(isSupervisorArgv(["vim", SUP])).toBe(false);
    expect(isSupervisorArgv(["grep", "-n", "supervisord.js", "install.ts"])).toBe(false);
    expect(isSupervisorArgv(["tmux", "new-session", "-d", "-s", "x", `node ${SUP}`])).toBe(false);
    // A daemon child whose agent NAME looks like the script.
    expect(isSupervisorArgv(["pi", "--mode", "rpc", "-e", "/x/index.js", "--name", "supervisord.js"])).toBe(false);
    // node running something else.
    expect(isSupervisorArgv([NODE, "/x/remote-pi/dist/index.js", "daemon", "status"])).toBe(false);
    expect(isSupervisorArgv([])).toBe(false);
  });

  test("the guard is `node …/index.js guard run` with both words behind the entry script", () => {
    expect(isGuardArgv([NODE, "/x/dist/index.js", "guard", "run"])).toBe(true);
    expect(isGuardArgv([NODE, "/home/u/.local/bin/remote-pi", "guard", "run"])).toBe(true);
    expect(isGuardArgv([NODE, "/x/dist/index.js", "guard", "status"])).toBe(false);
    expect(isGuardArgv([NODE, "/x/dist/index.js", "daemon", "send", "run", "guard"])).toBe(false);
    expect(isGuardArgv(["pi", "explain", "the", "guard", "run"])).toBe(false);
    expect(isGuardArgv(["bash", "-c", "node /x/dist/index.js guard run"])).toBe(false);
  });

  test("node options with a value of their own before the script (a wrapper's `--require` shim) do not hide the guard", () => {
    // 0.10.0 read the first non-option argument as the script: that was the
    // shim, so the running guard looked dead.
    const SHIM = "/data/data/com.termux/files/home/.pi/piper/android-shim.cjs";
    expect(isGuardArgv([NODE, "--require", SHIM, "/x/dist/index.js", "guard", "run"])).toBe(true);
    expect(isGuardArgv([NODE, `--require=${SHIM}`, "--no-warnings", "/x/dist/index.js", "guard", "run"])).toBe(true);
    expect(isGuardArgv([NODE, "--import", "/x/shim.mjs", "--enable-source-maps", "/home/u/.local/bin/remote-pi", "guard", "run"]))
      .toBe(true);
    // The entry script still has to be ours, followed by `guard run`.
    expect(isGuardArgv([NODE, "--require", SHIM, "/x/dist/index.js", "guard", "status"])).toBe(false);
    expect(isGuardArgv([NODE, "--require", SHIM, SUP])).toBe(false);
    // And it still has to be node that runs it.
    expect(isGuardArgv(["/bin/bash", "--require", SHIM, "/x/dist/index.js", "guard", "run"])).toBe(false);
    expect(isGuardArgv([])).toBe(false);
    // Not any `…/index.js guard run` anywhere: the FIRST argument that looks
    // like the entry script decides. An earlier one followed by other words
    // is the entry of some other command (review on #130).
    expect(isGuardArgv([NODE, "/x/dist/index.js", "daemon", "status", "--require", "/y/index.js", "guard", "run"]))
      .toBe(false);
    expect(isGuardArgv([NODE, "--require", SHIM, "/x/dist/index.js", "daemon", "status", "--require", SHIM, "index.js", "guard", "run"]))
      .toBe(false);
    // A shim that is itself named like the entry is still told apart: it is
    // the module behind the preload option, not the script node runs.
    expect(isGuardArgv([NODE, "--require", "/x/index.js", "/x/dist/index.js", "guard", "run"])).toBe(true);
    expect(isGuardArgv([NODE, "--require=/x/index.js", "/x/dist/index.js", "guard", "run"])).toBe(true);
    // The shim alone, without the entry script, is not the guard.
    expect(isGuardArgv([NODE, "--require", "/x/index.js", "guard", "run"])).toBe(false);
  });

  test("the interim shell guard is a shell running piper-guard.sh, never a node process mentioning it", () => {
    expect(isInterimGuardArgv(["/data/data/com.termux/files/usr/bin/bash", "/data/data/com.termux/files/home/.pi/piper/piper-guard.sh"])).toBe(true);
    expect(isInterimGuardArgv(["/system/bin/sh", "-c", "bash ~/.pi/piper/piper-guard.sh"])).toBe(true);
    expect(isInterimGuardArgv(["dash", "/home/u/.pi/piper/piper-guard.sh"])).toBe(true);
    expect(isInterimGuardArgv([NODE, "/x/dist/index.js", "guard", "run", "--note", "piper-guard.sh"])).toBe(false);
    expect(isInterimGuardArgv(["vim", "/home/u/.pi/piper/piper-guard.sh"])).toBe(false);
    expect(isInterimGuardArgv([NODE, "/x/dist/index.js", "guard", "run"])).toBe(false);
  });

  // The AI review suspected the shell test also matches a bare "a" or "k".
  // As written the trailing "sh" is mandatory; this pins it down.
  test("interim-guard shell test: every real shell matches, no bare letter or look-alike does", () => {
    const argv = (shell: string) => [shell, "/home/u/.pi/piper/piper-guard.sh"];
    for (const shell of ["sh", "ash", "bash", "dash", "zsh", "ksh", "/bin/bash", "/system/bin/sh", "/data/data/com.termux/files/usr/bin/bash"]) {
      expect(isInterimGuardArgv(argv(shell)), shell).toBe(true);
    }
    for (const shell of ["a", "k", "z", "da", "ba", "b", "d", "ash5", "bashx", "myscript.sh", "sh.d", "fish", "node", "/bin/node", ""]) {
      expect(isInterimGuardArgv(argv(shell)), shell).toBe(false);
    }
  });
});

describe("readCmdline / listPids / isPidAlive", () => {
  test("argv is NUL-split without the trailing empty piece; unreadable → null", () => {
    fakeProc(42, ["/bin/node", "/x/dist/index.js"]);
    expect(readCmdline(proc, 42)).toEqual(["/bin/node", "/x/dist/index.js"]);
    expect(readCmdline(proc, 999)).toBeNull();
  });

  test("listPids keeps numbers only and can exclude several pids (own pid and parent)", () => {
    fakeProc(7, ["a"]);
    fakeProc(8, ["b"]);
    fakeProc(9, ["c"]);
    expect(listPids(proc).sort((a, b) => a - b)).toEqual([7, 8, 9]);
    expect(listPids(proc, 7, 9)).toEqual([8]);
    expect(listPids(join(proc, "nope"))).toEqual([]);
  });

  test("isPidAlive is a directory check", () => {
    fakeProc(7, ["a"]);
    expect(isPidAlive(7, proc)).toBe(true);
    expect(isPidAlive(8, proc)).toBe(false);
  });
});

describe("findPidsMatching / findSupervisorPids / findGuardPids / findInterimGuardPids", () => {
  test("finds exactly the matching processes, skips the excluded pids, ignores decoys", () => {
    fakeProc(100, [NODE, SUP]);
    fakeProc(101, [NODE, "/x/remote-pi/dist/index.js", "guard", "run"]);
    fakeProc(102, ["pi", "--mode", "rpc", "-e", "/x/remote-pi/dist/index.js", "--name", "supervisord.js"]);
    fakeProc(103, ["node", "/home/u/.local/bin/pi-supervisord"]);
    fakeProc(104, [NODE, "/x/remote-pi/dist/index.js", "daemon", "status"]);
    fakeProc(105, ["bash", "-c", `nohup node ${SUP} >> ~/.pi/piper/boot.log 2>&1 &`]);
    fakeProc(106, ["vim", SUP]);
    fakeProc(107, ["/data/data/com.termux/files/usr/bin/bash", "/home/u/.pi/piper/piper-guard.sh"]);
    fakeProc(108, [NODE, "--max-old-space-size=512", SUP]);
    // A guard started through a wrapper's `--require` shim, and a shell merely carrying the same words.
    fakeProc(109, [NODE, "--require", "/home/u/.pi/piper/android-shim.cjs", "/x/remote-pi/dist/index.js", "guard", "run"]);
    fakeProc(110, ["bash", "--require", "/x/shim.cjs", "/x/remote-pi/dist/index.js", "guard", "run"]);

    expect(findSupervisorPids(proc).sort((a, b) => a - b)).toEqual([100, 103, 108]);
    expect(findGuardPids(proc).sort((a, b) => a - b)).toEqual([101, 109]);
    expect(findInterimGuardPids(proc)).toEqual([107]);
    // `excludePids` (own pid and parent in production) is always dropped.
    expect(findPidsMatching(isSupervisorArgv, proc, [100, process.pid]).sort((a, b) => a - b)).toEqual([103, 108]);
  });

  test("an unreadable table answers with an empty list, never a throw", () => {
    expect(findSupervisorPids(join(proc, "missing"))).toEqual([]);
    expect(findGuardPids(join(proc, "missing"))).toEqual([]);
  });
});

describe("process age (for the age restart)", () => {
  test("starttime is field 22, read after the LAST ')' of a comm that may contain spaces and parens", () => {
    const plain = `318 (node) S 100 1 1 0 -1 4194560 1234 0 0 0 10 5 0 0 20 0 3 0 4500 1 ...`;
    expect(parseStartTicks(plain)).toBe(4500);
    const awkward = `7 (a weird (name) ) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 77 1 ...`;
    expect(parseStartTicks(awkward)).toBe(77);
    expect(parseStartTicks("no closing paren")).toBeNull();
  });

  test("btime is read from /proc/stat; other lines are ignored", () => {
    expect(parseBootTimeMs("cpu  1 2 3\ncpu0 1 2 3\nbtime 1700000000\nprocesses 5\n")).toBe(1_700_000_000_000);
    expect(parseBootTimeMs("cpu 1 2 3")).toBeNull();
  });

  test("processStartMs = btime + ticks / CLK_TCK, or null when the files are missing", () => {
    writeFileSync(join(proc, "stat"), "cpu 1 2 3\nbtime 1700000000\n");
    const dir = fakeProc(55, [NODE, SUP]);
    // 4500 ticks after boot at 100 Hz = 45 s.
    writeFileSync(join(dir, "stat"), `55 (node) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 4500 1 ...\n`);
    expect(processStartMs(55, proc)).toBe(1_700_000_000_000 + 45_000);
    expect(processStartMs(55, proc, 50)).toBe(1_700_000_000_000 + 90_000);
    expect(CLK_TCK).toBe(100);
    expect(processStartMs(56, proc)).toBeNull();
  });
});
