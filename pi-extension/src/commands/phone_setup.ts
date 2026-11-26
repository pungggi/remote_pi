/**
 * `remote-pi phone-setup` — turn this Termux into a Piper session host with
 * one command (plan/173, stage A3).
 *
 * What the Step 0 spikes did by hand (docs/android.md, "Setup steps that
 * worked") took nine steps, and three of them were traps: a clipboard bridge
 * that silently does nothing, a pairing QR that needs a live terminal, a
 * supervisor nobody restarts. This command walks the same path and checks
 * each result:
 *
 *   environment  Termux, node, pi, tmux (offer to install), Termux:Boot,
 *                allow-external-apps, relay reachable, pi settings
 *   setup        `remote-pi install` (boot script), wake lock, run that very
 *                script, wait for the supervisor, the guard and the device
 *                daemon's relay room
 *   pairing      the device daemon mints the pairing link; it is PRINTED
 *                (the F-Droid clipboard bridge is broken, so printing is the
 *                primary path and the clipboard a bonus)
 *   host check   the Android rows of `remote-pi doctor`, as a closing report
 *
 * Everything that touches the phone is injected (`PhoneSetupDeps`), so the
 * flow is a unit test with recorded calls. Nothing here changes a PC: the
 * command refuses to run outside Termux.
 */

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { isWebSocketScheme, isValidRelayUrl, resolveRelayUrl, saveConfig } from "../config.js";
import { resolvePiSpawn } from "../daemon/rpc_child.js";
import {
  defaultRenderVars,
  installService,
  isGeneratedBootScript,
  lineDiff,
  previewTermuxBootScript,
  renderLineDiff,
} from "../daemon/install.js";
import { guardStart, interimGuardScriptPath, probeStatus, runningGuardPid } from "../daemon/guard.js";
import { callSupervisor } from "../daemon/client.js";
import type { DaemonInfo } from "../daemon/control_protocol.js";
import { readRoomsRegistry } from "../session/rooms_registry.js";
import { DEVICE_ROOM } from "../rooms.js";
import { isTermux as detectTermux, termuxBootScriptPath } from "../termux.js";
import { androidChecks, defaultAndroidCheckDeps, type TermuxBootApp } from "../android_checks.js";
import type { DoctorCheck } from "../doctor.js";

/** Default pairing window: the longest the interactive command allows, since
 *  the link has to travel to another device by hand. */
export const PHONE_SETUP_TTL_MS = 600_000;
/** How long the supervisor may take to answer after the boot script ran. */
export const SUPERVISOR_WAIT_MS = 30_000;
/** How long the device daemon may take to show up in the relay room. */
export const DEVICE_ROOM_WAIT_MS = 120_000;
/** One heartbeat interval of the device daemon (plan/168 tick) plus slack. */
const HEARTBEAT_SLACK_MS = 75_000;

export interface PhoneSetupOptions {
  /** `--relay <url>`: saved with `remote-pi set-relay` before anything runs. */
  relay?: string;
  /** `--yes`: answer every prompt with yes (non-interactive runs). */
  yes: boolean;
  /** `--ttl <seconds>`: pairing link lifetime (clamped by the supervisor). */
  ttlMs: number;
}

export function parsePhoneSetupArgs(args: string[]): { options: PhoneSetupOptions; error?: string } {
  const options: PhoneSetupOptions = { yes: false, ttlMs: PHONE_SETUP_TTL_MS };
  const ttl = (value: string | undefined): string | null => {
    const seconds = Number(value);
    if (!value || !Number.isFinite(seconds) || seconds <= 0) return "--ttl needs seconds: --ttl 600";
    options.ttlMs = seconds * 1000;
    return null;
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--yes" || a === "-y") options.yes = true;
    else if (a === "--relay") {
      const value = args[++i];
      if (!value) return { options, error: "--relay needs a URL: --relay http://<pc-ip>:3000" };
      options.relay = value;
    } else if (a.startsWith("--relay=")) options.relay = a.slice("--relay=".length);
    else if (a === "--ttl") {
      const error = ttl(args[++i]);
      if (error) return { options, error };
    } else if (a.startsWith("--ttl=")) {
      const error = ttl(a.slice("--ttl=".length));
      if (error) return { options, error };
    } else return { options, error: `unknown argument: ${a}` };
  }
  return { options };
}

/**
 * A relay on 127.0.0.1 / localhost / 0.0.0.0 / ::1 cannot be reached by
 * anything but this host — until Stage B gives the phone its own relay, the
 * PC's address is the only thing that works.
 */
export function isLoopbackHost(url: string): boolean {
  try {
    const host = new URL(url).hostname.replace(/^\[|\]$/g, "").toLowerCase();
    return host === "127.0.0.1" || host === "localhost" || host === "0.0.0.0" || host === "::1" || host === "";
  } catch {
    return false;
  }
}

/**
 * Has the device daemon registered its relay room since `since`? The daemon
 * writes `rooms.json` on relay connect and refreshes it on its 60 s tick
 * (plan/168), so `lastSeenAt >= since` means "connected after we started".
 * When the supervisor was already up before this run (`freshStart` false) a
 * heartbeat younger than one tick counts too — the room was never lost.
 */
export function deviceRoomReached(
  lastSeenAt: number | undefined,
  since: number,
  now: number,
  freshStart: boolean,
): boolean {
  if (lastSeenAt === undefined) return false;
  if (lastSeenAt >= since) return true;
  return !freshStart && now - lastSeenAt < HEARTBEAT_SLACK_MS;
}

/** `HH:MM` in local time, for "valid until". */
export function clockTime(ms: number): string {
  const d = new Date(ms);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

export type PairLink = { id: string; uri: string; expiresAt: number; roomId: string; name: string };

export interface PhoneSetupDeps {
  log: (line: string) => void;
  now: () => number;
  sleep: (ms: number) => Promise<void>;
  isTermux: boolean;
  nodeVersion: string;
  androidVersion: () => string | null;
  /** `pi --version` first line, or null when pi does not run. */
  piVersion: () => string | null;
  /** `tmux -V` output; empty when installed but broken; null when absent. */
  tmuxVersion: () => string | null;
  /** Runs `pkg install -y tmux`; true on exit 0. */
  installTmux: () => boolean;
  /** Asks the user. Production answers yes by itself under `--yes`. */
  confirm: (question: string, defaultYes: boolean) => Promise<boolean>;
  termuxBootApp: () => TermuxBootApp;
  allowExternalApps: () => boolean;
  /** Effective relay URL (after `setRelay`). */
  relayUrl: () => string;
  setRelay: (url: string) => void;
  fetchText: (url: string, timeoutMs: number) => Promise<string | null>;
  readSettingsPackages: () => string[] | null;
  install: (opts: { force: boolean }) => { ok: true; unitPath: string; log: string[]; backup?: string; diff?: string[] } | { ok: false; error: string };
  /** The boot script currently on disk, or null. */
  existingBootScript: () => string | null;
  /** The boot script this version would write (for the diff). */
  renderedBootScript: () => string;
  /** The interim shell guard's script is still in place (checked before the
   *  boot script runs; `remote-pi guard run` retires it). */
  interimGuardPresent: () => boolean;
  bootScriptPath: string;
  wakeLock: () => boolean;
  /** Runs the boot script (`sh <script>`), inheriting the terminal. */
  runBootScript: (path: string) => boolean;
  /** Last lines of the supervisor log, for the failure message. */
  supervisorLogTail: (lines: number) => string[];
  /** Was the supervisor already answering before this run started? */
  supervisorWasUp: () => Promise<boolean>;
  waitSupervisor: (timeoutMs: number) => Promise<DaemonInfo[] | null>;
  waitGuard: (timeoutMs: number) => Promise<number | null>;
  deviceRoomLastSeenAt: () => number | undefined;
  pair: (ttlMs: number) => Promise<{ ok: true; link: PairLink } | { ok: false; error: string }>;
  copyToClipboard: (text: string) => boolean;
  /** The Android rows of `remote-pi doctor`, for the closing report. */
  doctor: () => DoctorCheck[];
}

function firstLine(res: { status: number | null; stdout?: string | null; error?: Error }): string | null {
  if (res.error || res.status !== 0) return null;
  const line = (res.stdout ?? "").split(/\r?\n/)[0]?.trim() ?? "";
  return line.length > 0 ? line : null;
}

function home(): string {
  return process.env["REMOTE_PI_HOME"] || process.env["HOME"] || "";
}

function readPackagesFromSettings(): string[] | null {
  try {
    const parsed = JSON.parse(readFileSync(`${home()}/.pi/agent/settings.json`, "utf8")) as { packages?: unknown };
    return Array.isArray(parsed.packages) ? parsed.packages.filter((p): p is string => typeof p === "string") : null;
  } catch {
    return null;
  }
}

async function confirmOnTerminal(question: string, defaultYes: boolean, autoYes: boolean): Promise<boolean> {
  if (autoYes) return true;
  if (!process.stdin.isTTY) return false;
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    const answer: string = await new Promise((resolve) =>
      rl.question(`${question} ${defaultYes ? "[Y/n]" : "[y/N]"} `, (a) => resolve(a.trim().toLowerCase())),
    );
    if (answer.length === 0) return defaultYes;
    return answer === "y" || answer === "yes";
  } finally {
    rl.close();
  }
}

/** Production deps. Only built inside Termux (the flow checks first). */
export function defaultPhoneSetupDeps(opts: PhoneSetupOptions, log: (line: string) => void): PhoneSetupDeps {
  return {
    log,
    now: () => Date.now(),
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    isTermux: detectTermux(),
    nodeVersion: process.version,
    androidVersion: () => firstLine(spawnSync("/system/bin/getprop", ["ro.build.version.release"], { encoding: "utf8", timeout: 4000 })),
    piVersion: () => {
      const target = resolvePiSpawn("pi");
      return firstLine(spawnSync(target.command, [...target.prefixArgs, "--version"], { encoding: "utf8", timeout: 15_000 }));
    },
    tmuxVersion: () => {
      const res = spawnSync("tmux", ["-V"], { encoding: "utf8", timeout: 5000 });
      if (res.error) return null;
      return res.status === 0 ? (res.stdout ?? "").trim() : "";
    },
    installTmux: () => spawnSync("pkg", ["install", "-y", "tmux"], { stdio: "inherit" }).status === 0,
    confirm: (question, defaultYes) => confirmOnTerminal(question, defaultYes, opts.yes),
    termuxBootApp: () => defaultAndroidCheckDeps().termuxBootApp(),
    allowExternalApps: () => defaultAndroidCheckDeps().allowExternalApps(),
    relayUrl: () => resolveRelayUrl().url,
    setRelay: (url) => saveConfig({ relay: url }),
    fetchText: async (url, timeoutMs) => {
      try {
        const res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
        return res.ok ? await res.text() : null;
      } catch {
        return null;
      }
    },
    readSettingsPackages: readPackagesFromSettings,
    install: (opts) => {
      try {
        // `force` only after the user agreed to replace a script remote-pi
        // did not write; installService refuses such a file without it.
        const result = installService(defaultRenderVars(), { force: opts.force });
        return { ok: true, unitPath: result.unitPath, log: result.log, backup: result.backup, diff: result.diff };
      } catch (e) {
        return { ok: false, error: e instanceof Error ? e.message : String(e) };
      }
    },
    existingBootScript: () => {
      const path = termuxBootScriptPath();
      return existsSync(path) ? readFileSync(path, "utf8") : null;
    },
    renderedBootScript: () => previewTermuxBootScript(),
    interimGuardPresent: () => existsSync(interimGuardScriptPath()),
    bootScriptPath: termuxBootScriptPath(),
    wakeLock: () => spawnSync("termux-wake-lock", [], { encoding: "utf8", timeout: 5000 }).status === 0,
    runBootScript: (path) => spawnSync("sh", [path], { stdio: "inherit" }).status === 0,
    supervisorLogTail: (lines) => {
      try {
        return readFileSync(`${home()}/.pi/piper/supervisord.log`, "utf8").trimEnd().split("\n").slice(-lines);
      } catch {
        return [];
      }
    },
    supervisorWasUp: async () => (await probeStatus()) !== null,
    waitSupervisor: async (timeoutMs) => {
      const deadline = Date.now() + timeoutMs;
      for (;;) {
        const rows = await probeStatus();
        if (rows !== null) return rows;
        if (Date.now() >= deadline) return null;
        await new Promise((r) => setTimeout(r, 500));
      }
    },
    waitGuard: async (timeoutMs) => {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const pid = runningGuardPid();
        if (pid !== null) return pid;
        await new Promise((r) => setTimeout(r, 250));
      }
      // The script may have lost a race against a stale pid file: asking
      // explicitly is idempotent and either reports or starts the loop.
      return (await guardStart()).ok ? runningGuardPid() : null;
    },
    deviceRoomLastSeenAt: () => readRoomsRegistry().get(DEVICE_ROOM)?.lastSeenAt,
    pair: async (ttlMs) => {
      try {
        return { ok: true, link: await callSupervisor({ op: "pair", ttl_ms: ttlMs }) };
      } catch (e) {
        return { ok: false, error: e instanceof Error ? e.message : String(e) };
      }
    },
    copyToClipboard: (text) => spawnSync("termux-clipboard-set", [], { input: text, encoding: "utf8", timeout: 4000 }).status === 0,
    doctor: () => androidChecks(defaultAndroidCheckDeps()),
  };
}

// ── The flow ───────────────────────────────────────────────────────────────

const ICON = { ok: "✓", warn: "!", fail: "✗", info: "•" } as const;

/** Prints every reported line with the doctor's icons. */
class Report {
  constructor(private readonly log: (line: string) => void) {}

  line(status: keyof typeof ICON, name: string, detail = ""): void {
    this.log(` ${ICON[status]} ${name}${detail ? `: ${detail}` : ""}`);
  }

  heading(text: string): void {
    this.log(`\n${text}`);
  }

  /** A raw line (the pairing link, an indented log tail, a hint). */
  text(line: string): void {
    this.log(line);
  }

  checks(rows: DoctorCheck[]): void {
    for (const c of rows) this.line(c.status, c.name, c.detail);
  }
}

/**
 * Runs the setup. Returns the process exit code: 0 when the phone is a
 * working host and a pairing link was printed, 1 otherwise. Every failure
 * that would make the link useless stops the run where it is detected.
 */
export async function runPhoneSetup(opts: PhoneSetupOptions, deps: PhoneSetupDeps): Promise<number> {
  const report = new Report(deps.log);
  report.heading("[remote-pi] phone-setup — turning this Termux into a Piper session host");

  if (!deps.isTermux) {
    report.line("fail", "termux", "this command runs inside Termux on Android. On a PC use `remote-pi install`.");
    return 1;
  }

  // ── relay first: everything below depends on reaching it ──
  if (opts.relay !== undefined) {
    if (isWebSocketScheme(opts.relay) || !isValidRelayUrl(opts.relay)) {
      report.line("fail", "relay", `"${opts.relay}" is not an http(s) URL. Example: --relay http://192.168.1.20:3000`);
      return 1;
    }
    deps.setRelay(opts.relay);
  }

  report.heading("Environment");
  report.line("info", "termux", `Android ${deps.androidVersion() ?? "?"}, node ${deps.nodeVersion}`);
  const pi = deps.piVersion();
  if (pi === null) {
    report.line("fail", "pi", "`pi --version` did not run — install Pi first: npm install -g @earendil-works/pi-coding-agent");
    return 1;
  }
  report.line("ok", "pi", pi);

  let tmux = deps.tmuxVersion();
  if (tmux === null && (await deps.confirm("tmux is not installed. Install it now with `pkg install -y tmux`?", true))) {
    if (deps.installTmux()) tmux = deps.tmuxVersion() ?? "";
  }
  if (tmux === null) {
    report.line("fail", "tmux", "not installed — sessions started from the app run in tmux. Run: pkg install tmux");
    return 1;
  }
  if (!tmux) {
    report.line("fail", "tmux", "installed but `tmux -V` fails. Run: pkg reinstall tmux");
    return 1;
  }
  report.line("ok", "tmux", tmux);

  const bootApp = deps.termuxBootApp();
  if (bootApp === "missing") {
    const how = "Install Termux:Boot (F-Droid, the same source as Termux) and open it once.";
    const proceed = await deps.confirm(
      `Termux:Boot is not installed — without it nothing starts after a reboot. ${how} Continue anyway for this boot?`,
      false,
    );
    report.line(proceed ? "warn" : "fail", "termux:boot app", proceed ? `not installed — works now, NOT after a reboot. ${how}` : `not installed. ${how}`);
    if (!proceed) return 1;
  } else {
    report.line(
      bootApp === "installed" ? "ok" : "warn",
      "termux:boot app",
      bootApp === "installed" ? "installed (open it once if you have not — that arms it)" : "could not query the package manager — make sure Termux:Boot is installed and was opened once",
    );
  }

  const external = deps.allowExternalApps();
  report.line(
    external ? "warn" : "ok",
    "allow-external-apps",
    external ? "on — remote-pi itself does not need it; leave it on only for the app watchdog (plan/173 A7)" : "off (remote-pi talks through the relay)",
  );

  const relay = deps.relayUrl();
  if (isLoopbackHost(relay)) {
    report.line("fail", "relay", `${relay} is loopback. On the phone the relay is your PC: remote-pi phone-setup --relay http://<pc-ip>:3000`);
    return 1;
  }
  if ((await deps.fetchText(`${relay.replace(/\/$/, "")}/health`, 5000)) === null) {
    report.line("fail", "relay", `${relay}/health did not answer — check Wi-Fi and that the PC's relay is running (remote-pi doctor there)`);
    return 1;
  }
  report.line("ok", "relay", `${relay} healthy`);

  const packages = deps.readSettingsPackages();
  report.line(
    packages?.some((p) => /remote[-_]pi/i.test(p)) ? "ok" : "warn",
    "pi settings",
    packages?.some((p) => /remote[-_]pi/i.test(p))
      ? "remote-pi package present"
      : "remote-pi is not in `packages` of ~/.pi/agent/settings.json — `pi install npm:remote-pi`, or sessions will not join the relay",
  );

  // ── setup ──
  report.heading("Setup");

  // An existing boot script that is not ours (the phone ran an interim one
  // before this release existed) is shown, never silently replaced: diff on
  // screen, a dated copy on disk, and a question unless --yes answered it.
  const existingScript = deps.existingBootScript();
  const renderedScript = deps.renderedBootScript();
  // `force` lets install replace a script remote-pi did not write — only
  // after the user saw the diff and agreed.
  let force = false;
  if (existingScript !== null && existingScript !== renderedScript) {
    report.text("");
    report.text("  An existing boot script differs from the one this version writes (- old, + new):");
    for (const line of renderLineDiff(lineDiff(existingScript, renderedScript))) report.text(line);
    report.text("");
    if (!isGeneratedBootScript(existingScript)) {
      const replace = await deps.confirm(
        "Replace the existing boot script? A dated copy is kept next to it (start-piper.sh.bak-<timestamp>).",
        true,
      );
      if (!replace) {
        report.line("fail", "boot script", `kept ${deps.bootScriptPath}; nothing was changed. Remove or rename it yourself, then run this again`);
        return 1;
      }
      force = true;
    }
    report.text("  The existing script is kept as start-piper.sh.bak-<timestamp>.");
    report.text("");
  }
  if (deps.interimGuardPresent()) {
    report.text("  The interim guard (~/.pi/piper/piper-guard.sh) is retired by `remote-pi guard run`: stopped by its pid, script renamed.");
    report.text("");
  }

  const wasUp = await deps.supervisorWasUp();
  const startedAt = deps.now();
  const interimWasPresent = deps.interimGuardPresent();

  const installed = deps.install({ force });
  if (!installed.ok) {
    report.line("fail", "boot script", `remote-pi install failed: ${installed.error}`);
    return 1;
  }
  report.line(
    "ok",
    "boot script",
    installed.backup
      ? `${installed.unitPath} written; the previous version is kept at ${installed.backup}`
      : `${installed.unitPath} (Termux:Boot runs it after each reboot)`,
  );

  const awake = deps.wakeLock();
  report.line(awake ? "ok" : "warn", "wake lock", awake ? "termux-wake-lock taken (the boot script takes it again at boot)" : "termux-wake-lock failed — Android may doze Termux");

  if (!deps.runBootScript(deps.bootScriptPath)) {
    report.line("fail", "start", `running ${deps.bootScriptPath} failed — run it by hand to see the error`);
    return 1;
  }
  report.line("ok", "start", `ran ${deps.bootScriptPath}`);

  const rows = await deps.waitSupervisor(SUPERVISOR_WAIT_MS);
  if (rows === null) {
    report.line("fail", "supervisor", `no answer on the control socket within ${SUPERVISOR_WAIT_MS / 1000} s — last log lines:`);
    for (const line of deps.supervisorLogTail(12)) report.text(`     ${line}`);
    return 1;
  }
  report.line("ok", "supervisor", `${wasUp ? "already running" : "started"}, ${rows.length} fleet row(s)`);

  const guard = await deps.waitGuard(8000);
  report.line(
    guard !== null ? "ok" : "warn",
    "guard",
    guard !== null ? `running (pid ${guard}) — restarts the supervisor when it is gone` : "not running — start it with: remote-pi guard start",
  );
  if (interimWasPresent) {
    report.line(
      deps.interimGuardPresent() ? "warn" : "ok",
      "interim guard",
      deps.interimGuardPresent()
        ? "still in place — see ~/.pi/piper/guard.log (`remote-pi guard run` stops and renames it on start)"
        : "retired: remote-pi guard is the only guard now (its log lines are in ~/.pi/piper/guard.log)",
    );
  }

  report.text("     waiting for the device daemon to reach the relay (up to 120 s)…");
  const deadline = deps.now() + DEVICE_ROOM_WAIT_MS;
  while (!deviceRoomReached(deps.deviceRoomLastSeenAt(), startedAt, deps.now(), !wasUp)) {
    if (deps.now() > deadline) {
      report.line("fail", "device daemon", `did not register in room "${DEVICE_ROOM}" within ${DEVICE_ROOM_WAIT_MS / 1000} s — see ~/.pi/piper/daemons/device.log and remote-pi doctor`);
      return 1;
    }
    await deps.sleep(2000);
  }
  report.line("ok", "device daemon", `connected to the relay in room "${DEVICE_ROOM}"`);

  // ── pairing ──
  report.heading("Pairing");
  const pair = await deps.pair(opts.ttlMs);
  if (!pair.ok) {
    report.line("fail", "pairing link", `${pair.error}. Run remote-pi phone-setup again once the device daemon is connected.`);
    return 1;
  }
  report.text("");
  report.text("  Open Piper on the phone that should control this host → pair → paste this code");
  report.text("  (or send it there by chat or mail and open it):");
  report.text("");
  report.text(`      ${pair.link.uri}`);
  report.text("");
  // The supervisor clamps the TTL to the pairing window, so read the real
  // lifetime back from the link instead of trusting --ttl.
  const minutes = Math.max(1, Math.round((pair.link.expiresAt - deps.now()) / 60_000));
  report.text(`  Valid until ${clockTime(pair.link.expiresAt)} (${minutes} min). Expired? Run remote-pi phone-setup again.`);
  const copied = deps.copyToClipboard(pair.link.uri);
  report.line(copied ? "ok" : "info", "clipboard", copied ? "link copied (termux-clipboard-set)" : "not copied — copy it from the screen (the F-Droid clipboard bridge is unreliable)");

  // ── closing report ──
  report.heading("Host check (the Android rows of `remote-pi doctor`)");
  report.checks(deps.doctor());
  report.heading("That's it");
  for (const hint of [
    "Start a session from the app: it runs here in a tmux session (attach: tmux attach -t <room>).",
    "Survives reboots through Termux:Boot; the guard restarts the supervisor when it dies (remote-pi guard status).",
    "Guard settings: ~/.pi/piper/guard.conf and REMOTE_PI_GUARD_<KEY>; `remote-pi guard status` shows the effective values.",
    "Logs: ~/.pi/piper/supervisord.log, guard.log, daemons/device.log. Health: remote-pi doctor.",
    "One-time Android settings (adb, from the PC) keep Android from killing Termux — see docs/android.md.",
    "Stop on purpose: remote-pi guard stop && remote-pi daemon stop",
  ]) {
    report.text(` • ${hint}`);
  }
  return 0;
}
