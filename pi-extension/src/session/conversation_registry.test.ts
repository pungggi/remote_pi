import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import {
  buildWakeDedupKey,
  buildWakeNotificationMessage,
  conversationFilePath,
  findConversationForInbox,
  listLiveConversations,
  markConversationWoken,
  readConversationRecord,
  resolveAgentApiInvocation,
  writeConversationRecord,
} from "./conversation_registry.js";

describe("conversation_registry", () => {
  let tempHome = "";
  const prevHome = process.env["REMOTE_PI_HOME"];

  beforeEach(() => {
    tempHome = mkdtempSync(join(tmpdir(), "remote-pi-conv-reg-test-"));
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

  test("writes, reads, preserves woken state across busy/idle transitions, and prunes dead PIDs", () => {
    const workspace = join(tempHome, "repo-a");
    const convId = "f550dfa1-9420-40f1-a017-7f69b94ccaef";

    const filePath = writeConversationRecord({
      conversationId: convId,
      workspacePath: workspace,
      hostPid: process.pid,
      state: "busy",
    });
    expect(existsSync(filePath)).toBe(true);

    const busyRec = readConversationRecord(convId);
    expect(busyRec?.conversationId).toBe(convId);
    expect(busyRec?.hostPid).toBe(process.pid);
    expect(busyRec?.state).toBe("busy");

    // Mark woken for m-1
    markConversationWoken(convId, "m-1", 1);
    const wokenRec = readConversationRecord(convId);
    expect(wokenRec?.lastWokenMessageId).toBe("m-1");
    expect(wokenRec?.lastWokenKey).toBe(buildWakeDedupKey(convId, "m-1", 1));

    // Transitioning state to idle without specifying lastWokenMessageId preserves it
    writeConversationRecord({
      conversationId: convId,
      workspacePath: workspace,
      hostPid: process.pid,
      state: "idle",
    });
    const idleRec = readConversationRecord(convId);
    expect(idleRec?.state).toBe("idle");
    expect(idleRec?.lastWokenMessageId).toBe("m-1");
    expect(idleRec?.lastWokenKey).toBe(buildWakeDedupKey(convId, "m-1", 1));

    // Dead PID record is automatically pruned on listLiveConversations / readConversationRecord
    const deadPath = writeConversationRecord({
      conversationId: "dead-conv",
      workspacePath: workspace,
      hostPid: 999_999_999,
      state: "idle",
    });
    expect(existsSync(deadPath)).toBe(true);
    expect(readConversationRecord("dead-conv")).toBeNull();
    expect(existsSync(deadPath)).toBe(false);
    expect(listLiveConversations().map((c) => c.conversationId)).toEqual([convId]);
  });

  test("correlates inboxes to conversations by (workspacePath, hostPid) across coexisting agents", () => {
    const workspace = join(tempHome, "shared-workspace");

    // Spawn a real second host process to simulate a sibling session (`agy#2` or `claude`)
    const siblingHost = spawn(process.execPath, ["-e", "setTimeout(() => {}, 30000)"], {
      stdio: "ignore",
    });
    siblingHost.unref();

    try {
      writeConversationRecord({
        conversationId: "conv-agy-1",
        workspacePath: workspace,
        hostPid: process.pid,
        state: "idle",
      });
      writeConversationRecord({
        conversationId: "conv-agy-2",
        workspacePath: workspace,
        hostPid: siblingHost.pid!,
        state: "idle",
      });

      // Inbox for agy-1 matches conv-agy-1
      const match1 = findConversationForInbox({
        cwd: workspace,
        ppid: process.pid,
        name: "agy",
      });
      expect(match1?.conversationId).toBe("conv-agy-1");

      // Inbox for agy#2 matches conv-agy-2
      const match2 = findConversationForInbox({
        cwd: workspace,
        ppid: siblingHost.pid!,
        name: "agy#2",
      });
      expect(match2?.conversationId).toBe("conv-agy-2");

      // Inbox for a Claude session in the same workspace (different ppid) does NOT match either agy conversation
      const claudeMatch = findConversationForInbox({
        cwd: workspace,
        ppid: 888_888_888,
        name: "claude",
      });
      expect(claudeMatch).toBeNull();
    } finally {
      siblingHost.kill();
    }
  });

  test("resolveAgentApiInvocation uses agy.exe agentapi subcommand on Windows and respects ANTIGRAVITY_AGENTAPI_EXE", () => {
    const winDefault = resolveAgentApiInvocation("conv-1", "hello & calc.exe", {}, "win32");
    expect(winDefault.file).toBe("agy.exe");
    expect(winDefault.args).toEqual(["agentapi", "send-message", "conv-1", "hello & calc.exe"]);

    const posixDefault = resolveAgentApiInvocation("conv-1", "hello", {}, "linux");
    expect(posixDefault.file).toBe("agentapi");
    expect(posixDefault.args).toEqual(["send-message", "conv-1", "hello"]);

    const customAgyExe = resolveAgentApiInvocation(
      "conv-1",
      "hello",
      { ANTIGRAVITY_AGENTAPI_EXE: "C:\\Program Files\\Antigravity\\agy.exe" },
      "win32",
    );
    expect(customAgyExe.file).toBe("C:\\Program Files\\Antigravity\\agy.exe");
    expect(customAgyExe.args).toEqual(["agentapi", "send-message", "conv-1", "hello"]);

    const customStandalone = resolveAgentApiInvocation(
      "conv-1",
      "hello",
      { ANTIGRAVITY_AGENTAPI_EXE: "/usr/local/bin/agentapi-mock" },
      "linux",
    );
    expect(customStandalone.file).toBe("/usr/local/bin/agentapi-mock");
    expect(customStandalone.args).toEqual(["send-message", "conv-1", "hello"]);
  });

  test("buildWakeNotificationMessage formats sender and preview details", () => {
    const msg = buildWakeNotificationMessage({
      unreadCount: 2,
      preview: [
        {
          id: "m-1",
          from: "/repo@pi",
          re: null,
          at: "2026-10-31T18:00:00.000Z",
          bodyPreview: '{"event":"pr-merged"}',
        },
      ],
    });
    expect(msg).toContain("2 unread mesh message(s) arrived from /repo@pi");
    expect(msg).toContain('[from /repo@pi]: {"event":"pr-merged"}');
    expect(msg).toContain("get_messages");
  });

  test("conversationFilePath sanitizes unsafe characters", () => {
    const p = conversationFilePath("../evil/id");
    expect(p).not.toContain("..");
  });
});
