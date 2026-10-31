import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { acquireNamedCwdLock, type NamedAcquiredLock } from "../session/cwd_lock.js";
import { MeshInbox, formatIncomingMessages, type InboxMessageLike } from "./inbox_state.js";

function sampleMsg(overrides: Partial<InboxMessageLike> = {}): InboxMessageLike {
  return {
    id: overrides.id ?? "msg-1",
    from: overrides.from ?? "/repo@pi",
    body: overrides.body ?? "hello from pi",
    re: overrides.re ?? null,
    at: overrides.at ?? "2026-10-31T18:00:00.000Z",
  };
}

describe("acquireNamedCwdLock", () => {
  let tempHome = "";
  const prevHome = process.env["REMOTE_PI_HOME"];
  const heldLocks: NamedAcquiredLock[] = [];

  beforeEach(() => {
    tempHome = mkdtempSync(join(tmpdir(), "remote-pi-lock-test-"));
    process.env["REMOTE_PI_HOME"] = tempHome;
  });

  afterEach(() => {
    while (heldLocks.length > 0) {
      heldLocks.pop()?.release();
    }
    if (prevHome === undefined) delete process.env["REMOTE_PI_HOME"];
    else process.env["REMOTE_PI_HOME"] = prevHome;
    try {
      rmSync(tempHome, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors on Windows.
    }
  });

  test("coexists in same folder across pi, agy, and multiple agy instances via #N suffixing", async () => {
    const cwd = join(tempHome, "project");

    const piLock = await acquireNamedCwdLock(cwd, "project");
    expect(piLock.ok).toBe(true);
    if (piLock.ok) {
      heldLocks.push(piLock);
      expect(piLock.lockedName).toBe("project");
    }

    // Agy in the same folder with base name "agy" does not collide with "project"
    const agyLock1 = await acquireNamedCwdLock(cwd, "agy");
    expect(agyLock1.ok).toBe(true);
    if (agyLock1.ok) {
      heldLocks.push(agyLock1);
      expect(agyLock1.lockedName).toBe("agy");
    }

    // Second Agy in the same folder auto-suffixes to "agy#2"
    const agyLock2 = await acquireNamedCwdLock(cwd, "agy");
    expect(agyLock2.ok).toBe(true);
    if (agyLock2.ok) {
      heldLocks.push(agyLock2);
      expect(agyLock2.lockedName).toBe("agy#2");
    }

    // Claude in the same folder requesting default "project" auto-suffixes to "project#2"
    const claudeLock = await acquireNamedCwdLock(cwd, "project");
    expect(claudeLock.ok).toBe(true);
    if (claudeLock.ok) {
      heldLocks.push(claudeLock);
      expect(claudeLock.lockedName).toBe("project#2");
    }
  });
});

describe("MeshInbox", () => {
  test("waitForMessage resolves immediately if matching message is already buffered", async () => {
    const counts: number[] = [];
    const inbox = new MeshInbox((msgs) => counts.push(msgs.length));

    inbox.push(sampleMsg({ id: "m1", from: "/repo@pi", re: "req-1" }));
    inbox.push(sampleMsg({ id: "m2", from: "/repo@claude", re: "req-2" }));
    expect(inbox.count()).toBe(2);

    const res = await inbox.waitForMessage({ from: "/repo@claude", re: "req-2", timeoutMs: 500 });
    expect(res.status).toBe("received");
    expect(res.messages).toHaveLength(1);
    expect(res.messages[0]?.id).toBe("m2");

    // Non-matching message remains in inbox
    expect(inbox.count()).toBe(1);
    const remaining = inbox.drainAll();
    expect(remaining).toHaveLength(1);
    expect(remaining[0]?.id).toBe("m1");
    expect(counts.at(-1)).toBe(0);
  });

  test("waitForMessage wakes up as soon as matching message arrives", async () => {
    const inbox = new MeshInbox();
    const waitPromise = inbox.waitForMessage({ re: "req-99", timeoutMs: 5_000 });

    setTimeout(() => {
      inbox.push(sampleMsg({ id: "reply-99", from: "/repo@pi", re: "req-99", body: { ok: true } }));
    }, 20);

    const res = await waitPromise;
    expect(res.status).toBe("received");
    expect(res.messages).toHaveLength(1);
    expect(res.messages[0]?.id).toBe("reply-99");
    expect(inbox.count()).toBe(0);
  });

  test("waitForMessage times out cleanly when no matching message arrives", async () => {
    const inbox = new MeshInbox();
    const res = await inbox.waitForMessage({ timeoutMs: 60 });
    expect(res.status).toBe("timeout");
    expect(res.messages).toHaveLength(0);
  });

  test("formatIncomingMessages renders empty and populated lists", () => {
    expect(formatIncomingMessages([])).toBe("(no messages)");
    const text = formatIncomingMessages([
      sampleMsg({ id: "m1", from: "/repo@pi", re: "r0", body: { hello: "agy" } }),
    ]);
    expect(text).toContain("from=/repo@pi re=r0");
    expect(text).toContain("id=m1");
    expect(text).toContain('"hello": "agy"');
  });
});
