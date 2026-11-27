/**
 * Termux (Android) host helpers — plan/173, stage A3.
 *
 * The phone is a session host like a PC, minus everything a desktop OS does
 * for us: there is no systemd, launchd or Task Scheduler, and nothing outside
 * Termux may start a process inside it. This module is the one place that
 * knows what "we are running inside Termux" means, plus the few Termux files
 * the installer, `phone-setup`, doctor and the guard all look at:
 *
 *   - `~/.termux/boot/start-piper.sh`  autostart script (written by install)
 *   - `~/.termux/termux.properties`    Termux app settings (allow-external-apps)
 *
 * Everything here is a pure function of its arguments (env, platform, home
 * directory) so the behaviour is unit-testable on a PC. Nothing in this file
 * spawns a process; callers that need `pm` or `termux-wake-lock` inject that.
 */

import { accessSync, constants, existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";

/** Android package + install prefix of the Termux app (F-Droid and GitHub
 *  builds share both). */
export const TERMUX_APP_PACKAGE = "com.termux";
export const TERMUX_PREFIX = `/data/data/${TERMUX_APP_PACKAGE}/files/usr`;

/** Package name of the Termux:Boot add-on that runs `~/.termux/boot` scripts. */
export const TERMUX_BOOT_PACKAGE = "com.termux.boot";

/** File name the boot script gets. Termux:Boot runs every file in
 *  `~/.termux/boot` in sorted order; only ours is expected there. */
export const TERMUX_BOOT_SCRIPT = "start-piper.sh";

/**
 * True inside Termux. Termux's node reports `process.platform` as
 * `"android"` on the owner's phone (0.10.0 assumed `"linux"`), so both count
 * as the OS; that alone is never enough — a plain Linux box is not Termux. At
 * least one Termux marker must be present: `TERMUX_VERSION`, a `PREFIX` under
 * the app's data dir, or the app's home directory as our own (for processes
 * whose environment was stripped, like a daemon started by a boot script).
 * A bare `PREFIX` from another tool never matches: it must point at the
 * Termux prefix.
 */
export function isTermux(
  env: NodeJS.ProcessEnv = process.env,
  platform: NodeJS.Platform = process.platform,
  home: string = homedir(),
): boolean {
  if (platform !== "linux" && platform !== "android") return false;
  const version = env["TERMUX_VERSION"];
  if (typeof version === "string" && version.trim().length > 0) return true;
  const prefix = env["PREFIX"];
  if (typeof prefix === "string" && prefix.startsWith(TERMUX_PREFIX)) return true;
  return home === `/data/data/${TERMUX_APP_PACKAGE}/files/home`;
}

/** Home directory the Piper files live under (`~` in Termux). Tests and ops
 *  may redirect it with `REMOTE_PI_HOME`, as everywhere else in the daemon. */
export function piperHome(): string {
  return process.env["REMOTE_PI_HOME"] || homedir();
}

/** `~/.termux/boot/start-piper.sh` — the autostart script `remote-pi install`
 *  writes on Android. */
export function termuxBootScriptPath(home: string = piperHome()): string {
  return join(home, ".termux", "boot", TERMUX_BOOT_SCRIPT);
}

/** `~/.termux/termux.properties` — the Termux app's own settings file. It
 *  exists only after "Propiedades" / a manual edit; absence means defaults. */
export function termuxPropertiesPath(home: string = piperHome()): string {
  return join(home, ".termux", "termux.properties");
}

/**
 * Value of one key in `termux.properties` (`key=value`, `#` comments), or
 * null when the file or the key is absent. Termux reads the file loosely:
 * whitespace around the key and value is ignored.
 */
export function readTermuxProperty(
  key: string,
  path: string = termuxPropertiesPath(),
): string | null {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return null;
  }
  for (const line of raw.split(/\r?\n/)) {
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const k = line.slice(0, eq).trim();
    if (k !== key) continue;
    const comment = line.indexOf("#", eq);
    const v = (comment >= 0 ? line.slice(eq + 1, comment) : line.slice(eq + 1)).trim();
    return v;
  }
  return null;
}

/**
 * `allow-external-apps` state. Off unless the file says `true` (Termux parses
 * the value with `Boolean.parseBoolean`, so only that word, in any case,
 * enables it). Why it matters: the setting lets other apps holding Termux's
 * run-command permission start processes inside Termux. Remote Pi does not
 * need it (the app talks through the relay), so "off" is the good state.
 */
export function allowExternalApps(path: string = termuxPropertiesPath()): boolean {
  const value = readTermuxProperty("allow-external-apps", path);
  return value !== null && value.toLowerCase() === "true";
}

/**
 * PATH for the boot script: the Termux prefix first (node, pi, tmux, the
 * `termux-*` helpers), then the caller's PATH without duplicates. Termux:Boot
 * starts scripts with a minimal PATH; without `$PREFIX/bin` neither the
 * supervisor's `pi` nor the tmux launcher would resolve.
 */
export function termuxPath(env: NodeJS.ProcessEnv = process.env): string {
  const out: string[] = [];
  // Android's PATH separator is always `:`; the function is only consulted
  // inside Termux, so it does not follow the host OS (tests run elsewhere).
  for (const dir of [`${TERMUX_PREFIX}/bin`, ...(env["PATH"] ?? "").split(":")]) {
    const d = dir.replace(/\/+$/, "");
    if (d.length > 0 && !out.includes(d)) out.push(d);
  }
  return out.join(":");
}

/** Absolute path of `name` in the first PATH entry that holds an executable
 *  of that name, or null. A PATH lookup only: nothing is executed. `sep` is
 *  the host's `path.delimiter` unless given: Android's is always `:`. */
export function findOnPath(
  name: string,
  envPath: string = process.env["PATH"] ?? "",
  sep: string = delimiter,
): string | null {
  for (const dir of envPath.split(sep)) {
    const d = dir.replace(/\/+$/, "");
    if (!d) continue;
    const candidate = join(d, name);
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      /* not here — keep looking */
    }
  }
  return null;
}

/** True when `path` exists and carries an executable bit for someone. */
export function isExecutable(path: string): boolean {
  if (!existsSync(path)) return false;
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** `YYYYMMDD-HHMMSS` in local time, for backup file names. */
export function fileStamp(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number): string => String(n).padStart(2, "0");
  return (
    `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}` +
    `-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
  );
}
