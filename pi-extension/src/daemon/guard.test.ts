/**
 * Plan/173 — the Termux guard's state machine, driven with a fake clock and
 * recorded side effects: no processes are signalled, no supervisor started,
 * no socket opened except in the one probe test (an isolated pipe / socket,
 * the same way supervisor.test.ts isolates its own).
 *
 * Owner decision of 2026-11-26 under test: check every 30 s, restart after
 * TWO failed checks, one graceful restart after 24 h of uptime, with a
 * restart-rate limit — every number a setting, the environment winning over
 * guard.conf.
 */
import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import {
  DEFAULT_GUARD_CONFIG,
  acquireGuardLock,
  appendGuardLog,
  classifyDevice,
  createGuardState,
  describeGuardConfig,
  deviceTransitionLine,
  fileMarker,
  fleetHealthy,
  formatLogLine,
  guardStart,
  guardProcessAlive,
  guardStatus,
  guardStop,
  humanMs,
  loadGuardConfig,
  parseConf,
  probeStatus,
  releaseGuardLock,
  retireInterimGuard,
  runGuardCli,
  runGuardLoop,
  settleBeforeFirstTick,
  startAllowedAt,
  tick,
  timeOfDay,
  type GuardConfig,
  type GuardDeps,
  type GuardState,
} from "./guard.js";
import type { DaemonInfo } from "./control_protocol.js";
import { ipcAddress } from "../session/ipc.js";

const SOCK = "/data/data/com.termux/files/home/.pi/piper/supervisor.sock";
const MIN = 60_000;
const HOUR = 60 * MIN;

function deviceRow(state: DaemonInfo["state"] = "running"): DaemonInfo[] {
  return [{ id: "device", cwd: "/home", name: "device", state }];
}

function config(overrides: Partial<GuardConfig> = {}): GuardConfig {
  return { ...DEFAULT_GUARD_CONFIG, startBackoffMs: [...DEFAULT_GUARD_CONFIG.startBackoffMs], ...overrides };
}

/** Fake clock + recorded effects. `rows` is the probe script: values are
 *  consumed one per probe, the last one repeats. */
function harness(rows: Array<DaemonInfo[] | null>, cfg: GuardConfig = config()) {
  let now = 1_700_000_000_000;
  const out = {
    lines: [] as string[],
    starts: [] as number[],
    signals: [] as Array<[number, string]>,
    probes: 0,
    pids: [] as number[],
    alive: new Set<number>(),
    startOk: true,
    deviceStarts: [] as number[],
    deviceStartOk: true,
    sleepMs: [] as number[],
    ages: new Map<number, number>(),
    marker: [] as string[],
    /** Pids that ignore SIGTERM/SIGINT (the SIGSTOP shape of 2026-11-22). */
    frozen: new Set<number>(),
  };
  const script = [...rows];
  const deps: GuardDeps = {
    config: cfg,
    now: () => now,
    probe: async () => {
      out.probes += 1;
      return script.length > 1 ? script.shift()! : script[0]!;
    },
    supervisorPids: () => out.pids,
    processAge: (pid) => out.ages.get(pid) ?? null,
    isAlive: (pid) => out.alive.has(pid),
    signal: (pid, sig) => {
      out.signals.push([pid, sig]);
      // A healthy supervisor honours SIGINT/SIGTERM; a frozen one ignores it.
      if ((sig === "SIGTERM" || sig === "SIGINT") && !out.frozen?.has(pid)) out.alive.delete(pid);
      if (sig === "SIGKILL") out.alive.delete(pid);
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
    marker: {
      set: (text) => out.marker.push(`set:${text}`),
      clear: () => out.marker.push("clear"),
    },
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
const markerEvents = (out: { marker: string[] }): string[] => out.marker.map((m) => m.split(":")[0]!);

let tmp: string;

beforeEach(() => {
  tmp = mkdtempSync(join(tmpdir(), "pi-guard-"));
  process.env["REMOTE_PI_HOME"] = tmp;
});

afterEach(() => {
  delete process.env["REMOTE_PI_HOME"];
  rmSync(tmp, { recursive: true, force: true });
});

describe("pure helpers", () => {
  test("formatLogLine is the watchdog's local-time layout; timeOfDay is HH:MM", () => {
    const at = new Date(2026, 10, 26, 9, 5, 7).getTime();
    expect(formatLogLine(at, "supervisor: down")).toMatch(/^2026-11-26 09:05:07 supervisor: down$/);
    expect(timeOfDay(at)).toBe("09:05");
  });

  test("humanMs reads naturally up to days of uptime", () => {
    expect(humanMs(15_000)).toBe("15 s");
    expect(humanMs(60_000)).toBe("1 min");
    expect(humanMs(600_000)).toBe("10 min");
    expect(humanMs(24 * HOUR)).toBe("24 h");
    expect(humanMs(24 * HOUR + 90 * MIN)).toBe("25 h 30 min");
  });

  test("describeGuardConfig names every setting with the owner's defaults", () => {
    expect(describeGuardConfig(config())).toBe(
      "check every 30 s; restart after 2 silent probes; age restart above 24 h; at most 3 start(s) per 10 min; "
      + "start backoff 15 s, 30 s, 1 min, 2 min, 5 min, 10 min; stop grace 10 s",
    );
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

  test("the owner's bounds are the defaults: every 60 s at most, two fails, 24 h, rate-limited", () => {
    expect(DEFAULT_GUARD_CONFIG.intervalMs).toBeLessThanOrEqual(60_000);
    expect(DEFAULT_GUARD_CONFIG.failsBeforeRestart).toBe(2);
    expect(DEFAULT_GUARD_CONFIG.maxAgeMs).toBe(24 * HOUR);
    expect(DEFAULT_GUARD_CONFIG.rateMax).toBeGreaterThan(0);
    expect(DEFAULT_GUARD_CONFIG.rateWindowMs).toBeGreaterThan(0);
  });
});

describe("configuration", () => {
  test("parseConf reads what a shell would source: KEY=VALUE, export, quotes, comments", () => {
    expect(parseConf("# comment\nINTERVAL_S=30\nexport FAILS_BEFORE_RESTART=\"2\"\n  MAX_AGE_S='86400' \nSTART_BACKOFF_S=\"15,30\"\nnot a setting\n")).toEqual({
      INTERVAL_S: "30",
      FAILS_BEFORE_RESTART: "2",
      MAX_AGE_S: "86400",
      START_BACKOFF_S: "15,30",
    });
  });

  test("defaults, then guard.conf, then the environment — the environment wins", () => {
    const loaded = loadGuardConfig(
      { REMOTE_PI_GUARD_INTERVAL_S: "20", REMOTE_PI_GUARD_MAX_AGE_S: "0" },
      "INTERVAL_S=45\nFAILS_BEFORE_RESTART=4\nMAX_AGE_S=7200\nRESTART_RATE_MAX=5\nRESTART_RATE_WINDOW_S=120\nSTART_BACKOFF_S=5,10\nSTOP_GRACE_S=3\n",
    );
    expect(loaded.config).toEqual({
      intervalMs: 20_000,          // env beats the file's 45
      failsBeforeRestart: 4,       // file
      maxAgeMs: 0,                 // env: off
      rateMax: 5,
      rateWindowMs: 120_000,
      startBackoffMs: [5_000, 10_000],
      stopGraceMs: 3_000,
    });
    expect(loaded.sources).toEqual(["guard.conf", "env:REMOTE_PI_GUARD_INTERVAL_S", "env:REMOTE_PI_GUARD_MAX_AGE_S"]);
    expect(loaded.ignored).toEqual([]);
  });

  test("unknown names and unusable values are ignored AND reported, never silently dropped", () => {
    const loaded = loadGuardConfig(
      { REMOTE_PI_GUARD_FAILS_BEFORE_RESTART: "two", REMOTE_PI_GUARD_WAT: "1" },
      "INTERVAL_S=0\nSOMETHING_ELSE=1\nRESTART_RATE_WINDOW_S=0\n",
    );
    expect(loaded.config).toEqual(config());
    expect(loaded.ignored).toEqual([
      "guard.conf: INTERVAL_S (unknown setting or bad value)",
      "guard.conf: SOMETHING_ELSE (unknown setting or bad value)",
      "guard.conf: RESTART_RATE_WINDOW_S (unknown setting or bad value)",
      "REMOTE_PI_GUARD_FAILS_BEFORE_RESTART (unknown setting or bad value)",
      "REMOTE_PI_GUARD_WAT (unknown setting or bad value)",
    ]);
  });

  test("a missing guard.conf and no env leave the defaults, with no sources", () => {
    expect(loadGuardConfig({}, null)).toEqual({ config: config(), sources: [], ignored: [] });
  });
});

describe("appendGuardLog", () => {
  test("appends newline-terminated lines and trims an oversized file to its tail", () => {
    const file = join(tmp, "nested", "guard.log");
    appendGuardLog(file, "a");
    appendGuardLog(file, "b\n");
    expect(readFileSync(file, "utf8")).toBe("a\nb\n");
    writeFileSync(file, Array.from({ length: 5000 }, (_, i) => `line ${i} ${"x".repeat(300)}`).join("\n") + "\n");
    expect(readFileSync(file).length).toBeGreaterThan(1024 * 1024);
    appendGuardLog(file, "after");
    const kept = readFileSync(file, "utf8").trim().split("\n");
    // Exactly the newest 200 lines survive, newest last.
    expect(kept).toHaveLength(200);
    expect(kept[0]).toBe("line 4801 " + "x".repeat(300));
    expect(kept[198]).toBe("line 4999 " + "x".repeat(300));
    expect(kept[199]).toBe("after");
  });
});

describe("startAllowedAt", () => {
  test("the backoff and the rate window combine; any values stay sound", () => {
    const state = createGuardState();
    // Nothing started yet: allowed now.
    expect(startAllowedAt(state, config())).toBe(0);
    // Window full: the oldest of the last `rateMax` starts must leave it.
    state.startTimes = [0, 10_000, 20_000];
    state.nextStartAt = 15_000;
    expect(startAllowedAt(state, config())).toBe(600_000);
    // A backoff LONGER than the window simply wins.
    state.nextStartAt = 7_000_000;
    expect(startAllowedAt(state, config())).toBe(7_000_000);
    // rateMax 0 disables the limiter.
    expect(startAllowedAt({ ...state, nextStartAt: 15_000 }, config({ rateMax: 0 }))).toBe(15_000);
  });
});

describe("guardProcessAlive / acquireGuardLock", () => {
  test("a pid only counts as the guard when alive AND running `node … guard run`", () => {
    const proc = join(tmp, "proc");
    const put = (pid: number, argv: string[]) => {
      mkdirSync(join(proc, String(pid)), { recursive: true });
      writeFileSync(join(proc, String(pid), "cmdline"), argv.join("\0") + "\0");
    };
    put(10, ["/bin/node", "/x/dist/index.js", "guard", "run"]);
    put(11, ["/bin/node", "/x/dist/index.js", "daemon", "status"]);
    put(12, ["/bin/node", "/x/dist/index.js", "guard", "status"]);
    put(13, ["/bin/bash", "/home/u/.pi/piper/piper-guard.sh"]);
    for (const pid of [10, 11, 12, 13]) expect(guardProcessAlive(pid, proc)).toBe(pid === 10);
  });

  test("the lock is exclusive, survives a stale file, and is released by its owner only", () => {
    const pidFile = join(tmp, "piper", "guard.pid");
    const running = new Set([777]);
    const isGuardRunning = (pid: number) => running.has(pid);
    expect(acquireGuardLock(pidFile, 111, isGuardRunning)).toBe("acquired");
    running.add(111);
    expect(acquireGuardLock(pidFile, 222, isGuardRunning)).toBe("already-running");
    // The guard died: the stale file is replaced.
    running.delete(111);
    expect(acquireGuardLock(pidFile, 222, isGuardRunning)).toBe("acquired");
    expect(readFileSync(pidFile, "utf8")).toBe("222\n");
    // A foreign process reusing a dead guard's pid does not block either.
    writeFileSync(pidFile, "777\n");
    expect(acquireGuardLock(pidFile, 333, (pid) => pid === 111)).toBe("acquired");
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

describe("tick — supervisor gone", () => {
  test("healthy from the start: one line per fact at first sight, then silence", async () => {
    const h = harness([deviceRow()]);
    expect((await tick(h.state, h.deps)).action).toEqual({ kind: "none" });
    expect(messages(h.out.lines)).toEqual([
      "supervisor: up (1 fleet row(s))",
      "device daemon: running",
    ]);
    h.advance(30_000);
    expect((await tick(h.state, h.deps)).action).toEqual({ kind: "none" });
    expect(h.out.lines).toHaveLength(2);
    expect(h.out.starts).toHaveLength(0);
    expect(h.out.marker).toEqual([]);
  });

  test("gone: announced once, started at once, then backoff AND the rate limit apply", async () => {
    const h = harness([null]);
    const t0 = h.state;
    const a = await tick(t0, h.deps);
    expect(a.action).toEqual({ kind: "start-supervisor" });
    expect(messages(h.out.lines)).toEqual([
      `supervisor: down (no process, no reply on ${SOCK})`,
      "supervisor: start #1 (next attempt in 15 s if it does not answer)",
    ]);
    expect(h.out.starts).toHaveLength(1);
    // Every start is a marked stop-and-start sequence.
    expect(markerEvents(h.out)).toEqual(["set", "clear"]);

    // +30 s: the 15 s wait is over → start #2, now 30 s wait.
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "start-supervisor" });
    expect(messages(h.out.lines).at(-1)).toBe("supervisor: start #2 (next attempt in 30 s if it does not answer)");
    // +30 s: due → start #3. Three starts inside the 10 min window: the limit.
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "start-supervisor" });
    expect(messages(h.out.lines).at(-1)).toBe("supervisor: start #3 (next attempt in 1 min if it does not answer)");

    // +30 s (t = 90 s): backoff would allow at 150 s, the window only at 600 s → wait, said once.
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });
    expect(messages(h.out.lines).at(-1)).toBe(
      `supervisor: restart postponed by the start limit (3 per 10 min) until ${timeOfDay(h.deps.now() + 600_000 - 90_000)}`,
    );
    const linesBefore = h.out.lines.length;
    for (let t = 120_000; t < 600_000; t += 30_000) {
      h.advance(30_000);
      expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });
    }
    expect(h.out.lines).toHaveLength(linesBefore); // silent while it waits
    expect(h.out.starts).toHaveLength(3);

    // t = 600 s: the first start left the window → start #4.
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "start-supervisor" });
    expect(h.out.starts).toHaveLength(4);
    expect(messages(h.out.lines).at(-1)).toBe("supervisor: start #4 (next attempt in 2 min if it does not answer)");
  });

  test("without a rate limit the backoff ladder alone paces the starts", async () => {
    const h = harness([null], config({ rateMax: 0 }));
    const t0 = h.state;
    await tick(t0, h.deps);                       // #1 → wait 15 s
    h.advance(30_000); await tick(t0, h.deps);    // #2 → wait 30 s
    h.advance(30_000); await tick(t0, h.deps);    // #3 → wait 1 min
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });  // t = 90 s < 150 s
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "start-supervisor" }); // #4 at 120 s → wait 2 min
    h.advance(120_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "start-supervisor" }); // #5 → 5 min
    expect(messages(h.out.lines).at(-1)).toBe("supervisor: start #5 (next attempt in 5 min if it does not answer)");
    expect(h.out.lines.filter((l) => l.includes("postponed"))).toHaveLength(0);
  });

  test("a failing start is said so once, not on every retry", async () => {
    const h = harness([null]);
    h.out.startOk = false;
    expect((await tick(h.state, h.deps)).action).toEqual({ kind: "none" });
    expect(messages(h.out.lines)[1]).toMatch(/^supervisor: could not start \(script or node missing — reinstall remote-pi\); retrying in 15 s$/);
    h.advance(60_000);
    await tick(h.state, h.deps);
    expect(h.out.lines).toHaveLength(2);
    expect(h.out.starts).toHaveLength(2);
  });

  test("back up: one line with the outage length; the ladder is forgiven after 10 stable minutes", async () => {
    const h = harness([null]);
    const t0 = h.state;
    await tick(t0, h.deps);
    h.next(deviceRow());
    h.advance(2 * MIN);
    await tick(t0, h.deps);
    expect(messages(h.out.lines).slice(-2)).toEqual([
      "supervisor: back up after 2 min (1 fleet row(s))",
      "device daemon: running",
    ]);
    expect(t0.backoffIndex).toBe(1);
    h.advance(10 * MIN);
    await tick(t0, h.deps);
    expect(t0.backoffIndex).toBe(0);
    expect(t0.nextStartAt).toBe(0);
    h.next(null);
    await tick(t0, h.deps);
    expect(messages(h.out.lines).at(-1)).toContain("start #1 (");
  });
});

describe("tick — supervisor wedged (alive, silent)", () => {
  test("TWO silent probes (the owner's number), then kill + restart; the first probe only reports", async () => {
    const h = harness([null]);
    h.out.pids = [31337];
    h.out.alive.add(31337);
    expect((await tick(h.state, h.deps)).action).toEqual({ kind: "none" });
    expect(messages(h.out.lines)).toEqual([
      "supervisor: no reply (pid 31337 still present; restarted after 2 silent probes)",
    ]);
    expect(h.out.signals).toEqual([]);
    h.advance(30_000);
    const b = await tick(h.state, h.deps);
    expect(b.action).toEqual({ kind: "start-supervisor" });
    expect(h.out.signals).toEqual([[31337, "SIGTERM"]]);
    expect(messages(h.out.lines).slice(1)).toEqual([
      "supervisor: pid 31337 alive but silent for 2 probes → kill",
      "supervisor: start #1 (next attempt in 15 s if it does not answer)",
    ]);
    expect(h.state.misses).toBe(0);
  });

  test("FAILS_BEFORE_RESTART is a setting: with 3 the kill waits for the third probe", async () => {
    const h = harness([null, null, null, null], config({ failsBeforeRestart: 3 }));
    h.out.pids = [5];
    h.out.alive.add(5);
    expect((await tick(h.state, h.deps)).action).toEqual({ kind: "none" });
    h.advance(30_000);
    expect((await tick(h.state, h.deps)).action).toEqual({ kind: "none" });
    expect(h.out.signals).toEqual([]);
    h.advance(30_000);
    expect((await tick(h.state, h.deps)).action).toEqual({ kind: "start-supervisor" });
    expect(h.out.signals).toEqual([[5, "SIGTERM"]]);
  });

  test("a supervisor that ignores SIGTERM gets SIGKILL after the stop grace", async () => {
    const h = harness([null, null, null]);
    h.out.pids = [4];
    h.out.alive.add(4);
    h.out.frozen.add(4);
    await tick(h.state, h.deps);
    await tick(h.state, h.deps);
    expect(h.out.signals).toEqual([[4, "SIGTERM"], [4, "SIGKILL"]]);
    // 50 polls of 200 ms make the 10 s grace.
    expect(h.out.sleepMs.filter((ms) => ms === 200)).toHaveLength(50);
  });

  test("nothing is killed before the start limit allows the replacement", async () => {
    const h = harness([null]);
    const t0 = h.state;
    t0.supervisor = "down";
    t0.startTimes = [h.deps.now() - 30_000, h.deps.now() - 20_000, h.deps.now() - 10_000];
    t0.backoffIndex = 3;
    t0.nextStartAt = 0;
    h.out.pids = [5];
    h.out.alive.add(5);
    t0.misses = 1;
    await tick(t0, h.deps);   // miss 2: wedged, but the limit is exhausted
    expect(h.out.signals).toEqual([]);
    expect(h.out.starts).toEqual([]);
    expect(messages(h.out.lines).at(-1)).toMatch(/^supervisor: restart postponed by the start limit \(3 per 10 min\) until /);
    // Silent on the next tick, still nothing killed.
    h.advance(30_000);
    await tick(t0, h.deps);
    expect(h.out.signals).toEqual([]);
    expect(h.out.lines.filter((l) => l.includes("postponed"))).toHaveLength(1);
  });

  test("the replacement gets its own silent probes before it can be called wedged", async () => {
    const h = harness([null]);
    const t0 = h.state;
    h.out.pids = [7];
    h.out.alive.add(7);
    await tick(t0, h.deps);
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "start-supervisor" });
    expect(t0.misses).toBe(0);
    // Its replacement is alive but still booting: one silent probe spares it,
    // the second (two fails) does not.
    h.out.pids = [8];
    h.out.alive.add(8);
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });
    expect(h.out.signals).toEqual([[7, "SIGTERM"]]);
    expect(h.out.starts).toHaveLength(1);
  });
});

describe("tick — age restart", () => {
  test("a supervisor older than MAX_AGE gets ONE graceful restart: SIGINT, grace, SIGKILL, start", async () => {
    const h = harness([deviceRow()], config({ maxAgeMs: 5_000 }));   // tiny override for the test
    const t0 = h.state;
    h.out.pids = [21];
    h.out.alive.add(21);
    h.out.ages.set(21, 6_000);
    const a = await tick(t0, h.deps);
    expect(a.action).toEqual({ kind: "age-restart" });
    expect(messages(h.out.lines).slice(-1)).toEqual(["supervisor: age restart (uptime 6 s, limit 5 s)"]);
    expect(h.out.signals).toEqual([[21, "SIGINT"]]);
    expect(h.out.starts).toHaveLength(1);
    expect(markerEvents(h.out)).toEqual(["set", "clear"]);
    // The restart counts like any other start: backoff + rate window.
    expect(t0.nextStartAt).toBe(h.deps.now() + 15_000);
    expect(t0.startTimes).toHaveLength(1);
    expect(t0.ageRestarted).toEqual([21]);

    // Its replacement is young: no second restart, no line.
    h.out.pids = [22];
    h.out.alive.add(22);
    h.out.ages.set(22, 1_000);
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });
    expect(h.out.starts).toHaveLength(1);
  });

  test("with the default 24 h and a 25 h process the restart happens; with 23 h it does not", async () => {
    const old = harness([deviceRow()]);
    old.out.pids = [1];
    old.out.ages.set(1, 25 * HOUR);
    expect((await tick(old.state, old.deps)).action).toEqual({ kind: "age-restart" });
    expect(messages(old.out.lines).at(-1)).toBe("supervisor: age restart (uptime 25 h, limit 24 h)");

    const young = harness([deviceRow()]);
    young.out.pids = [2];
    young.out.ages.set(2, 23 * HOUR);
    expect((await tick(young.state, young.deps)).action).toEqual({ kind: "none" });
    expect(young.out.lines.some((l) => l.includes("age restart"))).toBe(false);
  });

  test("a frozen old supervisor: SIGINT is ignored, SIGKILL follows after the grace, then the start", async () => {
    const h = harness([deviceRow()], config({ maxAgeMs: 5_000, stopGraceMs: 2_000 }));
    h.out.pids = [9];
    h.out.alive.add(9);
    h.out.frozen.add(9);
    h.out.ages.set(9, 60_000);
    expect((await tick(h.state, h.deps)).action).toEqual({ kind: "age-restart" });
    expect(h.out.signals).toEqual([[9, "SIGINT"], [9, "SIGKILL"]]);
    expect(h.out.starts).toHaveLength(1);
  });

  test("MAX_AGE_S = 0 turns the age restart off", async () => {
    const h = harness([deviceRow()], config({ maxAgeMs: 0 }));
    h.out.pids = [3];
    h.out.ages.set(3, 100 * HOUR);
    expect((await tick(h.state, h.deps)).action).toEqual({ kind: "none" });
    expect(h.out.signals).toEqual([]);
  });

  test("the age restart waits for the start limit like any other start, said once", async () => {
    const h = harness([deviceRow()], config({ maxAgeMs: 5_000 }));
    const t0 = h.state;
    t0.startTimes = [h.deps.now() - 1000, h.deps.now() - 500, h.deps.now() - 100];
    h.out.pids = [4];
    h.out.ages.set(4, 60_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });
    expect(h.out.signals).toEqual([]);
    expect(messages(h.out.lines).at(-1)).toMatch(/^supervisor: age restart \(uptime 1 min\) postponed by the start limit until /);
    h.advance(30_000);
    await tick(t0, h.deps);
    expect(h.out.lines.filter((l) => l.includes("postponed"))).toHaveLength(1);
  });

  test("without a readable process age the observed uptime is used, and the restart cannot loop", async () => {
    const h = harness([deviceRow()], config({ maxAgeMs: 5 * MIN }));
    const t0 = h.state;
    h.out.pids = [6];
    // First observation at t0: age 0 → nothing.
    await tick(t0, h.deps);
    expect(h.out.starts).toHaveLength(0);
    // Six minutes later the OBSERVED uptime (process age unknown) exceeds the limit.
    h.advance(6 * MIN);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "age-restart" });
    expect(messages(h.out.lines).at(-1)).toBe("supervisor: age restart (uptime 6 min, limit 5 min)");
    // The graceful stop did not work (pid 6 still there, age unknown): the
    // same incarnation is never age-restarted twice.
    h.out.alive.add(6);
    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });
    expect(h.out.starts).toHaveLength(1);
  });
});

describe("tick — device daemon", () => {
  test("crashed and starting are logged on transition only; the supervisor owns the restart", async () => {
    const h = harness([deviceRow("crashed"), deviceRow("starting"), deviceRow(), deviceRow()]);
    expect((await tick(h.state, h.deps)).action).toEqual({ kind: "none" });
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

    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });
    expect(h.out.deviceStarts).toHaveLength(1);
    expect(h.out.lines).toHaveLength(3);

    h.advance(30_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "restart-device" });
    expect(h.out.deviceStarts).toHaveLength(2);
    h.advance(60_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "restart-device" });
    expect(h.out.deviceStarts).toHaveLength(3);

    h.advance(60_000);
    expect((await tick(t0, h.deps)).action).toEqual({ kind: "none" });
    expect(messages(h.out.lines).at(-1)).toBe(
      "device daemon: 3 starts in 10 min did not keep it up — leaving it alone (remote-pi doctor)",
    );
    h.advance(60_000);
    await tick(t0, h.deps);
    expect(h.out.deviceStarts).toHaveLength(3);

    // It runs once more (someone fixed it) → the budget line is re-armed.
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
    expect((await tick(h.state, h.deps)).action).toEqual({ kind: "restart-device" });
    expect(messages(h.out.lines)[2]).toBe("device daemon: stopped → start refused by the supervisor");
  });
});

describe("retireInterimGuard", () => {
  function retireDeps(opts: { pid: number | null; interim: boolean; alive: boolean; scriptExists: boolean; ignoreTerm?: boolean }) {
    const calls: string[] = [];
    let alive = opts.alive;
    let renamed = false;
    const deps = {
      pidFilePid: () => opts.pid,
      isInterim: () => opts.interim,
      signal: (pid: number, sig: string) => { calls.push(`${sig} ${pid}`); if (sig === "SIGKILL" || (sig === "SIGTERM" && !opts.ignoreTerm)) alive = false; return true; },
      isAlive: () => alive,
      sleep: async () => undefined,
      rename: (from: string) => { if (!opts.scriptExists) return false; renamed = true; calls.push(`rename ${from}`); return true; },
      now: () => new Date(2026, 10, 26, 14, 30, 15).getTime(),
      log: (line: string) => calls.push(line),
    };
    return { deps, calls, renamed: () => renamed };
  }

  test("stops the live interim guard by its pid, then renames its script out of reach", async () => {
    const d = retireDeps({ pid: 777, interim: true, alive: true, scriptExists: true });
    const lines = await retireInterimGuard(d.deps);
    expect(d.calls.filter((c) => c.startsWith("SIG"))).toEqual(["SIGTERM 777"]);
    expect(d.renamed()).toBe(true);
    expect(lines.map((l) => l.replace(/^\S+ \S+ /, ""))).toEqual([
      "interim guard: stopping pid 777 (remote-pi guard takes over)",
      "interim guard: stopped (pid 777)",
      `interim guard: script renamed to ${join(tmp, ".pi", "piper", "piper-guard.sh.replaced-20261126-143015")} (remote-pi guard run is the only guard now)`,
    ]);
  });

  test("a frozen interim guard gets SIGKILL after the grace", async () => {
    const d = retireDeps({ pid: 777, interim: true, alive: true, scriptExists: false, ignoreTerm: true });
    await retireInterimGuard(d.deps);
    expect(d.calls.filter((c) => c.startsWith("SIG"))).toEqual(["SIGTERM 777", "SIGKILL 777"]);
  });

  test("a pid file that names anything else is left alone; the script is still renamed", async () => {
    const d = retireDeps({ pid: 5, interim: false, alive: true, scriptExists: true });
    const lines = await retireInterimGuard(d.deps);
    expect(d.calls.filter((c) => c.startsWith("SIG"))).toEqual([]);
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("script renamed to");
  });

  test("nothing to retire: no lines", async () => {
    const d = retireDeps({ pid: null, interim: true, alive: false, scriptExists: false });
    expect(await retireInterimGuard(d.deps)).toEqual([]);
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

    const failed = await guardStart({ spawnFn: fakeSpawn, sleep: async () => undefined, runningPid: () => null, logPath: join(tmp, "guard.log") });
    expect(failed.ok).toBe(false);
    expect(failed.message).toContain("did not take its lock");
  });

  test("status: four lines in the log's vocabulary, the last one the effective settings", async () => {
    const lines = await guardStatus({ runningPid: () => 9, probe: async () => deviceRow("crashed"), sockPath: SOCK, config: config() });
    expect(lines[0]).toMatch(/^guard:\s+running \(pid 9\) — .*guard\.log$/);
    expect(lines[1]).toBe("supervisor: up (1 fleet row(s))");
    expect(lines[2]).toMatch(/^device:\s+crashed \(/);
    expect(lines[3]).toBe(`settings:  ${describeGuardConfig(config())}`);
    const down = await guardStatus({ runningPid: () => null, probe: async () => null, sockPath: SOCK, config: config() });
    expect(down.slice(0, 3)).toEqual([
      expect.stringMatching(/^guard:\s+not running/),
      `supervisor: no reply on ${SOCK}`,
      "device:     unknown (supervisor silent)",
    ]);
  });

  test("stop: waits for a restart in progress instead of shooting into it", async () => {
    const signalled: Array<[number, string]> = [];
    let alive = true;
    let waitedMs = 0;
    let inRestart = true;
    const stopped = await guardStop({
      runningPid: () => (alive ? 77 : null),
      signal: (pid, sig) => { signalled.push([pid, sig]); return true; },
      isAlive: () => alive,
      sleep: async (ms) => {
        waitedMs += ms;
        // The guard finishes its restart about 25 s after the SIGTERM.
        if (waitedMs >= 25_000) { inRestart = false; alive = false; }
      },
      restartInProgress: () => inRestart,
    });
    expect(stopped).toEqual({ ok: true, message: "guard stopped (pid 77)" });
    expect(signalled).toEqual([[77, "SIGTERM"]]); // no SIGKILL
    expect(waitedMs).toBeGreaterThanOrEqual(25_000);
  });

  test("stop: a guard that lingers WITHOUT a restart gets SIGKILL after the grace", async () => {
    const signalled: Array<[number, string]> = [];
    let alive = true;
    let waitedMs = 0;
    const stopped = await guardStop({
      runningPid: () => (alive ? 77 : null),
      signal: (pid, sig) => { signalled.push([pid, sig]); if (sig === "SIGKILL") alive = false; return true; },
      isAlive: () => alive,
      sleep: async (ms) => { waitedMs += ms; },
      restartInProgress: () => false,
    });
    expect(stopped).toEqual({ ok: true, message: "guard stopped (pid 77, needed SIGKILL)" });
    expect(signalled).toEqual([[77, "SIGTERM"], [77, "SIGKILL"]]);
    // The 10 s grace, plus the settle pause after the SIGKILL.
    expect(waitedMs).toBe(10_100);
    expect(await guardStop({ runningPid: () => null, signal: () => true, isAlive: () => false, sleep: async () => undefined, restartInProgress: () => false }))
      .toEqual({ ok: true, message: "guard is not running" });
  });

  test("the marker is a file that exists exactly while a restart runs", () => {
    const marker = fileMarker(join(tmp, "piper", "guard.restarting"));
    expect(marker.exists()).toBe(false);
    marker.set("guard pid 1");
    expect(marker.exists()).toBe(true);
    expect(readFileSync(join(tmp, "piper", "guard.restarting"), "utf8")).toBe("guard pid 1\n");
    marker.clear();
    expect(marker.exists()).toBe(false);
    marker.clear(); // idempotent
  });
});

describe("runGuardLoop", () => {
  test("logs the effective settings at start; a stop during a restart waits for the restart to finish", async () => {
    const cfg = config({ intervalMs: 5_000, failsBeforeRestart: 1 });
    const h = harness([null], cfg);
    h.out.pids = [31];
    h.out.alive.add(31);
    h.out.frozen.add(31);               // ignores SIGTERM → the sequence polls in terminatePid
    let release: () => void = () => undefined;
    const gate = new Promise<void>((r) => { release = r; });
    let sleeps = 0;
    h.deps.sleep = async () => {
      sleeps += 1;
      // The first four sleeps belong to the startup grace; the fifth is
      // inside the restart sequence.
      if (sleeps > 4) await gate;
    };
    const loop = runGuardLoop({ config: cfg, deps: { ...h.deps }, wireSignals: false });
    await new Promise((r) => setTimeout(r, 30));
    expect(messages(h.out.lines)[0]).toBe(`guard started (pid ${process.pid}): ${describeGuardConfig(cfg)}`);
    expect(messages(h.out.lines).at(-1)).toBe("supervisor: pid 31 alive but silent for 1 probes → kill");
    expect(h.out.starts).toHaveLength(0);
    expect(h.out.marker).toEqual([expect.stringMatching(/^set:/)]);

    // A TERM now must not abort the restart: stop waits for the tick.
    let stopped = false;
    const stopping = loop.stop().then(() => { stopped = true; });
    await new Promise((r) => setTimeout(r, 10));
    expect(stopped).toBe(false);

    release();
    await stopping;
    expect(h.out.starts).toHaveLength(1);
    expect(h.out.marker.at(-1)).toBe("clear");
    expect(messages(h.out.lines).slice(-2)).toEqual([
      "supervisor: start #1 (next attempt in 15 s if it does not answer)",
      `guard stopped (pid ${process.pid})`,
    ]);
  });
});

describe("runGuardCli", () => {
  test("no or unknown subcommand prints the usage (with the settings) and exits 1", async () => {
    const errs: string[] = [];
    const out: string[] = [];
    expect(await runGuardCli(["node", "index.js", "guard"], { out: (l) => out.push(l), err: (l) => errs.push(l) })).toBe(1);
    expect(await runGuardCli(["node", "index.js", "guard", "wat"], { out: (l) => out.push(l), err: (l) => errs.push(l) })).toBe(1);
    expect(errs).toHaveLength(2);
    expect(errs[0]).toContain("Usage: remote-pi guard <run|start|status|stop|once>");
    expect(errs[0]).toContain("INTERVAL_S, FAILS_BEFORE_RESTART, MAX_AGE_S");
    expect(out).toHaveLength(0);
  });

  test("run and start refuse outside Termux (a PC has a service manager)", async ({ skip }) => {
    if (process.env["TERMUX_VERSION"]) skip();
    const errs: string[] = [];
    expect(await runGuardCli(["node", "index.js", "guard", "run"], { out: () => undefined, err: (l) => errs.push(l) })).toBe(1);
    expect(await runGuardCli(["node", "index.js", "guard", "start"], { out: () => undefined, err: (l) => errs.push(l) })).toBe(1);
    expect(errs).toHaveLength(2);
    expect(errs[0]).toContain("belongs on a Termux (Android) host");
    expect(errs[1]).toContain("service manager");
  });
});
