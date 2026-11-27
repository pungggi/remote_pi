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
 *
 * The phone's node reports `process.platform` as `"android"` (found
 * 2026-11-26: 0.10.0 required `"linux"`, so every Termux check on the real
 * device said no and `guard run` refused to start). Every marker below is
 * therefore proven on BOTH platforms.
 */

const termuxHome = "/data/data/com.termux/files/home";

/** The two platforms Termux's node may report. */
const TERMUX_PLATFORMS: NodeJS.Platform[] = ["linux", "android"];

describe("isTermux", () => {
  test("true with TERMUX_VERSION (interactive Termux shell), on either platform", () => {
    for (const platform of TERMUX_PLATFORMS) {
      expect(isTermux({ TERMUX_VERSION: "118" }, platform, "/home/x")).toBe(true);
    }
  });

  test("true with the Termux PREFIX, even without TERMUX_VERSION, on either platform", () => {
    for (const platform of TERMUX_PLATFORMS) {
      expect(isTermux({ PREFIX: TERMUX_PREFIX }, platform, termuxHome)).toBe(true);
      expect(isTermux({ PREFIX: TERMUX_PREFIX }, platform, "/home/x")).toBe(true);
    }
  });

  test("true when only the home directory is Termux's (stripped environment), on either platform", () => {
    for (const platform of TERMUX_PLATFORMS) {
      expect(isTermux({}, platform, termuxHome)).toBe(true);
    }
  });

  test("the platform alone is never enough: android or linux without a marker is not Termux", () => {
    for (const platform of TERMUX_PLATFORMS) {
      expect(isTermux({}, platform, "/home/x")).toBe(false);
      expect(isTermux({ PREFIX: "/usr" }, platform, "/home/x")).toBe(false);
      expect(isTermux({ PREFIX: "/data/data/com.other.app/files/usr" }, platform, "/home/x")).toBe(false);
    }
  });

  test("every marker is false on every other OS", () => {
    for (const platform of ["darwin", "win32", "freebsd"] as NodeJS.Platform[]) {
      expect(isTermux({ TERMUX_VERSION: "118", PREFIX: TERMUX_PREFIX }, platform, termuxHome)).toBe(false);
    }
  });

  test("a blank TERMUX_VERSION is no signal", () => {
    for (const platform of TERMUX_PLATFORMS) {
      expect(isTermux({ TERMUX_VERSION: "  " }, platform, "/home/x")).toBe(false);
    }
  });

  test("the real phone: `android`, TERMUX_VERSION and PREFIX set, the app's home", () => {
    expect(
      isTermux({ TERMUX_VERSION: "102", PREFIX: `${TERMUX_PREFIX}/`, HOME: termuxHome }, "android", termuxHome),
    ).toBe(true);
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

  // A Windows path carries a drive colon; an Android PATH never does.
  test.skipIf(process.platform === "win32")("the separator can be given: Android's PATH is `:`-separated wherever the test runs", () => {
    // `delimiter` is `;` on Windows; a Termux PATH must still split on `:`.
    expect(findOnPath("termux-wake-lock", `${join(dir, "missing")}:${bin}`, ":")).toBe(join(bin, "termux-wake-lock"));
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
