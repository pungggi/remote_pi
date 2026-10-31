import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import {
  AGY_MESH_PLUGIN_NAME,
  AGY_MESH_SIDECAR_KEY,
  ensureAgyMeshPluginInstalled,
  stripJsonComments,
} from "./agy_plugin.js";
import { conversationFilePath, readConversationRecord } from "./conversation_registry.js";
import { writeInboxState } from "../mcp/inbox_state.js";

describe("ensureAgyMeshPluginInstalled + mesh_hook.mjs + watcher.mjs", () => {
  let tempDir = "";
  const prevHome = process.env["REMOTE_PI_HOME"];

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "remote-pi-agy-plugin-test-"));
    process.env["REMOTE_PI_HOME"] = tempDir;
  });

  afterEach(() => {
    if (prevHome === undefined) delete process.env["REMOTE_PI_HOME"];
    else process.env["REMOTE_PI_HOME"] = prevHome;
    try {
      rmSync(tempDir, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors on Windows.
    }
  });

  test("renders full Antigravity plugin bundle, flat hooks.json, sidecars, and preserves mcp_config.json + config.json", () => {
    const configDir = join(tempDir, ".gemini", "config");
    mkdirSync(configDir, { recursive: true });
    writeFileSync(
      join(configDir, "mcp_config.json"),
      `{
  "mcpServers": {
    "ms-learn": {
      "serverUrl": "https://learn.microsoft.com/api/mcp"
    },
    // commented out server
    // "old": { "command": "python" }
  }
}`,
      "utf8",
    );
    writeFileSync(
      join(configDir, "config.json"),
      `{
  "plugins": {
    "other-plugin": { "enabled": true }
  },
  "sidecars": {
    "other-plugin/daemon": { "enabled": false }
  }
}`,
      "utf8",
    );

    const fakeServerPath = "/abs/path/to/dist/mcp/mesh_server.js";
    const paths = ensureAgyMeshPluginInstalled({
      configDir,
      meshServerPath: fakeServerPath,
    });

    expect(existsSync(paths.pluginManifestPath)).toBe(true);
    expect(existsSync(paths.mcpConfigPath)).toBe(true);
    expect(existsSync(paths.agyConfigPath)).toBe(true);
    expect(existsSync(paths.hooksConfigPath)).toBe(true);
    expect(existsSync(paths.hookScriptPath)).toBe(true);
    expect(existsSync(paths.sidecarManifestPath)).toBe(true);
    expect(existsSync(paths.sidecarScriptPath)).toBe(true);
    expect(existsSync(paths.rulesPath)).toBe(true);
    expect(existsSync(paths.skillPath)).toBe(true);

    // Verify plugin.json has no non-schema keys like "sidecars"
    const pluginManifest = JSON.parse(readFileSync(paths.pluginManifestPath, "utf8")) as Record<
      string,
      unknown
    >;
    expect(pluginManifest["name"]).toBe(AGY_MESH_PLUGIN_NAME);
    expect(pluginManifest["sidecars"]).toBeUndefined();

    // Verify sidecar.json
    const sidecarManifest = JSON.parse(readFileSync(paths.sidecarManifestPath, "utf8")) as {
      command: string;
      args: string[];
      restart_policy: string;
    };
    expect(sidecarManifest.command).toBe("node");
    expect(sidecarManifest.args).toEqual(["watcher.mjs"]);
    expect(sidecarManifest.restart_policy).toBe("always");

    const mcpJson = JSON.parse(readFileSync(paths.mcpConfigPath, "utf8")) as {
      mcpServers: {
        "ms-learn": { serverUrl: string };
        "remote-pi-mesh": { command: string; args: string[]; env: Record<string, string> };
      };
    };
    expect(mcpJson.mcpServers["ms-learn"]?.serverUrl).toBe("https://learn.microsoft.com/api/mcp");
    expect(mcpJson.mcpServers["remote-pi-mesh"].args).toEqual([fakeServerPath, "--auto-join"]);
    expect(mcpJson.mcpServers["remote-pi-mesh"].env["REMOTE_PI_MCP_NAME"]).toBe("agy");
    expect(mcpJson.mcpServers["remote-pi-mesh"].env["REMOTE_PI_MCP_AUTO_JOIN"]).toBe("1");

    // Verify config.json preserves existing entries and enables remote-pi-mesh + sidecar
    const agyConfig = JSON.parse(readFileSync(paths.agyConfigPath, "utf8")) as {
      plugins: Record<string, { enabled: boolean }>;
      sidecars: Record<string, { enabled: boolean }>;
    };
    expect(agyConfig.plugins["other-plugin"]?.enabled).toBe(true);
    expect(agyConfig.plugins[AGY_MESH_PLUGIN_NAME]?.enabled).toBe(true);
    expect(agyConfig.sidecars["other-plugin/daemon"]?.enabled).toBe(false);
    expect(agyConfig.sidecars[AGY_MESH_SIDECAR_KEY]?.enabled).toBe(true);

    // Verify Antigravity-compliant flat hooks.json format
    const hooksJson = JSON.parse(readFileSync(paths.hooksConfigPath, "utf8")) as {
      "remote-pi-mesh": {
        SessionStart: Array<{ type: string; command: string; timeout: number }>;
        PreInvocation: Array<{ type: string; command: string; timeout: number }>;
        Stop: Array<{ type: string; command: string; timeout: number }>;
      };
    };
    expect(hooksJson["remote-pi-mesh"].SessionStart).toHaveLength(1);
    expect(hooksJson["remote-pi-mesh"].SessionStart[0]?.command).toBe("node scripts/mesh_hook.mjs --event=SessionStart");
    expect(hooksJson["remote-pi-mesh"].PreInvocation).toHaveLength(1);
    expect(hooksJson["remote-pi-mesh"].PreInvocation[0]?.command).toContain(
      "--event=PreInvocation",
    );
    expect(hooksJson["remote-pi-mesh"].Stop).toHaveLength(1);
    expect(hooksJson["remote-pi-mesh"].Stop[0]?.command).toContain("--event=Stop");
  });

  test("stripJsonComments preserves URLs inside strings while stripping //, /* */, and trailing commas", () => {
    const raw = `{
      "url": "https://example.com//path/*not-comment*/",
      /* block comment */
      "enabled": true, // line comment
    }`;
    expect(JSON.parse(stripJsonComments(raw))).toEqual({
      url: "https://example.com//path/*not-comment*/",
      enabled: true,
    });
  });

  test("stripJsonComments leaves commas inside string literals untouched", () => {
    const raw = `{
      "args": ["a,b", "x,}", "y,]"],
      "cmd": "echo a,b",
      "enabled": true,
    }`;
    expect(JSON.parse(stripJsonComments(raw))).toEqual({
      args: ["a,b", "x,}", "y,]"],
      cmd: "echo a,b",
      enabled: true,
    });
  });

  test("refuses to overwrite an unparseable mcp_config.json or config.json", () => {
    const configDir = join(tempDir, ".gemini", "config");
    mkdirSync(configDir, { recursive: true });
    const configPath = join(configDir, "mcp_config.json");
    const malformed = `{ "mcpServers": { "keep": { "command": "py"; } } }`;
    writeFileSync(configPath, malformed, "utf8");

    expect(() => ensureAgyMeshPluginInstalled({ configDir })).toThrow(/refusing to overwrite/);
    expect(readFileSync(configPath, "utf8")).toBe(malformed);
  });

  test("preserves existing servers from a BOM-prefixed mcp_config.json", () => {
    const configDir = join(tempDir, ".gemini", "config");
    mkdirSync(configDir, { recursive: true });
    const configPath = join(configDir, "mcp_config.json");
    writeFileSync(
      configPath,
      "\uFEFF" +
        JSON.stringify({ mcpServers: { keep: { command: "py", args: ["a,b"] } } }, null, 2),
      "utf8",
    );

    const paths = ensureAgyMeshPluginInstalled({ configDir });
    const json = JSON.parse(readFileSync(paths.mcpConfigPath, "utf8")) as {
      mcpServers: Record<string, { args?: string[] }>;
    };
    expect(json.mcpServers["keep"]?.args).toEqual(["a,b"]);
    expect(json.mcpServers["remote-pi-mesh"]).toBeDefined();
  });

  test("mesh_hook.mjs handles real Antigravity protojson payloads (no hook_event_name), records conversation state, and injects/continues", () => {
    const configDir = join(tempDir, ".gemini", "config");
    const paths = ensureAgyMeshPluginInstalled({ configDir });
    const workspace = join(tempDir, "my-repo");
    const convId = "4f4ebc2c-d269-47e7-aeab-c1e2cc0c6feb";

    const runHook = (
      payload: Record<string, unknown>,
      cliArgs: string[] = [],
    ): Record<string, unknown> => {
      const r = spawnSync(process.execPath, [paths.hookScriptPath, ...cliArgs], {
        input: JSON.stringify(payload),
        encoding: "utf8",
        env: { ...process.env, REMOTE_PI_HOME: tempDir },
      });
      expect(r.status).toBe(0);
      return JSON.parse(r.stdout.trim()) as Record<string, unknown>;
    };

    // 1. Empty inbox + real Antigravity protojson (workspacePaths + conversationId, no hook_event_name)
    expect(
      runHook(
        { conversationId: convId, workspacePaths: [workspace], invocationNum: 1 },
        ["--event=PreInvocation"],
      ),
    ).toEqual({});
    expect(readConversationRecord(convId)?.state).toBe("busy");
    expect(readConversationRecord(convId)?.hostPid).toBe(process.pid);

    expect(
      runHook(
        {
          conversationId: convId,
          workspacePaths: [workspace],
          terminationReason: "NO_TOOL_CALL",
        },
        ["--event=Stop"],
      ),
    ).toEqual({});
    expect(readConversationRecord(convId)?.state).toBe("idle");

    // 2. Populate unread message in workspace. `ppid: process.pid` marks the
    // record as written by THIS test process, which also spawns the hook.
    writeInboxState({
      cwd: workspace,
      name: "agy",
      address: `${workspace}@agy`,
      ppid: process.pid,
      messages: [
        {
          id: "m-1",
          from: `${workspace}@pi`,
          body: "please review PR",
          re: null,
          at: "2026-10-31T18:00:00.000Z",
        },
      ],
    });

    // 3. PreInvocation injects ephemeralMessage (even without CLI flag via protojson inference!)
    const preOut = runHook({
      conversationId: convId,
      workspacePaths: [workspace],
      invocationNum: 2,
    }) as {
      injectSteps?: Array<{ ephemeralMessage: string }>;
    };
    expect(preOut.injectSteps).toHaveLength(1);
    expect(preOut.injectSteps?.[0]?.ephemeralMessage).toContain("1 unread mesh message(s)");
    expect(preOut.injectSteps?.[0]?.ephemeralMessage).toContain("get_messages");
    expect(readConversationRecord(convId)?.state).toBe("busy");

    // 4. Stop with NO_TOOL_CALL returns decision: "continue" and keeps state "busy"
    const stopOut = runHook({
      conversationId: convId,
      workspacePaths: [workspace],
      terminationReason: "NO_TOOL_CALL",
    }) as { decision?: string; reason?: string };
    expect(stopOut.decision).toBe("continue");
    expect(stopOut.reason).toContain("get_messages");
    expect(readConversationRecord(convId)?.state).toBe("busy");

    // 5. Stop with USER_CANCELLED does not force continue and transitions state to "idle"
    expect(
      runHook({
        conversationId: convId,
        workspacePaths: [workspace],
        terminationReason: "USER_CANCELLED",
      }),
    ).toEqual({});
    expect(readConversationRecord(convId)?.state).toBe("idle");
  });

  test("shell-wrapped mesh_hook.mjs records session host PID (not transient shell PID) even before MCP inbox exists", () => {
    const configDir = join(tempDir, ".gemini", "config");
    const paths = ensureAgyMeshPluginInstalled({ configDir });
    const workspace = join(tempDir, "shell-wrapped-repo");
    const convId = "conv-shell-wrapped";

    // Invoke mesh_hook.mjs through a shell (`cmd.exe /c` on Windows, `sh -c` on POSIX)
    // BEFORE any workspace inbox state file has been written.
    const cmd = `"${process.execPath}" "${paths.hookScriptPath}" --event=Stop`;
    const r = spawnSync(cmd, {
      shell: true,
      input: JSON.stringify({
        conversationId: convId,
        workspacePaths: [workspace],
        terminationReason: "NO_TOOL_CALL",
      }),
      encoding: "utf8",
      env: { ...process.env, REMOTE_PI_HOME: tempDir },
    });
    expect(r.status).toBe(0);

    // Even after the shell process has exited, the conversation record is alive
    // and its hostPid equals THIS test process (`process.pid`), not the dead shell!
    const rec = readConversationRecord(convId);
    expect(rec).not.toBeNull();
    expect(rec?.hostPid).toBe(process.pid);
    expect(rec?.state).toBe("idle");
  });

  test("watcher.mjs wakes idle conversations via ANTIGRAVITY_AGENTAPI_EXE, preserves concurrent PreInvocation busy state, skips busy ones, and deduplicates across >5 unread messages", () => {
    const configDir = join(tempDir, ".gemini", "config");
    const paths = ensureAgyMeshPluginInstalled({ configDir });
    const workspace = join(tempDir, "watcher-repo");
    const convId = "conv-watcher-1";
    const convPath = conversationFilePath(convId);

    const callsLogPath = join(tempDir, "agentapi-calls.jsonl");
    const mockAgentApiScript = join(tempDir, "language_server_mock.mjs");
    writeFileSync(
      mockAgentApiScript,
      `import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
appendFileSync(${JSON.stringify(callsLogPath)}, JSON.stringify(process.argv.slice(2)) + "\\n", "utf8");
if (process.env.SIMULATE_PREINVOCATION_BUSY === "1") {
  const rec = JSON.parse(readFileSync(${JSON.stringify(convPath)}, "utf8"));
  rec.state = "busy";
  writeFileSync(${JSON.stringify(convPath)}, JSON.stringify(rec, null, 2), "utf8");
}
`,
      "utf8",
    );

    const runHook = (payload: Record<string, unknown>, event: string) => {
      const r = spawnSync(process.execPath, [paths.hookScriptPath, `--event=${event}`], {
        input: JSON.stringify(payload),
        encoding: "utf8",
        env: { ...process.env, REMOTE_PI_HOME: tempDir },
      });
      expect(r.status).toBe(0);
    };

    const runWatcherOnce = (extraEnv: Record<string, string> = {}) => {
      const r = spawnSync(process.execPath, [paths.sidecarScriptPath, "--once"], {
        encoding: "utf8",
        env: {
          ...process.env,
          REMOTE_PI_HOME: tempDir,
          ANTIGRAVITY_AGENTAPI_EXE: mockAgentApiScript,
          ...extraEnv,
        },
      });
      expect(r.status).toBe(0);
    };

    // 1. Register conversation as BUSY (PreInvocation)
    runHook({ conversationId: convId, workspacePaths: [workspace] }, "PreInvocation");
    expect(readConversationRecord(convId)?.state).toBe("busy");

    // 2. Message arrives while conversation is BUSY -> watcher must NOT call agentapi
    writeInboxState({
      cwd: workspace,
      name: "agy",
      address: `${workspace}@agy`,
      ppid: process.pid,
      messages: [
        {
          id: "m-1",
          from: `${workspace}@pi`,
          body: { event: "pr-merged" },
          re: null,
          at: "2026-10-31T18:00:00.000Z",
        },
      ],
    });
    runWatcherOnce();
    expect(existsSync(callsLogPath)).toBe(false);

    // 3. Conversation becomes IDLE (e.g. Stop with USER_CANCELLED or after turn end)
    runHook(
      { conversationId: convId, workspacePaths: [workspace], terminationReason: "USER_CANCELLED" },
      "Stop",
    );
    expect(readConversationRecord(convId)?.state).toBe("idle");

    // 4. Watcher runs -> wakes conversation once using ["agentapi", "send-message", ...]!
    // Also simulate PreInvocation flipping state to "busy" while agentapi runs;
    // watcher must NOT overwrite "busy" back to "idle" after execFileSync returns.
    runWatcherOnce({ SIMULATE_PREINVOCATION_BUSY: "1" });
    expect(existsSync(callsLogPath)).toBe(true);
    expect(readConversationRecord(convId)?.state).toBe("busy");

    const readCalls = (): string[][] =>
      readFileSync(callsLogPath, "utf8")
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => JSON.parse(line) as string[]);

    expect(readCalls()).toHaveLength(1);
    expect(readCalls()[0]?.[0]).toBe("agentapi");
    expect(readCalls()[0]?.[1]).toBe("send-message");
    expect(readCalls()[0]?.[2]).toBe(convId);
    expect(readCalls()[0]?.[3]).toContain("1 unread mesh message(s) arrived");

    // Transition back to idle; running watcher again with unchanged inbox is deduplicated (still 1 call)
    runHook(
      { conversationId: convId, workspacePaths: [workspace], terminationReason: "USER_CANCELLED" },
      "Stop",
    );
    runWatcherOnce();
    expect(readCalls()).toHaveLength(1);

    // 6. 6 messages now queued (preview capped at 5, but lastMessageId is m-6) -> wakes again!
    writeInboxState({
      cwd: workspace,
      name: "agy",
      address: `${workspace}@agy`,
      ppid: process.pid,
      messages: [1, 2, 3, 4, 5, 6].map((n) => ({
        id: `m-${n}`,
        from: `${workspace}@pi`,
        body: `msg ${n}`,
        re: null,
        at: "2026-10-31T18:00:00.000Z",
      })),
    });
    runWatcherOnce();
    expect(readCalls()).toHaveLength(2);
    expect(readCalls()[1]?.[3]).toContain("6 unread mesh message(s) arrived");

    // 7. Re-reads inbox on each iteration: if a second workspace drains its inbox
    // and becomes idle while the first workspace's agentapi call is running,
    // watcher must NOT wake the second workspace for its drained inbox.
    const workspace2 = join(tempDir, "watcher-repo-2");
    const convId2 = "conv-watcher-2";
    const convPath2 = conversationFilePath(convId2);
    runHook({ conversationId: convId2, workspacePaths: [workspace2] }, "PreInvocation");
    const inboxPath2 = writeInboxState({
      cwd: workspace2,
      name: "agy",
      address: `${workspace2}@agy`,
      ppid: process.pid,
      messages: [
        {
          id: "m-transient",
          from: `${workspace2}@pi`,
          body: "drained mid-turn",
          re: null,
          at: "2026-10-31T18:00:00.000Z",
        },
      ],
    });
    // Queue a 7th message in workspace 1 so workspace 1 runs execFileSync, and
    // during that execFileSync drain workspace 2's inbox and transition conv-watcher-2 to idle!
    writeInboxState({
      cwd: workspace,
      name: "agy",
      address: `${workspace}@agy`,
      ppid: process.pid,
      messages: [1, 2, 3, 4, 5, 6, 7].map((n) => ({
        id: `m-${n}`,
        from: `${workspace}@pi`,
        body: `msg ${n}`,
        re: null,
        at: "2026-10-31T18:00:00.000Z",
      })),
    });
    writeFileSync(
      mockAgentApiScript,
      `import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
appendFileSync(${JSON.stringify(callsLogPath)}, JSON.stringify(process.argv.slice(2)) + "\\n", "utf8");
const in2 = JSON.parse(readFileSync(${JSON.stringify(inboxPath2)}, "utf8"));
in2.unreadCount = 0;
in2.lastMessageId = null;
in2.preview = [];
writeFileSync(${JSON.stringify(inboxPath2)}, JSON.stringify(in2, null, 2), "utf8");
const c2 = JSON.parse(readFileSync(${JSON.stringify(convPath2)}, "utf8"));
c2.state = "idle";
writeFileSync(${JSON.stringify(convPath2)}, JSON.stringify(c2, null, 2), "utf8");
`,
      "utf8",
    );
    runWatcherOnce();
    // Only workspace 1 (convId) was woken; convId2 was skipped because its inbox was drained!
    expect(readCalls()).toHaveLength(3);
    expect(readCalls()[2]?.[2]).toBe(convId);
  });

  test("mesh_hook ignores other sessions' inboxes in the same workspace", () => {
    const configDir = join(tempDir, ".gemini", "config");
    const paths = ensureAgyMeshPluginInstalled({ configDir });
    const workspace = join(tempDir, "shared-repo");

    const sibling = spawn(process.execPath, ["-e", "setTimeout(() => {}, 30000)"], {
      stdio: "ignore",
    });
    sibling.unref();
    try {
      writeInboxState({
        cwd: workspace,
        name: "agy#2",
        address: `${workspace}@agy#2`,
        pid: sibling.pid!,
        ppid: 999_999,
        messages: [
          {
            id: "for-sibling",
            from: `${workspace}@pi`,
            body: "not for this session",
            re: null,
            at: "2026-10-31T18:00:00.000Z",
          },
        ],
      });

      const r = spawnSync(process.execPath, [paths.hookScriptPath], {
        input: JSON.stringify({
          hook_event_name: "Stop",
          cwd: workspace,
          terminationReason: "NO_TOOL_CALL",
        }),
        encoding: "utf8",
        env: { ...process.env, REMOTE_PI_HOME: tempDir },
      });
      expect(r.status).toBe(0);
      expect(JSON.parse(r.stdout.trim())).toEqual({});
    } finally {
      sibling.kill();
    }
  });

  test("mesh_hook does not fire for a parent workspace's inbox", () => {
    const configDir = join(tempDir, ".gemini", "config");
    const paths = ensureAgyMeshPluginInstalled({ configDir });
    const parent = join(tempDir, "parent-repo");
    const child = join(parent, "pkg");

    writeInboxState({
      cwd: parent,
      name: "pi",
      address: `${parent}@pi`,
      ppid: process.pid,
      messages: [
        {
          id: "parent-only",
          from: `${parent}@claude`,
          body: "for the parent agent",
          re: null,
          at: "2026-10-31T18:00:00.000Z",
        },
      ],
    });

    const r = spawnSync(process.execPath, [paths.hookScriptPath], {
      input: JSON.stringify({
        hook_event_name: "Stop",
        cwd: child,
        terminationReason: "NO_TOOL_CALL",
      }),
      encoding: "utf8",
      env: { ...process.env, REMOTE_PI_HOME: tempDir },
    });
    expect(r.status).toBe(0);
    expect(JSON.parse(r.stdout.trim())).toEqual({});
  });
});
