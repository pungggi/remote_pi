import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  MeshInbox,
  formatBodyPreview,
  readUnreadInboxStates,
  removeInboxState,
  writeInboxState,
  writeInboxStateSafe,
  type InboxMessageLike,
} from "./inbox_state.js";

function sampleMsg(overrides: Partial<InboxMessageLike> = {}): InboxMessageLike {
  return {
    id: overrides.id ?? "msg-1",
    from: overrides.from ?? "/repo@pi",
    body: overrides.body ?? "hello",
    re: overrides.re ?? null,
    at: overrides.at ?? "2026-10-31T18:00:00.000Z",
  };
}

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

  test("writes unread state, matches workspace, tracks lastMessageId beyond 5 preview items, and clears when drained", () => {
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
    expect(matching[0]?.lastMessageId).toBe("msg-1");
    expect(matching[0]?.address).toBe(`${cwd}@agy`);
    expect(matching[0]?.preview[0]?.from).toBe(`${cwd}@pi`);

    // 6 messages: preview is capped at 5, but lastMessageId reflects the 6th message ("msg-6")
    writeInboxState({
      cwd,
      name: "agy",
      address: `${cwd}@agy`,
      messages: [1, 2, 3, 4, 5, 6].map((n) => sampleMsg({ id: `msg-${n}` })),
    });
    const sixStates = readUnreadInboxStates([cwd]);
    expect(sixStates[0]?.preview).toHaveLength(5);
    expect(sixStates[0]?.lastMessageId).toBe("msg-6");

    const nonMatching = readUnreadInboxStates([join(tempHome, "other-workspace")]);
    expect(nonMatching).toHaveLength(0);

    // Draining inbox (empty messages) hides it from unread states and sets lastMessageId to null
    writeInboxState({
      cwd,
      name: "agy",
      address: `${cwd}@agy`,
      messages: [],
    });
    expect(readUnreadInboxStates([cwd])).toHaveLength(0);
    const drainedRaw = JSON.parse(readFileSync(statePath, "utf8")) as {
      lastMessageId: string | null;
    };
    expect(drainedRaw.lastMessageId).toBeNull();

    removeInboxState(statePath);
    expect(existsSync(statePath)).toBe(false);
  });

  test("parent and child workspaces do not match each other", () => {
    // Parent and child folders are distinct agents — a prefix match would leak
    // a child workspace's inbox into the parent's view (and vice versa).
    const parent = join(tempHome, "parent-ws");
    const child = join(parent, "child");
    writeInboxState({
      cwd: parent,
      name: "agy",
      address: `${parent}@agy`,
      messages: [sampleMsg({ id: "parent-msg" })],
    });
    writeInboxState({
      cwd: child,
      name: "agy",
      address: `${child}@agy`,
      messages: [sampleMsg({ id: "child-msg" })],
    });

    expect(readUnreadInboxStates([parent]).map((s) => s.cwd)).toEqual([parent]);
    expect(readUnreadInboxStates([child]).map((s) => s.cwd)).toEqual([child]);
    expect(readUnreadInboxStates([parent]).map((s) => s.unreadCount)).toEqual([1]);
    expect(readUnreadInboxStates([child]).map((s) => s.unreadCount)).toEqual([1]);
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

  test("writeInboxState records the writer's parent PID for session ownership", () => {
    const cwd = join(tempHome, "workspace-ppid");
    const statePath = writeInboxState({
      cwd,
      name: "agy",
      address: `${cwd}@agy`,
      messages: [sampleMsg()],
    });
    const record = JSON.parse(readFileSync(statePath, "utf8")) as {
      ppid?: number;
    };
    expect(record.ppid).toBe(process.ppid);
  });

  test("writeInboxStateSafe returns null instead of throwing when the state dir is unwritable", () => {
    // Make `$REMOTE_PI_HOME/.pi` a plain file so mkdirSync cannot create it.
    writeFileSync(join(tempHome, ".pi"), "not a directory", "utf8");
    const res = writeInboxStateSafe({
      cwd: join(tempHome, "ws"),
      name: "agy",
      address: "ws@agy",
      messages: [],
    });
    expect(res).toBeNull();
  });

  describe("waitForMessage abort signal", () => {
    test("abort while pending removes the waiter so later messages reach get_messages", async () => {
      const inbox = new MeshInbox();
      const controller = new AbortController();

      const wait = inbox.waitForMessage({
        re: "req-1",
        timeoutMs: 5_000,
        signal: controller.signal,
      });
      controller.abort();

      const res = await wait;
      expect(res.status).toBe("aborted");

      // A message arriving after cancellation must NOT be eaten by the dead
      // waiter — it has to stay visible to get_messages and future waits.
      inbox.push(sampleMsg({ id: "late", re: "req-1" }));
      expect(inbox.count()).toBe(1);
      expect(inbox.drainAll().map((m) => m.id)).toEqual(["late"]);
    });

    test("abort after the waiter consumed a message requeues it", async () => {
      const inbox = new MeshInbox();
      const controller = new AbortController();

      const wait = inbox.waitForMessage({
        re: "req-2",
        timeoutMs: 5_000,
        signal: controller.signal,
      });
      inbox.push(sampleMsg({ id: "early", re: "req-2" }));

      const res = await wait;
      expect(res.status).toBe("received");

      // Client cancels between our resolution and the SDK sending the
      // response: the SDK discards the response, so the message must go back.
      controller.abort();
      expect(inbox.count()).toBe(1);
      expect(inbox.drainAll().map((m) => m.id)).toEqual(["early"]);
    });

    test("an already-aborted signal returns aborted without draining buffered messages", async () => {
      const inbox = new MeshInbox();
      const controller = new AbortController();
      inbox.push(sampleMsg({ id: "buffered", re: "req-3" }));
      controller.abort();

      const res = await inbox.waitForMessage({ re: "req-3", signal: controller.signal });
      expect(res.status).toBe("aborted");
      expect(inbox.count()).toBe(1);
    });
  });
});
