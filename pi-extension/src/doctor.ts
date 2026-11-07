/**
 * `remote-pi doctor` — one-command pre-flight over the whole remote stack
 * (plan/159, step 5).
 *
 * Motivation (2026-11-07 incident): the phone showed no sessions and the
 * real cause chain (a registry entry on the home cwd spawning a duplicate
 * child that lost its room lock, a supervisor that wouldn't restart the
 * crashed rows, an unlogged supervisor) had to be excavated by hand from
 * process listings and log tails. Doctor walks the same chain in one run:
 *
 *   1. registry      — daemons.json readable, sane
 *   2. home conflict — no registry entry on the home cwd (duplicate-spawn
 *                      root cause; `_opRegister` now rejects it, this
 *                      catches hand-edited / legacy registries)
 *   3. supervisor    — control socket answers; no crashed / crash-looped
 *                      rows; fleet matches the registry
 *   4. relay         — /health answers (phone connectivity)
 *   5. pi binary     — `pi --version` spawns (PATH / shim health)
 *   6. pi settings   — no path-based remote-pi worktree packages in global
 *                      settings (breaks INTERACTIVE `pi` in a daemon cwd —
 *                      daemons themselves are protected by `-ne`)
 *
 * Every probe is injectable so tests can drive the failure paths without
 * network, sockets, or the real home directory.
 */

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { listDaemons } from "./daemon/registry.js";
import { supervisorOnline, callSupervisor, SupervisorOfflineError } from "./daemon/client.js";
import type { DaemonInfo } from "./daemon/control_protocol.js";
import { resolveRelayUrl } from "./config.js";
import { resolvePiSpawn } from "./daemon/rpc_child.js";

export interface DoctorCheck {
  name: string;
  status: "ok" | "warn" | "fail";
  detail: string;
}

export interface DoctorResult {
  checks: DoctorCheck[];
  /** True when no check failed (warnings don't fail the run). */
  healthy: boolean;
}

export interface DoctorDeps {
  /** Fetch a URL, return the body or null when unreachable. */
  fetchText?: (url: string, timeoutMs: number) => Promise<string | null>;
  /** Probe the supervisor control socket. */
  supervisorProbe?: () => Promise<boolean>;
  /** Ask the running supervisor for fleet status; null when unreachable,
   *  `error` set when it answered with an error reply. */
  supervisorStatus?: () => Promise<{ daemons: DaemonInfo[]; error?: string } | null>;
  /** Read the `packages` array from pi's global settings; null = absent. */
  readSettingsPackages?: () => string[] | null;
  /** Run `pi --version` through the same spawn path the daemon uses. */
  versionCheck?: () => { ok: boolean; detail: string };
}

// ── Default probe implementations (production) ─────────────────────────────

async function defaultFetchText(url: string, timeoutMs: number): Promise<string | null> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
    if (!res.ok) return null;
    return await res.text();
  } catch {
    return null;
  }
}

async function defaultSupervisorStatus(): Promise<{ daemons: DaemonInfo[]; error?: string } | null> {
  try {
    const data = await callSupervisor({ op: "status" });
    return { daemons: data.daemons };
  } catch (err) {
    if (err instanceof SupervisorOfflineError) return null;
    // Supervisor answered with an error reply — surface it distinctly from
    // "offline" so a wedged-but-listening socket isn't read as "down".
    return { daemons: [], error: String(err) };
  }
}

function defaultReadSettingsPackages(): string[] | null {
  const path = join(homedir(), ".pi", "agent", "settings.json");
  try {
    if (!existsSync(path)) return null;
    const parsed = JSON.parse(readFileSync(path, "utf8")) as { packages?: unknown };
    if (!Array.isArray(parsed.packages)) return null;
    return parsed.packages.filter((p): p is string => typeof p === "string");
  } catch {
    return null;
  }
}

function defaultVersionCheck(): { ok: boolean; detail: string } {
  const target = resolvePiSpawn("pi");
  try {
    const res = spawnSync(target.command, [...target.prefixArgs, "--version"], {
      timeout: 10_000,
      encoding: "utf8",
      windowsHide: true,
    });
    if (res.status === 0) {
      const first = (res.stdout || "").split(/\r?\n/, 1)[0]?.trim() ?? "";
      return { ok: true, detail: `${target.command} ${first}`.trim() };
    }
    return { ok: false, detail: `pi --version exited ${res.status}: ${(res.stderr || "").trim().slice(0, 200)}` };
  } catch (e) {
    return { ok: false, detail: `spawn failed: ${String(e)}` };
  }
}

// ── The check suite ─────────────────────────────────────────────────────────

/** Path-based (non-npm) package entries that look like a remote-pi worktree.
 *  These double-load remote-pi tools in any pi run that reads settings
 *  packages, while the daemon passes its own `-e` — the classic collision. */
export function conflictingWorktreePackages(packages: string[]): string[] {
  return packages.filter(
    (p) => !p.startsWith("npm:") && /remote[-_]pi/i.test(p),
  );
}

export async function runDoctor(deps: DoctorDeps = {}): Promise<DoctorResult> {
  const fetchText = deps.fetchText ?? defaultFetchText;
  const supervisorProbe = deps.supervisorProbe ?? supervisorOnline;
  const supervisorStatus = deps.supervisorStatus ?? defaultSupervisorStatus;
  const readSettingsPackages = deps.readSettingsPackages ?? defaultReadSettingsPackages;
  const versionCheck = deps.versionCheck ?? defaultVersionCheck;
  const checks: DoctorCheck[] = [];

  // 1 — registry
  const registry = listDaemons();
  checks.push(
    registry.length === 0
      ? { name: "registry", status: "warn", detail: "no daemons registered (only the device daemon will run)" }
      : { name: "registry", status: "ok", detail: `${registry.length} daemon(s) registered` },
  );

  // 2 — home conflict (the 2026-11-07 duplicate-spawn root cause)
  const home = process.env["REMOTE_PI_HOME"] || homedir();
  const homeEntry = registry.find((e) => e.cwd === home);
  checks.push(
    homeEntry
      ? {
          name: "home conflict",
          status: "fail",
          detail:
            `daemons.json registers the home cwd (${home}) — the always-on device ` +
            `daemon also runs there, so two children fight over the room lock. ` +
            `Run: remote-pi remove ${homeEntry.id}`,
        }
      : { name: "home conflict", status: "ok", detail: "home cwd left to the device daemon" },
  );

  // 3 — supervisor + fleet
  const online = await supervisorProbe();
  if (!online) {
    checks.push({
      name: "supervisor",
      status: "warn",
      detail: "not running — fleet is dark; run `remote-pi install` or start `pi-supervisord`",
    });
  } else {
    const status = await supervisorStatus();
    const fleet = status?.daemons ?? [];
    const crashed = fleet.filter((d) => d.state === "crashed");
    const dead = fleet.filter((d) => d.dead_since !== undefined);
    const problems: string[] = [];
    if (status?.error) problems.push(`status op error: ${status.error}`);
    if (crashed.length > 0) problems.push(`${crashed.length} crashed: ${crashed.map((d) => d.id).join(", ")}`);
    if (dead.length > 0) problems.push(`crash-loop marker on: ${dead.map((d) => d.id).join(", ")}`);
    const registryIds = new Set(registry.map((e) => e.id));
    const missing = fleet.filter((d) => !registryIds.has(d.id) && d.id !== "device" && d.name !== "transient");
    if (missing.length > 0) problems.push(`fleet rows without registry entries: ${missing.map((d) => d.id).join(", ")}`);
    checks.push(
      problems.length === 0
        ? { name: "supervisor", status: "ok", detail: `running, ${fleet.length} daemon(s), none crashed` }
        : { name: "supervisor", status: problems.some((p) => p.includes("crash-loop")) ? "fail" : "warn", detail: problems.join("; ") },
    );
  }

  // 4 — relay
  const relay = resolveRelayUrl();
  const body = await fetchText(`${relay.url.replace(/\/$/, "")}/health`, 3000);
  checks.push(
    body !== null && /ok/i.test(body)
      ? { name: "relay", status: "ok", detail: `${relay.url} healthy` }
      : {
          name: "relay",
          status: "fail",
          detail: `${relay.url}/health unreachable (source: ${relay.source}) — the phone cannot see this machine`,
        },
  );

  // 5 — pi binary
  const version = versionCheck();
  checks.push(
    version.ok
      ? { name: "pi binary", status: "ok", detail: version.detail }
      : { name: "pi binary", status: "fail", detail: version.detail },
  );

  // 6 — pi settings (interactive-sessions hazard; daemons run -ne)
  const packages = readSettingsPackages();
  if (packages === null) {
    checks.push({ name: "pi settings", status: "ok", detail: "no path-based packages" });
  } else {
    const conflicts = conflictingWorktreePackages(packages);
    checks.push(
      conflicts.length === 0
        ? { name: "pi settings", status: "ok", detail: "no remote-pi worktree packages in global settings" }
        : {
            name: "pi settings",
            status: "warn",
            detail:
              `global settings load remote-pi worktree package(s): ${conflicts.join(", ")}. ` +
              `Interactive \`pi\` in a daemon cwd double-loads tools and exits; remove the line ` +
              `(keep ONE worktree active at a time — see the repo CLAUDE.md rule)`,
          },
    );
  }

  return { checks, healthy: checks.every((c) => c.status !== "fail") };
}

/** Renders a doctor result; returns the process exit code (0 = healthy). */
export function printDoctor(result: DoctorResult, log: (line: string) => void): number {
  for (const c of result.checks) {
    const icon = c.status === "ok" ? "✓" : c.status === "warn" ? "!" : "✗";
    log(` ${icon} ${c.name}: ${c.detail}`);
  }
  const fails = result.checks.filter((c) => c.status === "fail").length;
  const warns = result.checks.filter((c) => c.status === "warn").length;
  log(fails > 0 ? `[remote-pi] doctor: ${fails} failure(s), ${warns} warning(s)` : `[remote-pi] doctor: all checks passed${warns > 0 ? ` (${warns} warning(s))` : ""}`);
  return fails > 0 ? 1 : 0;
}
