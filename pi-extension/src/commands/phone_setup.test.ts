/**
 * Plan/173 A3 — `remote-pi phone-setup`. The whole flow runs against recorded
 * deps: no phone, no socket, no process. What is asserted is the ORDER of
 * what the command does to the phone and where it stops when something is
 * wrong.
 */
import { describe, expect, test } from "vitest";
import {
  clockTime,
  defaultPhoneSetupDeps,
  deviceRoomReached,
  isLoopbackHost,
  parsePhoneSetupArgs,
  runPhoneSetup,
  type PhoneSetupDeps,
  type PhoneSetupOptions,
} from "./phone_setup.js";
import type { DaemonInfo } from "../daemon/control_protocol.js";

const SCRIPT = "/data/data/com.termux/files/home/.termux/boot/start-piper.sh";
const RELAY = "http://192.168.1.20:3000";
const T0 = 1_700_000_000_000;
const LINK = {
  id: "device",
  uri: "remotepi://pair?t=abc&epk=k&n=device&rm=device",
  /** Ten minutes after the harness clock starts (the supervisor clamps). */
  expiresAt: T0 + 600_000,
  roomId: "device",
  name: "device",
};
const BASE_OPTS: PhoneSetupOptions = { yes: false, ttlMs: 600_000 };

function fleet(): DaemonInfo[] {
  return [{ id: "device", cwd: "/home", name: "device", state: "running" }];
}

/** A healthy phone. `calls` records every side effect in order. */
function harness(overrides: Partial<PhoneSetupDeps> = {}) {
  const calls: string[] = [];
  const lines: string[] = [];
  const state = {
    now: T0,
    relay: RELAY,
    lastSeen: undefined as number | undefined,
    sleeps: 0,
    /** Called on every fake sleep; tests use it to move the world forward. */
    onSleep: (): void => undefined,
    answers: {} as Record<string, boolean>,
  };
  const deps: PhoneSetupDeps = {
    log: (l) => lines.push(l),
    now: () => state.now,
    sleep: async (ms) => {
      calls.push(`sleep:${ms}`);
      state.sleeps += 1;
      state.now += ms;
      state.onSleep();
    },
    isTermux: true,
    nodeVersion: "v26.4.0",
    androidVersion: () => "16",
    piVersion: () => "1.6.0",
    tmuxVersion: () => "tmux next-3.5",
    installTmux: () => {
      calls.push("installTmux");
      return true;
    },
    confirm: async (q, def) => {
      calls.push(`confirm(${def ? "Y" : "N"}):${q.split(" ")[0]}`);
      return state.answers[q] ?? def;
    },
    termuxBootApp: () => "installed",
    allowExternalApps: () => false,
    relayUrl: () => state.relay,
    setRelay: (url) => {
      calls.push(`setRelay:${url}`);
      state.relay = url;
    },
    fetchText: async (url) => {
      calls.push(`fetch:${url}`);
      return "OK";
    },
    readSettingsPackages: () => ["npm:remote-pi"],
    install: () => {
      calls.push("install");
      return { ok: true, unitPath: SCRIPT, log: ["wrote"] };
    },
    bootScriptPath: SCRIPT,
    wakeLock: () => {
      calls.push("wakeLock");
      return true;
    },
    runBootScript: (p) => {
      calls.push(`run:${p}`);
      // The script starts the supervisor; its device daemon registers its
      // relay room from now on.
      state.lastSeen = state.now;
      return true;
    },
    supervisorLogTail: () => ["[remote-pi-supervisord] fatal: boom"],
    supervisorWasUp: async () => {
      calls.push("wasUp");
      return false;
    },
    waitSupervisor: async () => {
      calls.push("waitSupervisor");
      return fleet();
    },
    waitGuard: async () => {
      calls.push("waitGuard");
      return 4242;
    },
    deviceRoomLastSeenAt: () => state.lastSeen,
    pair: async (ttl) => {
      calls.push(`pair:${ttl}`);
      return { ok: true, link: { ...LINK, expiresAt: state.now + ttl } };
    },
    copyToClipboard: (t) => {
      calls.push(`clipboard:${t === LINK.uri}`);
      return true;
    },
    doctor: () => [
      { name: "termux boot script", status: "ok", detail: "x" },
      { name: "guard", status: "warn", detail: "y" },
    ],
    ...overrides,
  };
  return { deps, calls, lines, state };
}

const strip = (lines: string[]): string[] => lines.map((l) => l.replace(/^\s*[✓!✗•]\s*/, "").trim());

describe("parsePhoneSetupArgs", () => {
  test("defaults, --relay in both spellings, --ttl in seconds, --yes", () => {
    expect(parsePhoneSetupArgs([]).options).toEqual({ yes: false, ttlMs: 600_000 });
    expect(parsePhoneSetupArgs(["--relay", "http://pc:3000", "--ttl", "120", "--yes"]).options).toEqual({
      yes: true, ttlMs: 120_000, relay: "http://pc:3000",
    });
    expect(parsePhoneSetupArgs(["--relay=http://pc:3000", "--ttl=5", "-y"]).options).toMatchObject({
      yes: true, ttlMs: 5_000, relay: "http://pc:3000",
    });
  });

  test("errors: missing values, bad ttl, unknown flags", () => {
    expect(parsePhoneSetupArgs(["--relay"]).error).toMatch(/--relay needs a URL/);
    expect(parsePhoneSetupArgs(["--ttl", "abc"]).error).toMatch(/--ttl needs seconds/);
    expect(parsePhoneSetupArgs(["--ttl", "0"]).error).toMatch(/--ttl needs seconds/);
    expect(parsePhoneSetupArgs(["--wat"]).error).toBe("unknown argument: --wat");
  });
});

describe("isLoopbackHost / deviceRoomReached / clockTime", () => {
  test("loopback spellings are refused; a LAN or Tailscale address passes", () => {
    for (const url of ["http://127.0.0.1:3000", "http://localhost:3000", "http://0.0.0.0:3000", "http://[::1]:3000", "https://LOCALHOST/"]) {
      expect(isLoopbackHost(url)).toBe(true);
    }
    expect(isLoopbackHost(RELAY)).toBe(false);
    expect(isLoopbackHost("http://100.64.0.9:3000")).toBe(false);
    expect(isLoopbackHost("not a url")).toBe(false);
  });

  test("the device room counts once the daemon registered after we started", () => {
    const since = 1_700_000_000_000;
    expect(deviceRoomReached(undefined, since, since + 100, true)).toBe(false);
    // An entry from before this run is not proof (the supervisor just started).
    expect(deviceRoomReached(since - 50_000, since, since + 100, true)).toBe(false);
    expect(deviceRoomReached(since + 500, since, since + 1_000, true)).toBe(true);
    // An already-running supervisor: one heartbeat younger than a tick is enough.
    expect(deviceRoomReached(since - 30_000, since, since, false)).toBe(true);
    expect(deviceRoomReached(since - 80_000, since, since, false)).toBe(false);
  });

  test("clockTime is HH:MM", () => {
    expect(clockTime(new Date(2026, 0, 2, 8, 5).getTime())).toBe("08:05");
  });
});

describe("runPhoneSetup — the happy path", () => {
  test("does every step once, in order, prints the link and exits 0", async () => {
    const h = harness();
    const code = await runPhoneSetup(BASE_OPTS, h.deps);
    expect(code).toBe(0);
    expect(h.calls).toEqual([
      "fetch:http://192.168.1.20:3000/health",
      "wasUp",
      "install",
      "wakeLock",
      `run:${SCRIPT}`,
      "waitSupervisor",
      "waitGuard",
      "pair:600000",
      "clipboard:true",
    ]);
    const text = strip(h.lines);
    expect(text).toContain("termux: Android 16, node v26.4.0");
    expect(text).toContain(`boot script: ${SCRIPT} (Termux:Boot runs it after each reboot)`);
    expect(text).toContain("supervisor: started, 1 fleet row(s)");
    expect(text).toContain("guard: running (pid 4242) — restarts the supervisor when it is gone");
    expect(text).toContain('device daemon: connected to the relay in room "device"');
    expect(h.lines).toContain(`      ${LINK.uri}`);
    expect(text).toContain(`Valid until ${clockTime(LINK.expiresAt)} (10 min). Expired? Run remote-pi phone-setup again.`);
    expect(text).toContain("clipboard: link copied (termux-clipboard-set)");
    // Closing report: the doctor rows, then the hints.
    expect(text).toContain("termux boot script: x");
    expect(text).toContain("guard: y");
    expect(text.some((l) => l.startsWith("Stop on purpose: remote-pi guard stop"))).toBe(true);
  });

  test("the device room is polled until the daemon registers; an old entry is not enough", async () => {
    const h = harness({ runBootScript: () => true });
    const stale = h.state.now - 10 * 60_000;
    h.state.lastSeen = stale;
    // The run's own clock starts at `now`; the daemon registers 6 s "later".
    h.state.onSleep = () => {
      if (h.state.sleeps === 3) h.state.lastSeen = h.state.now;
    };
    const code = await runPhoneSetup(BASE_OPTS, h.deps);
    expect(code).toBe(0);
    expect(h.calls.filter((c) => c.startsWith("sleep:"))).toHaveLength(3);
    expect(h.state.lastSeen).toBeGreaterThan(stale);
  });

  test("with the supervisor already up, a fresh heartbeat skips the wait", async () => {
    const h = harness();
    h.state.lastSeen = h.state.now - 30_000;
    h.deps.supervisorWasUp = async () => true;
    const code = await runPhoneSetup(BASE_OPTS, h.deps);
    expect(code).toBe(0);
    expect(h.calls.filter((c) => c.startsWith("sleep:"))).toHaveLength(0);
    expect(strip(h.lines)).toContain("supervisor: already running, 1 fleet row(s)");
  });
});

describe("runPhoneSetup — where it stops", () => {
  test("outside Termux it explains itself and does nothing", async () => {
    const h = harness({ isTermux: false });
    expect(await runPhoneSetup(BASE_OPTS, h.deps)).toBe(1);
    expect(h.calls).toEqual([]);
    expect(strip(h.lines).at(-1)).toMatch(/^termux: this command runs inside Termux/);
  });

  test("--relay is validated, saved, and then used for the health check", async () => {
    const h = harness();
    expect(await runPhoneSetup({ ...BASE_OPTS, relay: "ws://pc:3000" }, h.deps)).toBe(1);
    expect(h.calls).toEqual([]);
    const ok = harness();
    expect(await runPhoneSetup({ ...BASE_OPTS, relay: "http://10.0.0.5:3000/" }, ok.deps)).toBe(0);
    expect(ok.calls[0]).toBe("setRelay:http://10.0.0.5:3000/");
    expect(ok.calls[1]).toBe("fetch:http://10.0.0.5:3000/health");
  });

  test("pi missing stops before anything is changed", async () => {
    const h = harness({ piVersion: () => null });
    expect(await runPhoneSetup(BASE_OPTS, h.deps)).toBe(1);
    expect(h.calls).toEqual([]);
    expect(strip(h.lines).at(-1)).toMatch(/^pi: `pi --version` did not run/);
  });

  test("tmux: offered with yes as default; installed on yes, fatal on no; --yes needs no terminal", async () => {
    let tmux: string | null = null;
    let installedTmux = false;
    const yes = harness({
      tmuxVersion: () => tmux,
      installTmux: () => { installedTmux = true; tmux = "tmux next-3.5"; return true; },
    });
    expect(await runPhoneSetup(BASE_OPTS, yes.deps)).toBe(0);
    expect(yes.calls[0]).toBe("confirm(Y):tmux");
    expect(installedTmux).toBe(true);
    expect(yes.lines.some((l) => l.includes("✓ tmux: tmux next-3.5"))).toBe(true);

    const no = harness({
      tmuxVersion: () => null,
      installTmux: () => { throw new Error("must not be called"); },
    });
    no.state.answers["tmux is not installed. Install it now with `pkg install -y tmux`?"] = false;
    expect(await runPhoneSetup(BASE_OPTS, no.deps)).toBe(1);
    expect(strip(no.lines).at(-1)).toMatch(/^tmux: not installed — .*pkg install tmux/);

    // --yes is honoured by the production confirm, which therefore never
    // needs a terminal. Without it a non-terminal stdin answers "no".
    const auto = defaultPhoneSetupDeps({ ...BASE_OPTS, yes: true }, () => undefined);
    expect(await auto.confirm("Anything?", false)).toBe(true);
    const manual = defaultPhoneSetupDeps(BASE_OPTS, () => undefined);
    if (!process.stdin.isTTY) expect(await manual.confirm("Anything?", true)).toBe(false);

    const broken = harness({ tmuxVersion: () => "" });
    expect(await runPhoneSetup(BASE_OPTS, broken.deps)).toBe(1);
    expect(strip(broken.lines).at(-1)).toMatch(/^tmux: installed but `tmux -V` fails/);
  });

  test("Termux:Boot missing: asks (default no); no → fatal, yes → warning and the run continues", async () => {
    const question = expect.stringMatching(/^confirm\(N\):Termux:Boot/);
    const no = harness({ termuxBootApp: () => "missing" });
    expect(await runPhoneSetup(BASE_OPTS, no.deps)).toBe(1);
    expect(no.calls[0]).toEqual(question);
    expect(strip(no.lines).at(-1)).toMatch(/^termux:boot app: not installed\. Install Termux:Boot/);
    expect(no.calls).not.toContain("install");

    const yes = harness({ termuxBootApp: () => "missing" });
    yes.state.answers["Termux:Boot is not installed — without it nothing starts after a reboot. Install Termux:Boot (F-Droid, the same source as Termux) and open it once. Continue anyway for this boot?"] = true;
    expect(await runPhoneSetup(BASE_OPTS, yes.deps)).toBe(0);
    expect(strip(yes.lines)).toContainEqual(expect.stringMatching(/^termux:boot app: not installed — works now, NOT after a reboot\./));

    const unknown = harness({ termuxBootApp: () => "unknown" });
    expect(await runPhoneSetup(BASE_OPTS, unknown.deps)).toBe(0);
    expect(strip(unknown.lines)).toContainEqual(expect.stringMatching(/^termux:boot app: could not query/));
  });

  test("loopback relay and an unreachable relay are fatal, with the fix in the line", async () => {
    const loop = harness();
    loop.state.relay = "http://127.0.0.1:3000";
    expect(await runPhoneSetup(BASE_OPTS, loop.deps)).toBe(1);
    expect(loop.calls).toEqual([]);
    expect(strip(loop.lines).at(-1)).toContain("remote-pi phone-setup --relay http://<pc-ip>:3000");
    const deadCalls: string[] = [];
    const dead = harness({
      fetchText: async (url) => {
        deadCalls.push(`fetch:${url}`);
        return null;
      },
    });
    expect(await runPhoneSetup(BASE_OPTS, dead.deps)).toBe(1);
    expect(deadCalls).toEqual(["fetch:http://192.168.1.20:3000/health"]);
    expect(dead.calls).toEqual([]);
    expect(strip(dead.lines).at(-1)).toMatch(/^relay: .*\/health did not answer/);
  });

  test("remote-pi missing from pi settings is a warning, not a stop", async () => {
    const h = harness({ readSettingsPackages: () => ["npm:pi-schedule"] });
    expect(await runPhoneSetup(BASE_OPTS, h.deps)).toBe(0);
    expect(strip(h.lines)).toContainEqual(expect.stringMatching(/^pi settings: remote-pi is not in `packages`/));
  });

  test("a failing install, a failing start and a silent supervisor each stop with the log tail", async () => {
    const install = harness({ install: () => ({ ok: false, error: "supervisor script not found" }) });
    expect(await runPhoneSetup(BASE_OPTS, install.deps)).toBe(1);
    expect(install.calls).not.toContain("wakeLock");
    expect(strip(install.lines).at(-1)).toBe("boot script: remote-pi install failed: supervisor script not found");

    const start = harness({ runBootScript: () => false });
    expect(await runPhoneSetup(BASE_OPTS, start.deps)).toBe(1);
    expect(start.calls).not.toContain("waitSupervisor");

    const silent = harness({ waitSupervisor: async () => null });
    expect(await runPhoneSetup(BASE_OPTS, silent.deps)).toBe(1);
    expect(silent.calls).not.toContain("waitGuard");
    expect(strip(silent.lines).slice(-2)).toEqual([
      "supervisor: no answer on the control socket within 30 s — last log lines:",
      "[remote-pi-supervisord] fatal: boom",
    ]);
  });

  test("a missing guard is a warning (the supervisor runs); the device daemon never arriving is fatal", async () => {
    const noGuard = harness({ waitGuard: async () => null });
    expect(await runPhoneSetup(BASE_OPTS, noGuard.deps)).toBe(0);
    expect(strip(noGuard.lines)).toContain("guard: not running — start it with: remote-pi guard start");

    const dark = harness({ runBootScript: () => true });
    dark.state.lastSeen = dark.state.now - 3_600_000; // yesterday's entry
    const code = await runPhoneSetup(BASE_OPTS, dark.deps);
    expect(code).toBe(1);
    // 120 s window, polled every 2 s.
    expect(dark.calls.filter((c) => c === "sleep:2000")).toHaveLength(61);
    expect(dark.calls).not.toContain("pair:600000");
    expect(strip(dark.lines).at(-1)).toMatch(/^device daemon: did not register in room "device" within 120 s/);
  });

  test("a refused pairing link is fatal with the retry hint; no clipboard is merely noted", async () => {
    const refused = harness({ pair: async () => ({ ok: false, error: "daemon device produced no pairing code" }) });
    expect(await runPhoneSetup(BASE_OPTS, refused.deps)).toBe(1);
    expect(strip(refused.lines).at(-1)).toBe("pairing link: daemon device produced no pairing code. Run remote-pi phone-setup again once the device daemon is connected.");

    const noClip = harness({ copyToClipboard: () => false });
    expect(await runPhoneSetup(BASE_OPTS, noClip.deps)).toBe(0);
    expect(strip(noClip.lines)).toContain("clipboard: not copied — copy it from the screen (the F-Droid clipboard bridge is unreliable)");
  });

  test("--ttl reaches the supervisor in milliseconds", async () => {
    const h = harness();
    expect(await runPhoneSetup({ ...BASE_OPTS, ttlMs: 120_000 }, h.deps)).toBe(0);
    expect(h.calls).toContain("pair:120000");
    expect(strip(h.lines)).toContain(`Valid until ${clockTime(T0 + 120_000)} (2 min). Expired? Run remote-pi phone-setup again.`);
  });
});

// ── Production deps ────────────────────────────────────────────────────────

describe("defaultPhoneSetupDeps", () => {
  test("is only meaningful inside Termux and wires the real helpers", () => {
    const deps = defaultPhoneSetupDeps(BASE_OPTS, () => undefined);
    expect(typeof deps.isTermux).toBe("boolean");
    expect(deps.bootScriptPath).toMatch(/\.termux[/\\]boot[/\\]start-piper\.sh$/);
    expect(deps.doctor().length).toBeGreaterThanOrEqual(0);
  });
});
