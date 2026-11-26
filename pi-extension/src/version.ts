/**
 * The package version, for `remote-pi --version`.
 *
 * Read from the package's own `package.json`, found relative to this module
 * (dist/version.js → ../../package.json; from src/ under the test runner the
 * same two levels up). Best-effort on purpose: an unreadable or malformed
 * file answers "0.0.0", which is still a valid semver for everything that
 * parses it.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/** `remote-pi <version>` as `--version` prints it. */
export function cliVersionLine(version: string = readPackageVersion()): string {
  return `remote-pi ${version}`;
}

/** The version in the `package.json` two levels above `moduleUrl`, or
 *  "0.0.0" when there is none or it is not a non-empty string. */
export function readPackageVersion(moduleUrl: string = import.meta.url): string {
  try {
    const pkgPath = join(fileURLToPath(moduleUrl), "..", "..", "package.json");
    const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as { version?: unknown };
    return typeof pkg.version === "string" && pkg.version.trim().length > 0 ? pkg.version : "0.0.0";
  } catch {
    return "0.0.0";
  }
}

/** The two spellings `remote-pi` answers without loading the runtime. */
export function isVersionFlag(arg: string | undefined): boolean {
  return arg === "--version" || arg === "-v";
}
