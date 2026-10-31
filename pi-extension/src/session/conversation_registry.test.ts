import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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
  maybeWakeIdleConversationForInbox,
  readConversationRecord,
  resolveAgentApiInvocation,
  writeConversationRecord,
} from "./conversation_registry.js";
import { readUnreadInboxStates, writeInboxState } from "../mcp/inbox_state.js";

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

  test("resolveAgentApiInvocation uses agentapi subcommand for agy.exe and language_server binaries in ANTIGRAVITY_AGENTAPI_EXE", () => {
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

    const customLanguageServerExe = resolveAgentApiInvocation(
      "conv-1",
      "hello",
      { ANTIGRAVITY_AGENTAPI_EXE: "/opt/antigravity/language_server_linux_x64" },
      "linux",
    );
    expect(customLanguageServerExe.file).toBe("/opt/antigravity/language_server_linux_x64");
    expect(customLanguageServerExe.args).toEqual(["agentapi", "send-message", "conv-1", "hello"]);

    const customStandalone = resolveAgentApiInvocation(
      "conv-1",
      "hello",
      { ANTIGRAVITY_AGENTAPI_EXE: "/usr/local/bin/agentapi-mock" },
      "linux",
    );
    expect(customStandalone.file).toBe("/usr/local/bin/agentapi-mock");
    expect(customStandalone.args).toEqual(["send-message", "conv-1", "hello"]);
  });

  test("maybeWakeIdleConversationForInbox records pendingWake while agentapi runs, commits lastWokenKey on success, and recovers from dead pendingWake PIDs", () => {
    const workspace = join(tempHome, "claim-workspace");
    const convId = "conv-claim-1";
    // Seed a stale pendingWake from a dead PID (999_999_999) to verify crash recovery
    const convPath = writeConversationRecord({
      conversationId: convId,
      workspacePath: workspace,
      hostPid: process.pid,
      state: "idle",
      pendingWake: {
        key: buildWakeDedupKey(convId, "m-claim", 1),
        pid: 999_999_999,
        claimedAt: Date.now(),
      },
    });

    writeInboxState({
      cwd: workspace,
      name: "agy",
      address: `${workspace}@agy`,
      ppid: process.pid,
      messages: [
        {
          id: "m-claim",
          from: `${workspace}@pi`,
          body: "hello",
          re: null,
          at: "2026-10-31T18:00:00.000Z",
        },
      ],
    });
    const inboxRec = readUnreadInboxStates([workspace])[0]!;

    // Mock script that verifies pendingWake is active on disk while agentapi
    // is running AND simulates PreInvocation transitioning state to "busy".
    const verifyLogPath = join(tempHome, "in-flight-check.json");
    const mockScript = join(tempHome, "agentapi-inflight.mjs");
    writeFileSync(
      mockScript,
      `import { readFileSync, writeFileSync } from "node:fs";
const current = JSON.parse(readFileSync(${JSON.stringify(convPath)}, "utf8"));
writeFileSync(${JSON.stringify(verifyLogPath)}, JSON.stringify(current), "utf8");
current.state = "busy";
writeFileSync(${JSON.stringify(convPath)}, JSON.stringify(current, null, 2), "utf8");
`,
      "utf8",
    );

    const woken = maybeWakeIdleConversationForInbox(inboxRec, {
      ...process.env,
      REMOTE_PI_HOME: tempHome,
      ANTIGRAVITY_AGENTAPI_EXE: mockScript,
    });
    expect(woken).toBe(true);

    // 1. While mockScript was running, pendingWake was active on disk with this process's PID
    const inFlightRecord = JSON.parse(readFileSync(verifyLogPath, "utf8")) as {
      pendingWake: { key: string; pid: number } | null;
      lastWokenKey: string | null;
    };
    expect(inFlightRecord.pendingWake?.key).toBe(buildWakeDedupKey(convId, "m-claim", 1));
    expect(inFlightRecord.pendingWake?.pid).toBe(process.pid);
    expect(inFlightRecord.lastWokenKey).toBeNull();

    // 2. After maybeWakeIdleConversationForInbox returned, lastWokenKey is committed,
    // pendingWake is cleared, and the "busy" state written during execution is preserved.
    const afterRec = readConversationRecord(convId);
    expect(afterRec?.state).toBe("busy");
    expect(afterRec?.lastWokenKey).toBe(buildWakeDedupKey(convId, "m-claim", 1));
    expect(afterRec?.pendingWake).toBeNull();
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
