import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  formatBodyPreview,
  readUnreadInboxStates,
  removeInboxState,
  writeInboxState,
} from "./inbox_state.js";

describe("inbox_state", () => {
  let tempHome = "";
  const prevHome = process.env["REMOTE_PI_HOME"];

  beforeEach(() => {
    tempHome = mkdtempSync(join(tmpdir(), "remote-pi-inbox-test-"));
    process.env["REMOTE_PI_HOME"] = tempHome;
  });

  afterEach(() => {
    if (prevHome === undefined) delete process.env["REMOTE_PI_HOME"];
    else process.env["REMOTE_PI_HOME"] = prevHome;
    try {
      rmSync(tempHome, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors on Windows.
    }
  });

  test("writes unread state, matches workspace, and clears when drained", () => {
    const cwd = join(tempHome, "workspace-a");
    const statePath = writeInboxState({
      cwd,
      name: "agy",
      address: `${cwd}@agy`,
      messages: [
        {
          id: "msg-1",
          from: `${cwd}@pi`,
          body: { task: "run tests" },
          re: null,
          at: "2026-10-31T18:00:00.000Z",
        },
      ],
    });

    expect(existsSync(statePath)).toBe(true);

    const matching = readUnreadInboxStates([cwd]);
    expect(matching).toHaveLength(1);
    expect(matching[0]?.unreadCount).toBe(1);
    expect(matching[0]?.address).toBe(`${cwd}@agy`);
    expect(matching[0]?.preview[0]?.from).toBe(`${cwd}@pi`);

    const nonMatching = readUnreadInboxStates([join(tempHome, "other-workspace")]);
    expect(nonMatching).toHaveLength(0);

    // Draining inbox (empty messages) hides it from unread states
    writeInboxState({
      cwd,
      name: "agy",
      address: `${cwd}@agy`,
      messages: [],
    });
    expect(readUnreadInboxStates([cwd])).toHaveLength(0);

    removeInboxState(statePath);
    expect(existsSync(statePath)).toBe(false);
  });

  test("unlinks stale state files from dead PIDs", () => {
    const cwd = join(tempHome, "workspace-stale");
    const statePath = writeInboxState({
      cwd,
      name: "agy",
      address: `${cwd}@agy`,
      pid: 999_999_999,
      messages: [
        {
          id: "msg-stale",
          from: `${cwd}@pi`,
          body: "hello",
          re: null,
          at: "2026-10-31T18:00:00.000Z",
        },
      ],
    });

    expect(existsSync(statePath)).toBe(true);
    const states = readUnreadInboxStates([cwd]);
    expect(states).toHaveLength(0);
    expect(existsSync(statePath)).toBe(false);
  });

  test("formatBodyPreview collapses whitespace and truncates long strings", () => {
    expect(formatBodyPreview("hello\n  world")).toBe("hello world");
    const long = "x".repeat(200);
    const preview = formatBodyPreview(long);
    expect(preview.length).toBe(120);
    expect(preview.endsWith("…")).toBe(true);
  });
});
