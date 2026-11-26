/**
 * Plan/173 — the Termux guard's state machine, driven with a fake clock and
 * recorded side effects: no processes are signalled, no supervisor started,
 * no socket opened except in the one probe test (an isolated pipe / socket,
 * the same way supervisor.test.ts isolates its own).
 */
import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer, createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import {
  DEVICE_RESTART_BUDGET,
  DEVICE_RESTART_COOLDOWN_MS,
  GUARD_INTERVAL_MS,
  SUPERVISOR_BACKOFF_MS,
  WEDGE_MISSES,
  acquireGuardLock,
  appendGuardLog,
  classifyDevice,
  deviceTransitionLine,
  fleetHealthy,
  formatLogLine,
  guardProcessAlive,
  guardStart,
  guardStatus,
  guardStop,
  humanMs,
  probeStatus,
  releaseGuardLock,
  runGuardCli,
  settleBeforeFirstTick,
  tick,
  createGuardState,
  type GuardDeps,
  type GuardState,
} from "./guard.js";
import type { DaemonInfo } from "./control_protocol.js";
import { ipcAddress } from "../session/ipc.js";

const SOCK = "/data/data/com.termux/files/home/.pi/piper/supervisor.sock";
const MIN = 60_000;

function deviceRow(state: DaemonInfo["state"] = "running"): DaemonInfo[] {
  return [{ id: "device", cwd: "/home", name: "device", state }];
}

/** Fake clock + recorded effects. `rows` is the probe script: values are
 *  consumed one per probe, the last one repeats. */
function harness(rows: Array<DaemonInfo[] | null>) {
  let now = 1_700_000_000_000;
  const out = {
    lines: [] as string[],
    starts: [] as number[],
    deviceStarts: [] as number[],
    signals: [] as Array<[number, string]>,
    probes: 0,
    pids: [] as number[],
    alive: new Set<number>(),
    startOk: true,
    deviceStartOk: true,
    sleepMs: [] as number[],
  };
  const script = [...rows];
  const deps: GuardDeps = {
    now: () => now,
    probe: async () => {
      out.probes += 1;
      return script.length > 1 ? script.shift()! : script[0]!;
    },
    supervisorPids: () => out.pids,
    isAlive: (pid) => out.alive.has(pid),
    signal: (pid, sig) => {
      out.signals.push([pid, sig]);
      if (sig === "SIGTERM") out.alive.delete(pid);
      return true;
    },
    sleep: async (ms) => {
      out.sleepMs.push(ms);
    },
    startSupervisor: () => {
      out.starts.push(now);
      return out.startOk;
    },
    startDevice: async () => {
      out.deviceStarts.push(now);
      return out.deviceStartOk;
    },
    log: (line) => out.lines.push(line),
    sockPath: SOCK,
  };
  return {
    deps,
    out,
    state: createGuardState(),
    advance: (ms: number) => { now += ms; },
    /** Re-scripts the probe answers from now on. */
    next: (...values: Array<DaemonInfo[] | null>) => { script.splice(0, script.length, ...values); },
  };
}

const messages = (lines: string[]): string[] => lines.map((l) => l.replace(/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d /, ""));

let tmp: string;

beforeEach(() => {
  tmp = mkdtempSync(join(tmpdir(), "pi-guard-"));
});

afterEach(() => {
  rmSync(tmp, { recursive: true, force: true });
});

describe("pure helpers", () => {
  test("formatLogLine is the watchdog's local-time layout; humanMs reads naturally", () => {
    const line = formatLogLine(new Date(2026, 10, 26, 9, 5, 7).getTime(), "supervisor: down");
    expect(line).toMatch(/^2026-11-26 09:05:07 supervisor: down$/);
    expect(humanMs(15_000)).toBe("15 s");
    expect(humanMs(60_000)).toBe("1 min");
    expect(humanMs(600_000)).toBe("10 min");
  });

  test("classifyDevice reads the device row and fleetHealthy wants it up", () => {
    expect(classifyDevice(deviceRow())).toBe("running");
    expect(classifyDevice(deviceRow("crashed"))).toBe("crashed");
    expect(classifyDevice([{ id: "ab12", cwd: "/x", name: "x", state: "running" }])).toBe("missing");
    expect(fleetHealthy(deviceRow())).toBe(true);
    expect(fleetHealthy(deviceRow("starting"))).toBe(true);
    expect(fleetHealthy(deviceRow("crashed"))).toBe(false);
    expect(fleetHealthy(null)).toBe(false);
  });

  test("transition lines name from and to, with the hint for the target", () => {
    expect(deviceTransitionLine(null, "running")).toBe("device daemon: running");
    expect(deviceTransitionLine("running", "crashed")).toBe(
      "device daemon: running → crashed (the supervisor restarts it with backoff — not the guard's job)",
    );
    expect(deviceTransitionLine("crashed", "stopped")).toMatch(/^device daemon: crashed → stopped .*the guard starts it/);
    expect(deviceTransitionLine("running", "missing")).toMatch(/registry entry may cover the home cwd/);
  });

  test("the constants keep the owner's bounds: at least every 60 s, bounded restarts", () => {
    expect(GUARD_INTERVAL_MS).toBeLessThanOrEqual(60_000);
    expect(SUPERVISOR_BACKOFF_MS[0]).toBe(0);
    expect(SUPERVISOR_BACKOFF_MS[SUPERVISOR_BACKOFF_MS.length - 1]).toBe(600_000);
    expect(WEDGE_MISSES).toBeGreaterThan(1);
    expect(DEVICE_RESTART_COOLDOWN_MS).toBeGreaterThanOrEqual(30_000);
    expect(DEVICE_RESTART_BUDGET).toBeLessThan(10);
  });
});

describe("appendGuardLog", () => {
  test("appends newline-terminated lines and trims an oversized file to its tail", () => {
    const file = join(tmp, "nested", "guard.log");
    appendGuardLog(file, "a");
    appendGuardLog(file, "b\n");
    expect(readFileSync(file, "utf8")).toBe("a\nb\n");
    writeFileSync(file, Array.from({ length: 5000 }, (_, i) => `line ${i} ${"x".repeat(300)}`).join("\n") + "\n");
    expect(statSync(file).size).toBeGreaterThan(1024 * 1024);
    appendGuardLog(file, "after");
    const kept = readFileSync(file, "utf8").trim().split("\n");
    // Exactly the newest 200 lines survive, newest last.
    expect(kept).toHaveLength(200);
    expect(kept[0]).toBe("line 4801 " + "x".repeat(300));
    expect(kept[198]).toBe("line 4999 " + "x".repeat(300));
    expect(kept[199]).toBe("after");
    expect(readFileSync(file, "utf8").endsWith("after\n")).toBe(true);
  });
});

describe("guardProcessAlive / acquireGuardLock", () => {
  test("a pid only counts as the guard when alive AND running `… guard run`", () => {
    const proc = join(tmp, "proc");
    const put = (pid: number, argv: string[]) => {
      mkdirSync(join(proc, String(pid)), { recursive: true });
      writeFileSync(join(proc, String(pid), "cmdline"), argv.join("\0") + "\0");
    };
    put(10, ["/bin/node", "/x/dist/index.js", "guard", "run"]);
    put(11, ["/bin/node", "/x/dist/index.js", "daemon", "status"]);
    put(12, ["/bin/node", "/x/dist/index.js", "guard", "status"]);
    expect(guardProcessAlive(10, proc)).toBe(true);
    expect(guardProcessAlive(11, proc)).toBe(false);
    expect(guardProcessAlive(12, proc)).toBe(false);
    expect(guardProcessAlive(99, proc)).toBe(false);
  });

  test("the lock is exclusive, survives a stale file, and is released by its owner only", () => {
    const pidFile = join(tmp, "piper", "guard.pid");
    const running = new Set([777]);
    const isGuardRunning = (pid: number) => running.has(pid);
    expect(acquireGuardLock(pidFile, 111, isGuardRunning)).toBe("acquired");
    // A live guard holds it.
    running.add(111);
    expect(acquireGuardLock(pidFile, 222, isGuardRunning)).toBe("already-running");
    // The guard died: the stale file (pid 111 no longer a guard) is replaced.
    running.delete(111);
    expect(acquireGuardLock(pidFile, 222, isGuardRunning)).toBe("acquired");
    expect(readFileSync(pidFile, "utf8")).toBe("222\n");
    // A foreign process reusing a dead guard's pid does not block either.
    writeFileSync(pidFile, "777\n");
    expect(acquireGuardLock(pidFile, 333, (pid) => pid === 111)).toBe("acquired");
    // Release removes the file only when it still names the releasing pid.
    writeFileSync(pidFile, "444\n");
    releaseGuardLock(pidFile, 333);
    expect(readFileSync(pidFile, "utf8")).toBe("444\n");
    releaseGuardLock(pidFile, 444);
    expect(() => readFileSync(pidFile)).toThrow();
  });
});

describe("probeStatus", () => {
  function isolated(): string {
    const id = randomUUID().slice(0, 8);
    return ipcAddress(`guard-test-${id}`, join(tmp, `${id}.sock`));
  }

  test("a real status round trip returns the fleet rows", async () => {
    const path = isolated();
    const server = createServer((socket) => {
      socket.setEncoding("utf8");
      socket.once("data", (line: string) => {
        expect(JSON.parse(line)).toEqual({ op: "status" });
        socket.end(JSON.stringify({ ok: true, data: { daemons: deviceRow() } }) + "\n");
      });
    });
    await new Promise<void>((r) => server.listen(path, r));
    try {
      expect(await probeStatus(path, 2_000)).toEqual(deviceRow());
    } finally {
      await new Promise<void>((r) => server.close(() => r()));
    }
  });

  test("nobody listening, a malformed reply and an error reply all mean 'not proven alive'", async () => {
    expect(await probeStatus(isolated(), 300)).toBeNull();
    const path = isolated();
    let mode = "malformed";
    const server = createServer((socket) => {
      socket.setEncoding("utf8");
      socket.once("data", () => socket.end(mode === "malformed" ? "not json\n" : JSON.stringify({ ok: false, error: "boom" }) + "\n"));
    });
    await new Promise<void>((r) => server.listen(path, r));
    try {
      expect(await probeStatus(path, 2_000)).toBeNull();
      mode = "error";
      expect(await probeStatus(path, 2_000)).toBeNull();
    } finally {
      await new Promise<void>((r) => server.close(() => r()));
    }
  });
});

describe("settleBeforeFirstTick", () => {
  test("waits through a booting supervisor without logging, and gives up after the grace", async () => {
    let probes = 0;
    const sleeps: number[] = [];
    const booting = { probe: async () => (++probes < 3 ? null : deviceRow()), sleep: async (ms: number) => { sleeps.push(ms); } };
    expect(await settleBeforeFirstTick(booting, 20_000, 5_000)).toBe(true);
    expect(probes).toBe(3);
    expect(sleeps).toEqual([5_000, 5_000]);

    const dead = { probe: async () => null, sleep: async (ms: number) => { sleeps.push(ms); } };
    expect(await settleBeforeFirstTick(dead, 20_000, 5_000)).toBe(false);
    expect(sleeps.slice(2)).toEqual([5_000, 5_000, 5_000, 5_000]);
  });
});

describe("tick — supervisor", () => {
  test("healthy from the start: one line per fact at first sight, then silence", async () => {
    const h = harness([deviceRow()]);
    const first = await tick(h.state, h.deps);
    expect(first.action).toEqual({ kind: "none" });
    expect(messages(h.out.lines)).toEqual([
      "supervisor: up (1 fleet row(s))",
      "device daemon: running",
    ]);
    h.advance(GUARD_INTERVAL_MS);
    const second = await tick(h.state, h.deps);
    expect(second.action).toEqual({ kind: "none" });
    expect(h.out.lines).toHaveLength(2);
    expect(h.out.starts).toHaveLength(0);
  });

  test("supervisor gone: announced once, restarted at once, then only on the backoff ladder", async () => {
    const h = harness([null]);
    const t0 = h.state;
    const a = await tick(t0, h.deps);
    expect(a.action).toEqual({ kind: "start-supervisor" });
    expect(messages(h.out.lines)).toEqual([
      `supervisor: down (no process, no reply on ${SOCK})`,
      "supervisor: start #1 (next attempt in 15 s if it does not answer)",
    ]);
    expect(h.out.starts).toHaveLength(1);

    // +30 s: the 15 s wait is over → start #2, now 30 s wait.
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "start-supervisor" });
    expect(messages(h.out.lines).at(-1)).toBe("supervisor: start #2 (next attempt in 30 s if it does not answer)");

    // +30 s: due again → start #3, now 1 min wait.
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "start-supervisor" });
    expect(messages(h.out.lines).at(-1)).toBe("supervisor: start #3 (next attempt in 1 min if it does not answer)");

    // +30 s: inside the 1 min wait → silent, nothing started.
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });
    expect(h.out.lines).toHaveLength(4);
    expect(h.out.starts).toHaveLength(3);

    // +30 s: due → start #4 (2 min). Five starts in the first two minutes.
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "start-supervisor" });
    expect(messages(h.out.lines).at(-1)).toContain("start #4 (next attempt in 2 min");

    // The ladder keeps growing up to the cap: one tick skipped, then due.
    for (const [advance, expected] of [
      [60_000, null],
      [60_000, "start #5 (next attempt in 5 min"],
      [300_000, "start #6 (next attempt in 10 min"],
      [300_000, null],
      [300_000, "start #7 (next attempt in 10 min"],
    ] as const) {
      h.advance(advance);
      const r = await tick(t0, h.deps);
      if (expected === null) {
        expect(r.action).toEqual({ kind: "none" });
      } else {
        expect(r.action).toEqual({ kind: "start-supervisor" });
        expect(messages(h.out.lines).at(-1)).toContain(expected);
      }
    }
    expect(h.out.starts).toHaveLength(7);

    // It answers again: one line with the outage length; the ladder is
    // forgiven after 10 stable minutes and the numbering starts over.
    h.next(deviceRow());
    h.advance(600_000);
    await tick(t0, h.deps);
    expect(messages(h.out.lines).at(-2)).toMatch(/^supervisor: back up after \d+ min \(1 fleet row\(s\)\)$/);
    expect(messages(h.out.lines).at(-1)).toBe("device daemon: running");
    expect(t0.starts).toBe(7);
    h.advance(10 * MIN);
    await tick(t0, h.deps);
    expect(t0.starts).toBe(0);
    expect(t0.nextStartAt).toBe(0);
    h.next(null);
    await tick(t0, h.deps);
    expect(messages(h.out.lines).at(-1)).toContain("start #1 (");
  });

  test("a present but silent supervisor is killed after WEDGE_MISSES probes, then restarted", async () => {
    const h = harness([null, null, null, null]);
    h.out.pids = [31337];
    h.out.alive.add(31337);
    const a = await tick(h.state, h.deps);
    expect(a.action).toEqual({ kind: "none" });
    expect(messages(h.out.lines)).toEqual([
      `supervisor: no reply (pid 31337 still present; restarted after ${WEDGE_MISSES} silent probes)`,
    ]);
    h.advance(GUARD_INTERVAL_MS);
    const b = await tick(h.state, h.deps);
    expect(b.action).toEqual({ kind: "none" });
    expect(h.out.lines).toHaveLength(1); // no transition, no action → no line
    expect(h.out.signals).toEqual([]);

    h.advance(GUARD_INTERVAL_MS);
    const c = await tick(h.state, h.deps);
    expect(c.action).toEqual({ kind: "start-supervisor" });
    expect(h.out.signals).toEqual([[31337, "SIGTERM"]]);
    expect(messages(h.out.lines).slice(1)).toEqual([
      "supervisor: pid 31337 alive but silent for 3 probes → kill",
      "supervisor: start #1 (next attempt in 15 s if it does not answer)",
    ]);
    expect(h.out.starts).toHaveLength(1);
  });

  test("a supervisor that ignores SIGTERM gets SIGKILL after the grace period", async () => {    const h = harness([null, null, null, null]);
    h.out.pids = [4];
    h.out.alive.add(4);
    const stubborn = { ...h.deps, signal: (pid: number, sig: string) => { h.out.signals.push([pid, sig]); return true; } };
    await tick(h.state, stubborn);
    await tick(h.state, stubborn);
    await tick(h.state, stubborn);
    expect(h.out.signals).toEqual([[4, "SIGTERM"], [4, "SIGKILL"]]);
    // 25 polls of 200 ms make the 5 s grace.
    expect(h.out.sleepMs.filter((ms) => ms === 200)).toHaveLength(25);
  });

  test("the replacement starts at once, even inside a long backoff", async () => {
    const h = harness([null]);
    const t0 = h.state;
    // An outage that already burned six starts: the next one would wait 10 min.
    t0.supervisor = "down";
    t0.downSince = h.deps.now() - 600_000;
    t0.starts = 6;
    t0.nextStartAt = h.deps.now() + 600_000;
    h.out.pids = [5];
    h.out.alive.add(5);
    await tick(t0, h.deps);
    await tick(t0, h.deps);
    const c = await tick(t0, h.deps);
    expect(h.out.signals).toEqual([[5, "SIGTERM"]]);
    expect(c.action).toEqual({ kind: "start-supervisor" });
    expect(messages(h.out.lines).at(-1)).toContain("start #7 (next attempt in 10 min");
  });

  test("a supervisor that was just started gets three fresh probes before it can be called wedged", async () => {
    const h = harness([null]);
    const t0 = h.state;
    h.out.pids = [7];
    h.out.alive.add(7);
    await tick(t0, h.deps);
    h.advance(30_000);
    await tick(t0, h.deps);
    h.advance(30_000);
    const c = await tick(t0, h.deps);
    expect(c.action).toEqual({ kind: "start-supervisor" });
    expect(t0.misses).toBe(0);

    // Its replacement is alive but still booting: two silent probes spare it.
    h.out.pids = [8];
    h.out.alive.add(8);
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });
    expect(h.out.signals).toEqual([[7, "SIGTERM"]]);
    expect(h.out.starts).toHaveLength(1);
    // The third silent probe does kill it, and starts the next one.
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "start-supervisor" });
    expect(h.out.signals).toEqual([[7, "SIGTERM"], [8, "SIGTERM"]]);
  });

  test("a supervisor that cannot be started is said so once, not on every retry", async () => {
    const h = harness([null]);
    h.out.startOk = false;
    const a = await tick(h.state, h.deps);
    expect(a.action).toEqual({ kind: "none" });
    expect(messages(h.out.lines)[1]).toMatch(/^supervisor: could not start \(script or node missing — reinstall remote-pi\); retrying in 15 s$/);
    h.advance(60_000);
    await tick(h.state, h.deps);
    expect(h.out.lines).toHaveLength(2);
    expect(h.out.starts).toHaveLength(2);
  });
});

describe("tick — device daemon", () => {
  test("crashed and starting are logged on transition only; the supervisor owns the restart", async () => {
    const h = harness([deviceRow("crashed"), deviceRow("starting"), deviceRow(), deviceRow()]);
    const a = await tick(h.state, h.deps);
    expect(a.action).toEqual({ kind: "none" });
    expect(messages(h.out.lines)[1]).toMatch(/^device daemon: crashed \(/);
    await tick(h.state, h.deps);
    await tick(h.state, h.deps);
    await tick(h.state, h.deps);
    expect(messages(h.out.lines).slice(1)).toEqual([
      "device daemon: crashed (the supervisor restarts it with backoff — not the guard's job)",
      "device daemon: crashed → starting",
      "device daemon: starting → running",
    ]);
    expect(h.out.deviceStarts).toHaveLength(0);
  });

  test("a missing row gets the home-cwd hint once", async () => {
    const h = harness([[]]);
    await tick(h.state, h.deps);
    await tick(h.state, h.deps);
    expect(messages(h.out.lines)).toEqual([
      "supervisor: up (0 fleet row(s))",
      "device daemon: no fleet row — a registry entry may cover the home cwd (remote-pi doctor)",
    ]);
  });

  test("stopped: the guard asks for a start, at most once per minute and three per ten", async () => {
    const h = harness([deviceRow("stopped"), deviceRow("stopped"), deviceRow("stopped")]);
    const t0 = h.state;
    const a = await tick(t0, h.deps);
    expect(a.action).toEqual({ kind: "restart-device" });
    expect(messages(h.out.lines)[1]).toBe("device daemon: stopped (no restart is scheduled — the guard starts it)");
    expect(messages(h.out.lines)[2]).toBe("device daemon: stopped → start requested");
    expect(h.out.deviceStarts).toHaveLength(1);

    // Still stopped 30 s later: inside the cooldown → nothing.
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });
    expect(h.out.deviceStarts).toHaveLength(1);
    expect(h.out.lines).toHaveLength(3);

    // 60 s after the first request: second one.
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "restart-device" });
    expect(h.out.deviceStarts).toHaveLength(2);
    h.advance(DEVICE_RESTART_COOLDOWN_MS);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "restart-device" });
    expect(h.out.deviceStarts).toHaveLength(3);

    // Budget exhausted: said once, then silence until the daemon runs again.
    h.advance(DEVICE_RESTART_COOLDOWN_MS);
    const d = await tick(t0, h.deps);
    expect(d.action).toEqual({ kind: "none" });
    expect(messages(h.out.lines).at(-1)).toBe(
      `device daemon: 3 starts in 10 min did not keep it up — leaving it alone (remote-pi doctor)`,
    );
    h.advance(DEVICE_RESTART_COOLDOWN_MS);
    await tick(t0, h.deps);
    expect(h.out.deviceStarts).toHaveLength(3);
    expect(messages(h.out.lines).at(-1)).toContain("leaving it alone");

    // It runs once more (someone fixed it) → the budget line is re-armed, so
    // the next exhaustion is announced again instead of staying silent.
    h.next(deviceRow(), deviceRow("stopped"));
    await tick(t0, h.deps);
    await tick(t0, h.deps);
    expect(messages(h.out.lines).slice(-3)).toEqual([
      "device daemon: stopped → running",
      "device daemon: running → stopped (no restart is scheduled — the guard starts it)",
      "device daemon: 3 starts in 10 min did not keep it up — leaving it alone (remote-pi doctor)",
    ]);
  });

  test("a start refused by the supervisor is reported as such", async () => {
    const h = harness([deviceRow("stopped")]);
    h.out.deviceStartOk = false;
    const a = await tick(h.state, h.deps);
    expect(a.action).toEqual({ kind: "restart-device" });
    expect(messages(h.out.lines)[2]).toBe("device daemon: stopped → start refused by the supervisor");
  });
});

describe("guardStart / guardStatus / guardStop", () => {
  test("start: already running → no spawn; otherwise spawn detached and wait for the lock", async () => {
    let spawns = 0;
    const calls: Array<{ cmd: string; args: string[]; detached: boolean }> = [];
    const fakeSpawn = ((cmd: string, args: string[], options: { detached: boolean }) => {
      spawns += 1;
      calls.push({ cmd, args, detached: options.detached });
      return { unref: () => undefined };
    }) as never;
    let running: number | null = 55;
    const already = await guardStart({
      spawnFn: fakeSpawn,
      sleep: async () => undefined,
      runningPid: () => running,
      logPath: join(tmp, "guard.log"),
    });
    expect(already).toEqual({ ok: true, message: "guard already running (pid 55)" });
    expect(spawns).toBe(0);

    running = null;
    let checks = 0;
    const started = await guardStart({
      spawnFn: fakeSpawn,
      sleep: async () => undefined,
      runningPid: () => (++checks < 3 ? null : 56),
      logPath: join(tmp, "nested", "guard.log"),
    });
    expect(started).toEqual({ ok: true, message: "guard started (pid 56)" });
    expect(spawns).toBe(1);
    expect(calls[0]).toMatchObject({ args: [expect.stringMatching(/index\.js$/), "guard", "run"], detached: true });

    checks = -100;
    const failed = await guardStart({ spawnFn: fakeSpawn, sleep: async () => undefined, runningPid: () => null, logPath: join(tmp, "guard.log") });
    expect(failed.ok).toBe(false);
    expect(failed.message).toContain("did not take its lock");
  });

  test("status: three lines in the log's vocabulary", async () => {
    const lines = await guardStatus({ runningPid: () => 9, probe: async () => deviceRow("crashed"), sockPath: SOCK });
    expect(lines[0]).toMatch(/^guard:\s+running \(pid 9\) — .*guard\.log$/);
    expect(lines[1]).toBe("supervisor: up (1 fleet row(s))");
    expect(lines[2]).toMatch(/^device:\s+crashed \(/);
    const down = await guardStatus({ runningPid: () => null, probe: async () => null, sockPath: SOCK });
    expect(down).toEqual([
      expect.stringMatching(/^guard:\s+not running/),
      `supervisor: no reply on ${SOCK}`,
      "device:     unknown (supervisor silent)",
    ]);
  });

  test("stop: SIGTERM the running guard, escalate to SIGKILL when it lingers", async () => {
    const signalled: Array<[number, string]> = [];
    let alive = true;
    let polls = 0;
    const stopped = await guardStop({
      runningPid: () => (alive ? 77 : null),
      signal: (pid, sig) => { signalled.push([pid, sig]); return true; },
      isAlive: () => alive,
      // Lingers through the whole SIGTERM grace (40 polls), dies on SIGKILL.
      sleep: async () => { polls += 1; alive = !(signalled.length > 1 && polls > 41); },
    });
    expect(stopped).toEqual({ ok: true, message: "guard stopped (pid 77)" });
    expect(signalled).toEqual([[77, "SIGTERM"], [77, "SIGKILL"]]);
    expect(await guardStop({ runningPid: () => null, signal: () => true, isAlive: () => false, sleep: async () => undefined }))
      .toEqual({ ok: true, message: "guard is not running" });
  });
});

describe("runGuardCli", () => {
  test("no or unknown subcommand prints the usage and exits 1", async () => {
    const errs: string[] = [];
    const out: string[] = [];
    expect(await runGuardCli(["node", "index.js", "guard"], { out: (l) => out.push(l), err: (l) => errs.push(l) })).toBe(1);
    expect(await runGuardCli(["node", "index.js", "guard", "wat"], { out: (l) => out.push(l), err: (l) => errs.push(l) })).toBe(1);
    expect(errs).toHaveLength(2);
    expect(errs[0]).toContain("Usage: remote-pi guard <run|start|status|stop|once>");
    expect(out).toHaveLength(0);
  });

  test("run and start refuse outside Termux (a PC has a service manager)", async ({ skip }) => {
    // On a Termux host these really run; the refusal is the behaviour under test.
    if (process.env["TERMUX_VERSION"]) skip();
    const errs: string[] = [];
    expect(await runGuardCli(["node", "index.js", "guard", "run"], { out: () => undefined, err: (l) => errs.push(l) })).toBe(1);
    expect(await runGuardCli(["node", "index.js", "guard", "start"], { out: () => undefined, err: (l) => errs.push(l) })).toBe(1);
    expect(errs).toHaveLength(2);
    expect(errs[0]).toContain("belongs on a Termux (Android) host");
    expect(errs[1]).toContain("service manager");
  });
});
