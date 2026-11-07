import { beforeEach, afterEach, describe, expect, test } from "vitest";
import { mkdtempSync, rmSync, existsSync, readFileSync, writeFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  appendDaemonLog,
  clearDeadMarker,
  daemonLogPath,
  deadMarkerPath,
  readDeadMarker,
  writeDeadMarker,
  DAEMON_LOG_KEEP_BYTES,
} from "./diagnostics.js";

/** Scratch REMOTE_PI_HOME so tests never touch the real ~/.pi. */
let testHome: string;

beforeEach(() => {
  testHome = mkdtempSync(join(tmpdir(), "pi-diag-"));
  process.env["REMOTE_PI_HOME"] = testHome;
});

afterEach(() => {
  delete process.env["REMOTE_PI_HOME"];
  try { rmSync(testHome, { recursive: true, force: true }); } catch { /* best-effort */ }
});

describe("diagnostics — per-daemon log", () => {
  test("appends timestamped chunks and creates the dir on demand", () => {
    appendDaemonLog("abc12345", "child exploded\n");
    appendDaemonLog("abc12345", "second line\n");
    const path = daemonLogPath("abc12345");
    expect(existsSync(path)).toBe(true);
    const content = readFileSync(path, "utf8");
    expect(content).toContain("child exploded");
    expect(content).toContain("second line");
    // Every chunk is prefixed with an ISO timestamp.
    const lines = content.trim().split("\n");
    expect(lines.length).toBe(2);
    expect(lines[0]).toMatch(/^\[\d{4}-\d{2}-\d{2}T/);
  });

  test("never throws when the payload is garbage-ish", () => {
    expect(() => appendDaemonLog("x", "\u0000\u0001")).not.toThrow();
  });

  test("caps the log at the max size keeping the tail", () => {
    const path = daemonLogPath("big00001");
    // First append creates the directory; then overwrite with a file past
    // the cap carrying a recognizable tail.
    appendDaemonLog("big00001", "seed\n");
    const filler = "x".repeat(6 * 1024 * 1024);
    writeFileSync(path, filler + "TAIL_MARKER");
    appendDaemonLog("big00001", "new line\n");
    const size = statSync(path).size;
    expect(size).toBeLessThanOrEqual(DAEMON_LOG_KEEP_BYTES + 4096);
    const content = readFileSync(path, "utf8");
    expect(content).toContain("TAIL_MARKER");
    expect(content).toContain("new line");
  });
});

describe("diagnostics — crash-loop marker", () => {
  test("round-trips and clears", () => {
    expect(readDeadMarker("dev01")).toBeNull();
    writeDeadMarker("dev01", { at: "2026-11-07T00:00:00Z", exit_code: 1, attempt: 4 });
    expect(existsSync(deadMarkerPath("dev01"))).toBe(true);
    expect(readDeadMarker("dev01")).toEqual({ at: "2026-11-07T00:00:00Z", exit_code: 1, attempt: 4 });
    clearDeadMarker("dev01");
    expect(readDeadMarker("dev01")).toBeNull();
  });

  test("clearing a missing marker is a no-op", () => {
    expect(() => clearDeadMarker("ghost")).not.toThrow();
  });

  test("corrupt marker reads as null", () => {
    writeDeadMarker("bad01", { at: "x", exit_code: 0, attempt: 0 });
    writeFileSync(deadMarkerPath("bad01"), "not json\n");
    expect(readDeadMarker("bad01")).toBeNull();
  });
});
