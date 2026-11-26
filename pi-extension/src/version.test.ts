/**
 * `remote-pi --version` / `-v` (0.10.1). 0.10.0 printed the usage: the thin
 * CLI entry knew only `guard` and loaded the runtime for everything else,
 * whose `runCli` has no branch for the flag.
 */
import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { cliVersionLine, isVersionFlag, readPackageVersion } from "./version.js";

describe("remote-pi --version", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "pi-version-"));
    mkdirSync(join(dir, "dist"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  /** The URL of a module at `<dir>/dist/index.js`, as `import.meta.url` would be. */
  const moduleUrl = (): string => pathToFileURL(join(dir, "dist", "index.js")).href;

  test("reads package.json two levels above the module (dist/x.js → package.json)", () => {
    writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "remote-pi", version: "0.10.1" }));
    expect(readPackageVersion(moduleUrl())).toBe("0.10.1");
  });

  test("missing, malformed or versionless package.json answers 0.0.0, still a valid semver", () => {
    expect(readPackageVersion(moduleUrl())).toBe("0.0.0");
    writeFileSync(join(dir, "package.json"), "{ not json");
    expect(readPackageVersion(moduleUrl())).toBe("0.0.0");
    for (const version of [42, "", "  ", null]) {
      writeFileSync(join(dir, "package.json"), JSON.stringify({ version }));
      expect(readPackageVersion(moduleUrl())).toBe("0.0.0");
    }
    expect(readPackageVersion("file:///nowhere/dist/index.js")).toBe("0.0.0");
  });

  test("this package's own version is found from this module", () => {
    const own = (JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as { version: string })
      .version;
    expect(own).toMatch(/^\d+\.\d+\.\d+/);
    expect(readPackageVersion()).toBe(own);
  });

  test("--version and -v are the flags; the line is `remote-pi <version>`", () => {
    expect(isVersionFlag("--version")).toBe(true);
    expect(isVersionFlag("-v")).toBe(true);
    for (const other of ["-V", "version", "--ver", "", undefined]) expect(isVersionFlag(other)).toBe(false);
    expect(cliVersionLine("0.10.1")).toBe("remote-pi 0.10.1");
  });

  test("the thin CLI entry answers before the runtime is imported", () => {
    // The wiring lives in the direct-run block of the entry, which no unit
    // test can execute as a module; its order is what matters and is read here.
    const source = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
    const entry = source.slice(source.indexOf("if (_isDirectRun())"));
    expect(entry.length).toBeGreaterThan(0);
    const answersAt = entry.indexOf("isVersionFlag(process.argv[2])");
    const printsAt = entry.indexOf("cliVersionLine()");
    const loadsRuntimeAt = entry.indexOf('import("./main.js")');
    expect(answersAt).toBeGreaterThan(0);
    expect(printsAt).toBeGreaterThan(answersAt);
    expect(loadsRuntimeAt).toBeGreaterThan(printsAt);
  });
});
