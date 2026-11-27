/**
 * Android (Termux) health checks — plan/173, stage A3.
 *
 * One source of truth for "is this phone set up to be an always-on session
 * host", consumed by `remote-pi doctor` (appended only inside Termux) and by
 * `remote-pi phone-setup` (as its closing report). Every probe is injectable,
 * so the whole table is unit-testable on a PC and nothing here touches a
 * phone by itself.
 *
 * What each check means for the owner:
 *
 *   boot script        Termux:Boot runs it after each reboot. Missing = the
 *                      phone leaves the mesh at the next reboot (2026-11-25).
 *                      Termux:Boot runs EVERY file of that directory, so old
 *                      copies left there run too (2026-11-27): a warning.
 *   Termux:Boot app    The thing that runs the script. Install it from F-Droid
 *                      and OPEN IT ONCE — that is what arms it.
 *   wake lock          Keeps Android from dozing Termux. The boot script takes
 *                      it; its state cannot be read back from inside Termux.
 *   allow-external-apps  Off is right: remote-pi talks through the relay and
 *                      does not need other apps to start commands in Termux.
 *   tmux               Sessions started from the app run in a tmux session.
 *   guard              Restarts the supervisor when it dies (no service
 *                      manager on Android).
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import type { DoctorCheck } from "./doctor.js";
import {
  MOVE_LEGACY_BOOT_BACKUPS,
  TERMUX_BOOT_PACKAGE,
  allowExternalApps,
  findOnPath,
  isExecutable,
  legacyBootBackupsInBootDir,
  termuxBootScriptPath,
} from "./termux.js";
import { runningGuardPid } from "./daemon/guard.js";

export type TermuxBootApp = "installed" | "missing" | "unknown";

/** Outcome of one package-manager query, as `spawnSync` reports it. */
export interface CommandResult {
  status: number | null;
  stdout: string;
  stderr: string;
  error?: Error;
}

/**
 * Turns `pm list packages com.termux.boot` into a verdict. Termux targets
 * SDK 28, so it sees every package; the query itself is best-effort — Android
 * may refuse `pm` to an app ("Could not access the Package Manager"), and a
 * refusal must not be reported as "not installed".
 */
export function classifyPackageQuery(result: CommandResult, packageName: string = TERMUX_BOOT_PACKAGE): TermuxBootApp {
  if (result.error || result.status !== 0) return "unknown";
  const listed = result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.startsWith("package:"))
    .map((line) => line.slice("package:".length).trim());
  if (listed.length === 0) return "unknown";
  return listed.includes(packageName) ? "installed" : "missing";
}

/** Android user id of the calling process: uid = 10000 + appId + 100000 * user. */
export function callingAndroidUserId(uid: number | undefined = process.getuid?.()): number {
  return Math.floor((uid ?? 10000) / 100_000);
}

export interface AndroidCheckDeps {
  bootScriptPath: string;
  bootScriptExists: () => boolean;
  bootScriptExecutable: () => boolean;
  termuxBootApp: () => TermuxBootApp;
  allowExternalApps: () => boolean;
  wakeLockAvailable: () => boolean;
  /** `tmux -V` output; empty string when tmux is installed but the call
   *  failed; null when tmux is not on PATH at all. */
  tmuxVersion: () => string | null;
  /** Pid of the running guard loop, or null. */
  guardRunning: () => number | null;
  /** Old dated copies that install up to 0.10.2 left in the boot directory
   *  itself, where Termux:Boot runs them at every boot. Absent = none. */
  legacyBootBackups?: () => string[];
}

export function defaultAndroidCheckDeps(): AndroidCheckDeps {
  return {
    bootScriptPath: termuxBootScriptPath(),
    bootScriptExists: () => existsSync(termuxBootScriptPath()),
    bootScriptExecutable: () => isExecutable(termuxBootScriptPath()),
    termuxBootApp: () => {
      const res = spawnSync(
        "/system/bin/pm",
        ["list", "packages", TERMUX_BOOT_PACKAGE, "--user", String(callingAndroidUserId())],
        { encoding: "utf8", timeout: 8000, stdio: ["ignore", "pipe", "pipe"] },
      );
      return classifyPackageQuery({
        status: res.status,
        stdout: res.stdout ?? "",
        stderr: res.stderr ?? "",
        ...(res.error ? { error: res.error } : {}),
      });
    },
    allowExternalApps: () => allowExternalApps(),
    wakeLockAvailable: () => findOnPath("termux-wake-lock") !== null,
    tmuxVersion: () => {
      if (findOnPath("tmux") === null) return null;
      const res = spawnSync("tmux", ["-V"], { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "pipe"] });
      const first = (res.stdout || "").split(/\r?\n/)[0]?.trim();
      return res.status === 0 && first ? first : "";
    },
    guardRunning: () => runningGuardPid(),
    legacyBootBackups: () => legacyBootBackupsInBootDir(),
  };
}

/** The checks, in the order they are printed. */
export function androidChecks(deps: AndroidCheckDeps): DoctorCheck[] {
  const checks: DoctorCheck[] = [];

  const script = deps.bootScriptPath;
  if (!deps.bootScriptExists()) {
    checks.push({
      name: "termux boot script",
      status: "fail",
      detail: `${script} is missing — nothing starts the supervisor after a reboot. Run: remote-pi phone-setup`,
    });
  } else if (!deps.bootScriptExecutable()) {
    checks.push({
      name: "termux boot script",
      status: "fail",
      detail: `${script} lacks the executable bit — Termux:Boot runs only executable scripts. Fix: chmod +x "${script}"`,
    });
  } else {
    const legacy = deps.legacyBootBackups?.() ?? [];
    checks.push(
      legacy.length === 0
        ? { name: "termux boot script", status: "ok", detail: `${script} (run by Termux:Boot after each reboot)` }
        : {
            name: "termux boot script",
            status: "warn",
            detail: `${script} runs after each reboot, and so do ${legacy.length} old cop${legacy.length === 1 ? "y" : "ies"} ` +
              `in its directory (${legacy.map((p) => p.split("/").pop()).join(", ")}): Termux:Boot runs every file there. Move them: ${MOVE_LEGACY_BOOT_BACKUPS}`,
          },
    );
  }

  switch (deps.termuxBootApp()) {
    case "installed":
      checks.push({ name: "termux:boot app", status: "ok", detail: "installed (make sure it was opened once — that arms it)" });
      break;
    case "missing":
      checks.push({
        name: "termux:boot app",
        status: "fail",
        detail: `not installed — Termux starts nothing after a reboot. Install Termux:Boot (F-Droid, same source as Termux) and open it once`,
      });
      break;
    default:
      checks.push({
        name: "termux:boot app",
        status: "warn",
        detail: "could not query the package manager — confirm Termux:Boot is installed and was opened once",
      });
  }

  checks.push(
    deps.wakeLockAvailable()
      ? {
          name: "termux wake lock",
          status: "ok",
          detail: "termux-wake-lock is available and taken by the boot script (its state cannot be read from inside Termux)",
        }
      : {
          name: "termux wake lock",
          status: "warn",
          detail: "termux-wake-lock not found — without the lock Android dozes Termux and the relay connections drop",
        },
  );

  checks.push(
    deps.allowExternalApps()
      ? {
          name: "allow-external-apps",
          status: "warn",
          detail: "on — any app holding Termux's run-command permission can start processes here. remote-pi itself does not need it; leave it on only for the app watchdog (plan/173 A7)",
        }
      : { name: "allow-external-apps", status: "ok", detail: "off (remote-pi talks through the relay and does not need it)" },
  );

  const tmux = deps.tmuxVersion();
  checks.push(
    tmux === null
      ? {
          name: "tmux",
          status: "fail",
          detail: "not installed — sessions started from the app run in a tmux session. Run: pkg install tmux",
        }
      : tmux
        ? { name: "tmux", status: "ok", detail: tmux }
        : {
            name: "tmux",
            status: "fail",
            detail: "installed but `tmux -V` failed — sessions started from the app run in tmux. Reinstall: pkg reinstall tmux",
          },
  );

  const guard = deps.guardRunning();
  checks.push(
    guard !== null
      ? { name: "guard", status: "ok", detail: `running (pid ${guard}) — restarts the supervisor when it is gone` }
      : {
          name: "guard",
          status: "warn",
          detail: "not running — nothing restarts the supervisor when it dies. Run: remote-pi guard start",
        },
  );

  return checks;
}
