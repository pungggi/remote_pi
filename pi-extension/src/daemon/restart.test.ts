/**
 * PR #126 (F4) — `remote-pi restart-supervisor` must tell the truth.
 *
 * The incident of 2026-11-26: the running supervisor had been started by hand,
 * not by the scheduled task; `schtasks /End` ended nothing, `/Run` launched a
 * second instance that refused to start, and the command printed "Supervisor
 * restarted." with exit 0 while the same pids kept running. The whole flow is
 * driven here against a scripted supervisor identity and a fake clock.
 */
import { describe, expect, test } from "vitest";
import {
  RESTART_WAIT_MS,
  incarnationChanged,
  restartSupervisor,
  restartSupervisorCommand,
  startSupervisorCommand,
  type RunOutcome,
  type SupervisorIdentity,
} from "./restart.js";
import type { DaemonInfo } from "./control_protocol.js";

const SOCK = "\\\\.\\pipe\\remote-pi-supervisor-user";
const TASK = "RemotePiSupervisor";

function rows(...pids: Array<[string, number | undefined]>): DaemonInfo[] {
  return pids.map(([id, pid]) => ({ id, cwd: "/home", name: id, state: "running", ...(pid !== undefined ? { pid } : {}) }));
}

/** The identity one probe reports. */
type Script = SupervisorIdentity;

function harness(opts: {
  platform?: NodeJS.Platform;
  before: Script;
  /** What every later probe reports. `phase` tells whether the service
   *  commands or the kill fallback have run. */
  probe: (call: number, phase: "steps" | "fallback") => Script;
  /** `owner()` answers when asked outside a probe (the kill fallback).
   *  Default: whatever the current probe scripts. */
  ownerAlone?: () => { pid: number } | null;
  waitMs?: number;
  run?: (cmd: string, args: string[]) => RunOutcome;
  /** When the old supervisor pid disappears: after SIGTERM, only after
   *  SIGKILL, or never. Default: after SIGTERM. */
  supervisorDies?: "term" | "kill" | "never";
  /** How long after the supervisor died its children exit (stdio EOF). */
  childrenExitMs?: number;
  /** Whether the OLD processes (supervisor + children) exist at all. */
  oldProcessesAlive?: boolean;
}) {
  let now = 1_000_000;
  const log: string[] = [];
  const runs: string[] = [];
  const kills: Array<[number, string]> = [];
  let ownerCalls = 0;
  const alive = new Set<number>();
  if (opts.oldProcessesAlive !== false) {
    for (const pid of [opts.before.pid, ...(opts.before.rows ?? []).map((d) => d.pid)]) {
      if (pid !== null && pid !== undefined) alive.add(pid);
    }
  }
  let phase: "steps" | "fallback" = "steps";
  let probes = -1;
  // Set by status(), consumed by the owner() of the same probe. Anything
  // else that happens in between (a kill, a command, a wait) clears it, so
  // an owner() that follows is the flow's standalone lookup in the fallback.
  // A liveness check does not clear it: the poll reads the old pid's liveness
  // between the two halves of one probe.
  let paired = false;
  let supervisorDiedAt: number | null = null;

  const current = (): Script => {
    const call = probes;
    return call <= 0 ? opts.before : opts.probe(call, phase);
  };
  const deps = {
    platform: opts.platform ?? "win32",
    uid: 0,
    sockPath: SOCK,
    status: async () => {
      probes += 1;
      paired = true;
      return current().rows;
    },
    owner: async () => {
      ownerCalls += 1;
      if (!paired) {
        const alone = (opts.ownerAlone ? opts.ownerAlone()?.pid : current().pid) ?? null;
        return alone === null ? null : { pid: alone };
      }
      paired = false;
      const pid = current().pid;
      return pid === null ? null : { pid };
    },
    run: (cmd: string, args: string[]) => {
      paired = false;
      const line = `${cmd} ${args.join(" ")}`;
      runs.push(line);
      if (cmd === "schtasks" && args[0] === "/Run" && phase === "steps") phase = "fallback";
      return opts.run ? opts.run(cmd, args) : { ok: true, detail: "" };
    },
    kill: (pid: number, signal: string) => {
      paired = false;
      kills.push([pid, signal]);
      if (opts.supervisorDies === "never") return true;
      if (opts.supervisorDies === "kill" && signal === "SIGTERM") return true;
      alive.delete(pid);
      supervisorDiedAt = now;
      return true;
    },
    pidAlive: (pid: number) => alive.has(pid),
    sleep: async (ms: number) => {
      paired = false;
      now += ms;
      if (supervisorDiedAt !== null && now - supervisorDiedAt >= (opts.childrenExitMs ?? 6_000)) {
        for (const d of opts.before.rows ?? []) if (d.pid !== undefined) alive.delete(d.pid);
      }
    },
    now: () => now,
    log: (line: string) => log.push(line),
    waitMs: opts.waitMs ?? 5_000,
  };
  return { deps, log, runs, kills, clockMs: () => now, ownerCalls: () => ownerCalls };
}

const OLD: Script = { pid: 13772, rows: rows(["device", 27180], ["ab12cd34", 27190]) };
const FRESH: Script = { pid: 15000, rows: rows(["device", 31111], ["ab12cd34", 31120]) };

describe("restartSupervisorCommand / startSupervisorCommand", () => {
  test("restart: kickstart -k, systemctl restart, schtasks /End (tolerated) + /Run; null elsewhere", () => {
    expect(restartSupervisorCommand("darwin", 501)).toEqual([{ cmd: "launchctl", args: ["kickstart", "-k", "gui/501/ch.pungitore.piper.supervisord"] }]);
    expect(restartSupervisorCommand("linux", 1000)).toEqual([{ cmd: "systemctl", args: ["--user", "restart", "remote-pi-supervisord.service"] }]);
    expect(restartSupervisorCommand("win32", 0)).toEqual([
      { cmd: "schtasks", args: ["/End", "/TN", TASK], ignoreFailure: true },
      { cmd: "schtasks", args: ["/Run", "/TN", TASK] },
    ]);
    expect(restartSupervisorCommand("aix", 0)).toBeNull();
  });

  test("start (second half of the fallback): no -k, start instead of restart, /Run alone", () => {
    expect(startSupervisorCommand("darwin", 501)).toEqual([{ cmd: "launchctl", args: ["kickstart", "gui/501/ch.pungitore.piper.supervisord"] }]);
    expect(startSupervisorCommand("linux", 1000)).toEqual([{ cmd: "systemctl", args: ["--user", "start", "remote-pi-supervisord.service"] }]);
    expect(startSupervisorCommand("win32", 0)).toEqual([{ cmd: "schtasks", args: ["/Run", "/TN", TASK] }]);
    expect(startSupervisorCommand("sunos", 0)).toBeNull();
  });
});

describe("incarnationChanged", () => {
  test("a new socket owner is a new supervisor; while nobody answers nothing changed", () => {
    expect(incarnationChanged(OLD, FRESH)).toBe(true);
    expect(incarnationChanged(OLD, { pid: 13772, rows: rows(["device", 27180]) })).toBe(false);
    expect(incarnationChanged(OLD, { pid: null, rows: null })).toBe(false);
  });

  test("was down, answers now: started counts as changed", () => {
    expect(incarnationChanged({ pid: null, rows: null }, FRESH)).toBe(true);
    expect(incarnationChanged({ pid: null, rows: null }, { pid: null, rows: null })).toBe(false);
  });

  test("where the owner cannot be named (macOS) the children's pids decide", () => {
    expect(incarnationChanged({ pid: null, rows: OLD.rows }, { pid: null, rows: FRESH.rows })).toBe(true);
    expect(incarnationChanged({ pid: null, rows: OLD.rows }, { pid: null, rows: OLD.rows })).toBe(false);
    expect(incarnationChanged({ pid: null, rows: OLD.rows }, { pid: null, rows: [] })).toBe(false);
  });
});

describe("restartSupervisor — the honest path", () => {
  test("Windows, healthy: /End + /Run, the pid changes, exit ok with both pids in the message", async () => {
    // Probe 1: the old instance is still shutting down; probe 2: the new one answers.
    const h = harness({ before: OLD, probe: (n) => (n === 1 ? { pid: null, rows: null } : FRESH) });
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(true);
    expect(h.runs).toEqual([`schtasks /End /TN ${TASK}`, `schtasks /Run /TN ${TASK}`]);
    expect(h.kills).toEqual([]);
    expect(r.message).toBe("Supervisor restarted: pid 13772, 2 fleet row(s) → pid 15000, 2 fleet row(s) (0.5 s).");
    // The verdict is printed once by the CLI (main.ts), not by the flow itself.
    expect(h.log.some((l) => l.includes("Supervisor restarted"))).toBe(false);
    expect(h.ownerCalls()).toBe(2);   // the identity before, and the one candidate
  });

  test("supervisor down before: the service command starts it, reported as such", async () => {
    const h = harness({ platform: "linux", before: { pid: null, rows: null }, probe: () => FRESH });
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(true);
    expect(h.runs).toEqual(["systemctl --user restart remote-pi-supervisord.service"]);
    expect(r.message).toBe("Supervisor restarted: not answering (pid unknown) → pid 15000, 2 fleet row(s) (0.0 s).");
  });

  test("macOS, owner unknown on both sides: the respawned children prove the restart", async () => {
    const h = harness({ platform: "darwin", before: { pid: null, rows: OLD.rows }, probe: () => ({ pid: null, rows: FRESH.rows }) });
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(true);
    expect(r.message).toContain("pid unknown, 2 fleet row(s) → pid unknown, 2 fleet row(s)");
  });

  test("a /End that fails is ignored (nothing to end); a /Run that cannot spawn fails the command", async () => {
    const h = harness({
      before: OLD,
      probe: () => FRESH,
      run: (cmd, args) => (cmd === "schtasks" && args[0] === "/End" ? { ok: false, reason: "failed", detail: "exited 1: The task is not currently running." } : { ok: true, detail: "" }),
    });
    expect((await restartSupervisor(h.deps)).ok).toBe(true);
    expect(h.log).toContain("  schtasks /End /TN RemotePiSupervisor → failed, ignored (exited 1: The task is not currently running.)");

    const broken = harness({
      before: OLD,
      probe: () => FRESH,
      run: () => ({ ok: false, reason: "not-runnable", detail: "spawn schtasks ENOENT" }),
    });
    const r = await restartSupervisor(broken.deps);
    expect(r.ok).toBe(false);
    expect(r.message).toBe(
      `restart-supervisor failed: schtasks /Run /TN ${TASK} not runnable (spawn schtasks ENOENT). Is the service installed? Run \`remote-pi install\`.`,
    );
  });

  test("an unsupported platform says so and exits non-zero", async () => {
    const h = harness({ platform: "aix", before: OLD, probe: () => FRESH });
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(false);
    expect(r.message).toBe("restart-supervisor is not supported on 'aix' yet. Restart pi-supervisord manually.");
    expect(h.runs).toEqual([]);
  });

  test("the poll bound is the default 30 s", () => {
    expect(RESTART_WAIT_MS).toBe(30_000);
  });
});

describe("restartSupervisor — the incident of 2026-11-26 (status never changes)", () => {
  test("same pid after /End + /Run → stop the foreign instance by pid, wait for its daemons, /Run again, then a new pid", async () => {
    let fresh = false;
    const h = harness({
      before: OLD,
      probe: () => (fresh ? FRESH : OLD),
      supervisorDies: "term",
      childrenExitMs: 6_000,
    });
    // The old instance yields to nothing until it is stopped; the second /Run
    // (after the kill) finally starts the service's own instance.
    const origRun = h.deps.run;
    h.deps.run = (cmd, args) => {
      const out = origRun(cmd, args);
      if (h.kills.length > 0 && cmd === "schtasks" && args[0] === "/Run") fresh = true;
      return out;
    };
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(true);
    expect(h.runs).toEqual([`schtasks /End /TN ${TASK}`, `schtasks /Run /TN ${TASK}`, `schtasks /Run /TN ${TASK}`]);
    expect(h.kills).toEqual([[13772, "SIGTERM"]]);
    expect(r.message).toContain("Supervisor restarted through the fallback: pid 13772, 2 fleet row(s) → pid 15000, 2 fleet row(s)");
    expect(r.message).toContain("The service did not own the running instance; keep ONE launcher");
    expect(h.log.some((l) => l.includes("Supervisor restarted"))).toBe(false);
    // Review on #127: while nothing changed the poll cost one status round
    // trip per tick; the socket owner was asked for for the identity before,
    // for the report ("no new supervisor … pid 13772"), and for the one
    // candidate after the second /Run — never per tick.
    expect(h.ownerCalls()).toBe(3);
    expect(h.log).toContain("  no new supervisor after 5.0 s: pid 13772, 2 fleet row(s)");
    expect(h.log).toContain("  the service did not own the running instance → stopping pid 13772 and starting the service again");
    expect(h.log).toContain("  old daemons exited");
    // The second /Run waited for the old daemons (6 s after the kill) — never
    // next to a process still holding a room lock.
    expect(h.clockMs() - 1_000_000).toBeGreaterThanOrEqual(5_000 + 6_000);
  });

  test("a supervisor that ignores SIGTERM gets SIGKILL before the service is started again", async () => {
    let fresh = false;
    const h = harness({ before: OLD, probe: () => (fresh ? FRESH : OLD), supervisorDies: "kill" });
    const origRun = h.deps.run;
    h.deps.run = (cmd, args) => {
      const out = origRun(cmd, args);
      if (h.kills.length > 1 && cmd === "schtasks" && args[0] === "/Run") fresh = true;
      return out;
    };
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(true);
    expect(h.kills).toEqual([[13772, "SIGTERM"], [13772, "SIGKILL"]]);
    expect(h.runs.filter((l) => l.includes("/Run"))).toHaveLength(2);
  });

  test("still the same supervisor after the fallback → NOT restarted, exit non-zero, said so", async () => {
    const h = harness({ before: OLD, probe: () => OLD, supervisorDies: "term" });
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(false);
    expect(h.kills).toEqual([[13772, "SIGTERM"]]);
    expect(h.runs.filter((l) => l.includes("/Run"))).toHaveLength(2);
    expect(r.message).toBe(
      "restart-supervisor: the supervisor was NOT restarted (after stopping pid 13772 and starting the service, " +
        "pid 13772, 2 fleet row(s) after 5.0 s). See ~/.pi/piper/supervisord.log.",
    );
  });

  test("a supervisor that survives SIGTERM and SIGKILL is reported, the service is not started next to it", async () => {
    const h = harness({ before: OLD, probe: () => OLD, supervisorDies: "never" });
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(false);
    expect(h.kills).toEqual([[13772, "SIGTERM"], [13772, "SIGKILL"]]);
    expect(h.runs.filter((l) => l.includes("/Run"))).toHaveLength(1);
    expect(r.message).toBe("restart-supervisor: the supervisor was NOT restarted (pid 13772 survived SIGTERM and SIGKILL).");
  });

  test("review on #127: old processes already gone + same fleet reported → nothing is stopped, said so", async () => {
    // macOS shape (owner unknown), the children's pids read the same as before,
    // but none of the old processes exists any more: the unchanged answer
    // cannot be trusted as "the foreign instance survives".
    const h = harness({
      platform: "darwin",
      before: { pid: null, rows: OLD.rows },
      probe: () => ({ pid: null, rows: OLD.rows }),
      oldProcessesAlive: false,
    });
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(false);
    expect(h.kills).toEqual([]);
    expect(r.message).toBe(
      "restart-supervisor: cannot tell whether the supervisor was restarted: its previous processes (pid 27180, 27190) " +
        "are gone, yet the control socket still reports the same fleet (pid unknown, 2 fleet row(s)). Nothing was stopped.",
    );
    // The identity before and the report's naming attempt; no poll ever
    // asked for the owner because no tick looked like a new incarnation.
    expect(h.ownerCalls()).toBe(2);
  });

  test("no pid to stop (owner unknown and status frozen): honest failure with the manual steps, no kill", async () => {
    const frozen: Script = { pid: null, rows: OLD.rows };
    const h = harness({ platform: "darwin", before: frozen, probe: () => frozen, ownerAlone: () => null });
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(false);
    expect(h.kills).toEqual([]);
    expect(h.runs).toEqual(["launchctl kickstart -k gui/0/ch.pungitore.piper.supervisord"]);
    expect(r.message).toContain("could not be identified before the attempt, so nothing was stopped");
    expect(r.message).toContain("Stop-Process");
    expect(r.exitCode).toBe(1);
    // The identity before and the report's naming: nothing is looked up to kill.
    expect(h.ownerCalls()).toBe(2);
  });

  test("third review: an owner learned only afterwards is not a kill target — a new instance the poll missed stays alive", async () => {
    // The owner could not be named before the attempt. During the poll a NEW
    // supervisor took the socket and kept the fleet's pids, so nothing looked
    // different and the poll never asked for the owner. The report's lookup
    // after the poll then learns its pid: before, the fallback killed it.
    const h = harness({
      before: { pid: null, rows: OLD.rows },
      probe: () => ({ pid: 15000, rows: OLD.rows }),
    });
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(false);
    expect(r.exitCode).toBe(1);
    expect(h.kills).toEqual([]);
    // The service's start command is not repeated either: somebody answers.
    expect(h.runs).toEqual([`schtasks /End /TN ${TASK}`, `schtasks /Run /TN ${TASK}`]);
    expect(r.message).toContain("could not be identified before the attempt, so nothing was stopped");
    // The identity before and the report's naming; no lookup for a kill.
    expect(h.ownerCalls()).toBe(2);
  });

  test("third review: the old pid is gone by the time the fallback would kill it → no kill, the service is started, the new instance answers", async () => {
    let gone = false;
    let fresh = false;
    const h = harness({ before: OLD, probe: () => (fresh ? FRESH : OLD) });
    const realOwner = h.deps.owner;
    const realAlive = h.deps.pidAlive;
    let ownerCalls = 0;
    h.deps.owner = async () => {
      // The second owner query is the one the report makes after the poll:
      // the old supervisor dies right there, and a new one is on its way.
      if (++ownerCalls === 2) {
        gone = true;
        fresh = true;
      }
      return realOwner();
    };
    h.deps.pidAlive = (pid) => (pid === OLD.pid && gone ? false : realAlive(pid));
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(true);
    expect(r.exitCode).toBe(0);
    expect(h.kills).toEqual([]);
    expect(h.runs).toEqual([`schtasks /End /TN ${TASK}`, `schtasks /Run /TN ${TASK}`, `schtasks /Run /TN ${TASK}`]);
    expect(r.message).toBe(
      "Supervisor started through the fallback: pid 13772, 2 fleet row(s) → pid 15000, 2 fleet row(s) (0.0 s). " +
        "The service's own restart had not brought it up.",
    );
    expect(h.log).toContain("  the old supervisor (pid 13772) is already gone → starting the service");
  });

  test("owner unknown and nobody answers any more: nothing to stop, the service is started and the new instance answers", async () => {
    // The socket was silent before the attempt and still is when the poll
    // ends. Before: a lookup for something to kill, then a failure; a
    // supervisor that was simply down never got started by the fallback.
    let up = false;
    const h = harness({
      platform: "linux",
      before: { pid: null, rows: null },
      probe: () => (up ? FRESH : { pid: null, rows: null }),
    });
    const origRun = h.deps.run;
    let commands = 0;
    h.deps.run = (cmd, args) => {
      commands += 1;
      if (commands === 2) up = true; // the start in the fallback brings it up
      return origRun(cmd, args);
    };
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(true);
    expect(r.exitCode).toBe(0);
    expect(h.kills).toEqual([]);
    expect(h.runs).toEqual([
      "systemctl --user restart remote-pi-supervisord.service",
      "systemctl --user start remote-pi-supervisord.service",
    ]);
    expect(r.message).toBe(
      "Supervisor started through the fallback: not answering (pid unknown) → pid 15000, 2 fleet row(s) (0.0 s). " +
        "The service's own restart had not brought it up.",
    );
    expect(h.log).toContain(
      "  the control socket does not answer and no pid was identified before the attempt → starting the service",
    );
  });
});

describe("restartSupervisor — second review on #127", () => {
  test("same children, new socket owner: found on the first tick (the old pid is gone, somebody answers)", async () => {
    // The fleet kept its pids (not respawned yet, or respawned onto the same
    // ones), so the fingerprint says "nothing new". The old supervisor's pid
    // being gone while the socket still answers makes it a candidate anyway.
    for (const [platform, run] of [
      ["win32", `schtasks /Run /TN ${TASK}`],
      ["linux", "systemctl --user restart remote-pi-supervisord.service"],
    ] as const) {
      const h = harness({
        platform,
        before: OLD,
        probe: () => ({ pid: 15000, rows: OLD.rows }),
        oldProcessesAlive: false,
      });
      const r = await restartSupervisor(h.deps);
      expect(r.ok).toBe(true);
      expect(r.exitCode).toBe(0);
      expect(r.message).toBe("Supervisor restarted: pid 13772, 2 fleet row(s) → pid 15000, 2 fleet row(s) (0.0 s).");
      expect(h.runs.filter((l) => l === run)).toHaveLength(1);
      expect(h.kills).toEqual([]);
      expect(h.ownerCalls()).toBe(2);   // the identity before, and the one candidate
    }
  });

  test("the new supervisor answers before its fleet spawned (empty fleet): still a new incarnation", async () => {
    const h = harness({ before: OLD, probe: () => ({ pid: 15000, rows: [] }), oldProcessesAlive: false });
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(true);
    expect(r.message).toBe("Supervisor restarted: pid 13772, 2 fleet row(s) → pid 15000, 0 fleet row(s) (0.0 s).");
  });

  test("owner unknown (macOS) and the same children: nothing can prove a restart, the poll runs to its bound, no kill", async () => {
    const frozen: Script = { pid: null, rows: OLD.rows };
    const h = harness({ platform: "darwin", before: frozen, probe: () => frozen, ownerAlone: () => null });
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(false);
    expect(r.exitCode).toBe(1);
    expect(h.clockMs() - 1_000_000).toBeGreaterThanOrEqual(5_000);
    expect(h.kills).toEqual([]);
    expect(r.message).toContain("could not be identified before the attempt, so nothing was stopped");
    // The identity before and the report's naming attempt: no tick asked for
    // an owner it cannot make sense of, and nothing is looked up to kill.
    expect(h.ownerCalls()).toBe(2);
  });

  test("the old supervisor alive and the fleet unchanged (the incident): the poll still asks nobody", async () => {
    const h = harness({ before: OLD, probe: () => OLD, supervisorDies: "never" });
    const r = await restartSupervisor(h.deps);
    expect(r.ok).toBe(false);
    expect(r.exitCode).toBe(1);
    expect(r.message).toBe("restart-supervisor: the supervisor was NOT restarted (pid 13772 survived SIGTERM and SIGKILL).");
    expect(h.ownerCalls()).toBe(2);   // the identity before and the report; the fallback's lookup never runs (the pid is known)
  });

  test("a service command that failed with a code of its own hands that code to the caller", async () => {
    const failed = harness({
      before: OLD,
      probe: () => FRESH,
      run: (cmd, args) =>
        cmd === "schtasks" && args[0] === "/Run"
          ? { ok: false, reason: "failed", detail: "exited 2147943712: The operator or administrator has refused the request", status: 2147943712 }
          : { ok: true, detail: "" },
    });
    const r = await restartSupervisor(failed.deps);
    expect(r.ok).toBe(false);
    expect(r.exitCode).toBe(2147943712);
    expect(r.message).toBe(
      `restart-supervisor failed: schtasks /Run /TN ${TASK} failed (exited 2147943712: The operator or administrator has refused the request)`,
    );

    // Killed by a signal (status null) or not runnable at all: 1.
    const signalled = harness({
      before: OLD,
      probe: () => FRESH,
      run: (cmd) => (cmd === "schtasks" ? { ok: false, reason: "failed", detail: "killed by SIGKILL", status: null } : { ok: true, detail: "" }),
    });
    // /End fails first but is tolerated; /Run then fails with status null.
    const r2 = await restartSupervisor(signalled.deps);
    expect(r2.ok).toBe(false);
    expect(r2.exitCode).toBe(1);

    const missing = harness({ before: OLD, probe: () => FRESH, run: () => ({ ok: false, reason: "not-runnable", detail: "spawn schtasks ENOENT" }) });
    const r3 = await restartSupervisor(missing.deps);
    expect(r3.ok).toBe(false);
    expect(r3.exitCode).toBe(1);
  });

  test("a healthy restart and the unsupported platform: exit codes 0 and 1", async () => {
    const ok = await restartSupervisor(harness({ before: OLD, probe: () => FRESH }).deps);
    expect(ok.ok).toBe(true);
    expect(ok.exitCode).toBe(0);
    const aix = await restartSupervisor(harness({ platform: "aix", before: OLD, probe: () => FRESH }).deps);
    expect(aix.ok).toBe(false);
    expect(aix.exitCode).toBe(1);
  });
});
