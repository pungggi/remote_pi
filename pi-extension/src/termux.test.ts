import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { chmodSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import {
  TERMUX_BOOT_PACKAGE,
  TERMUX_BOOT_SCRIPT,
  TERMUX_PREFIX,
  allowExternalApps,
  findOnPath,
  isExecutable,
  isTermux,
  readTermuxProperty,
  termuxBootScriptPath,
  termuxPath,
  termuxPropertiesPath,
} from "./termux.js";

/**
 * Plan/173 — Termux detection and the two Termux files the Android host
 * reads. Everything is a pure function of env / platform / home, so these
 * run on a desktop; nothing touches the real home directory.
 */

const termuxHome = "/data/data/com.termux/files/home";

describe("isTermux", () => {
  test("true on linux with TERMUX_VERSION (interactive Termux shell)", () => {
    expect(isTermux({ TERMUX_VERSION: "118" }, "linux", "/home/x")).toBe(true);
  });

  test("true on linux with the Termux PREFIX, even without TERMUX_VERSION", () => {
    expect(isTermux({ PREFIX: TERMUX_PREFIX }, "linux", termuxHome)).toBe(true);
  });

  test("true when only the home directory is Termux's (stripped environment)", () => {
    expect(isTermux({}, "linux", termuxHome)).toBe(true);
  });

  test("false for a foreign PREFIX, a bare linux box, and every other OS", () => {
    expect(isTermux({ PREFIX: "/usr" }, "linux", "/home/x")).toBe(false);
    expect(isTermux({}, "linux", "/home/x")).toBe(false);
    expect(isTermux({ TERMUX_VERSION: "118", PREFIX: TERMUX_PREFIX }, "darwin", termuxHome)).toBe(false);
    expect(isTermux({ TERMUX_VERSION: "118", PREFIX: TERMUX_PREFIX }, "win32", termuxHome)).toBe(false);
  });

  test("a blank TERMUX_VERSION is no signal", () => {
    expect(isTermux({ TERMUX_VERSION: "  " }, "linux", "/home/x")).toBe(false);
  });
});

describe("termux paths", () => {
  test("boot script and properties live under ~/.termux", () => {
    expect(termuxBootScriptPath("/home/u")).toBe(join("/home/u", ".termux", "boot", TERMUX_BOOT_SCRIPT));
    expect(TERMUX_BOOT_SCRIPT).toBe("start-piper.sh");
    expect(termuxPropertiesPath("/home/u")).toBe(join("/home/u", ".termux", "termux.properties"));
  });

  test("the Termux:Boot package name is the real one", () => {
    expect(TERMUX_BOOT_PACKAGE).toBe("com.termux.boot");
  });
});

describe("readTermuxProperty / allowExternalApps", () => {
  let dir: string;
  let file: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "pi-termux-"));
    file = join(dir, "termux.properties");
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("missing file and missing key answer null", () => {
    expect(readTermuxProperty("allow-external-apps", file)).toBeNull();
    writeFileSync(file, "extra-styles = true\n");
    expect(readTermuxProperty("allow-external-apps", file)).toBeNull();
  });

  test("reads key=value, trims, ignores comments and survives CRLF", () => {
    writeFileSync(file, "# allow-external-apps = true (commented out)\r\n  allow-external-apps = true # on\r\nextra-styles=false\r\n");
    expect(readTermuxProperty("allow-external-apps", file)).toBe("true");
    expect(readTermuxProperty("extra-styles", file)).toBe("false");
  });

  test("allow-external-apps is off unless the value is the word true", () => {
    expect(allowExternalApps(file)).toBe(false);
    writeFileSync(file, "allow-external-apps=false\n");
    expect(allowExternalApps(file)).toBe(false);
    writeFileSync(file, "allow-external-apps=TRUE\n");
    expect(allowExternalApps(file)).toBe(true);
  });
});

describe("termuxPath", () => {
  test("puts the Termux prefix first and drops duplicates and empty entries", () => {
    const out = termuxPath({ PATH: `${TERMUX_PREFIX}/bin/:/system/bin::/system/bin:/data/data/com.termux/files/usr/bin` });
    expect(out).toBe(`${TERMUX_PREFIX}/bin:/system/bin`);
  });

  test("falls back to the prefix alone when PATH is unset", () => {
    expect(termuxPath({})).toBe(`${TERMUX_PREFIX}/bin`);
  });
});

describe("findOnPath / isExecutable", () => {
  let dir: string;
  let bin: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "pi-termux-bin-"));
    bin = join(dir, "bin");
    mkdirSync(bin);
    writeFileSync(join(bin, "termux-wake-lock"), "#!/bin/sh\n");
    writeFileSync(join(bin, "plain.txt"), "not a program\n");
    chmodSync(join(bin, "termux-wake-lock"), 0o755);
    chmodSync(join(bin, "plain.txt"), 0o644);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("resolves the first executable match and nothing for a missing name", () => {
    const found = findOnPath("termux-wake-lock", `${join(dir, "missing")}${delimiter}${bin}`);
    expect(found).toBe(join(bin, "termux-wake-lock"));
    expect(findOnPath("nope", bin)).toBeNull();
    expect(findOnPath("nope", "")).toBeNull();
  });

  test("isExecutable: the bit matters on POSIX", () => {
    expect(isExecutable(join(bin, "termux-wake-lock"))).toBe(true);
    expect(isExecutable(join(bin, "missing"))).toBe(false);
    if (process.platform !== "win32") {
      // Windows reports every existing file as executable; POSIX honours the bit.
      expect(isExecutable(join(bin, "plain.txt"))).toBe(false);
    }
  });
});
