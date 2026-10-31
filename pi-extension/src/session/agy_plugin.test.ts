import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { ensureAgyMeshPluginInstalled, stripJsonComments } from "./agy_plugin.js";
import { writeInboxState } from "../mcp/inbox_state.js";

describe("ensureAgyMeshPluginInstalled + mesh_hook.mjs", () => {
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

  test("renders full Antigravity plugin bundle and preserves existing JSONC mcp_config.json servers", () => {
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

    const fakeServerPath = "/abs/path/to/dist/mcp/mesh_server.js";
    const paths = ensureAgyMeshPluginInstalled({
      configDir,
      meshServerPath: fakeServerPath,
    });

    expect(existsSync(paths.pluginManifestPath)).toBe(true);
    expect(existsSync(paths.mcpConfigPath)).toBe(true);
    expect(existsSync(paths.hooksConfigPath)).toBe(true);
    expect(existsSync(paths.hookScriptPath)).toBe(true);
    expect(existsSync(paths.rulesPath)).toBe(true);
    expect(existsSync(paths.skillPath)).toBe(true);

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

    const hooksJson = JSON.parse(readFileSync(paths.hooksConfigPath, "utf8")) as {
      hooks: { PreInvocation: unknown[]; Stop: unknown[] };
    };
    expect(hooksJson.hooks.PreInvocation).toHaveLength(1);
    expect(hooksJson.hooks.Stop).toHaveLength(1);
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
    // Regression: the old trailing-comma regex rewrote `,}` inside strings
    // ("x,}" → "x}"), silently corrupting existing server arguments when the
    // parsed config was written back to disk.
    const raw = `{
      "args": ["a,b", "x,}"],
      "cmd": "echo a,b",
      "enabled": true,
    }`;
    expect(JSON.parse(stripJsonComments(raw))).toEqual({
      args: ["a,b", "x,}"],
      cmd: "echo a,b",
      enabled: true,
    });
  });

  test("refuses to overwrite an unparseable mcp_config.json", () => {
    const configDir = join(tempDir, ".gemini", "config");
    mkdirSync(configDir, { recursive: true });
    const configPath = join(configDir, "mcp_config.json");
    const malformed = `{ "mcpServers": { "keep": { "command": "py"; } } }`;
    writeFileSync(configPath, malformed, "utf8");

    expect(() => ensureAgyMeshPluginInstalled({ configDir })).toThrow(/refusing to overwrite/);
    // The unreadable file must be byte-for-byte untouched — overwriting it
    // would erase every unrelated server entry.
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

  test("mesh_hook.mjs emits {} when inbox is empty, injectSteps on PreInvocation, and continue on Stop", () => {
    const configDir = join(tempDir, ".gemini", "config");
    const paths = ensureAgyMeshPluginInstalled({ configDir });
    const workspace = join(tempDir, "my-repo");

    const runHook = (payload: Record<string, unknown>): Record<string, unknown> => {
      const r = spawnSync(process.execPath, [paths.hookScriptPath], {
        input: JSON.stringify(payload),
        encoding: "utf8",
        env: { ...process.env, REMOTE_PI_HOME: tempDir },
      });
      expect(r.status).toBe(0);
      return JSON.parse(r.stdout.trim()) as Record<string, unknown>;
    };

    // 1. Empty inbox -> {}
    expect(runHook({ hook_event_name: "PreInvocation", cwd: workspace })).toEqual({});
    expect(runHook({ hook_event_name: "Stop", cwd: workspace, terminationReason: "NO_TOOL_CALL" })).toEqual({});

    // 2. Populate unread message in workspace. `ppid: process.pid` marks the
    // record as written by THIS test process, which also spawns the hook below
    // — exactly like the real session host that spawns both the mesh server
    // and the hook.
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

    // 3. PreInvocation injects ephemeralMessage
    const preOut = runHook({ hook_event_name: "PreInvocation", cwd: workspace }) as {
      injectSteps?: Array<{ ephemeralMessage: string }>;
    };
    expect(preOut.injectSteps).toHaveLength(1);
    expect(preOut.injectSteps?.[0]?.ephemeralMessage).toContain("1 unread mesh message(s)");
    expect(preOut.injectSteps?.[0]?.ephemeralMessage).toContain("get_messages");

    // 4. Stop with NO_TOOL_CALL returns decision: "continue"
    const stopOut = runHook({
      hook_event_name: "Stop",
      cwd: workspace,
      terminationReason: "NO_TOOL_CALL",
    }) as { decision?: string; reason?: string };
    expect(stopOut.decision).toBe("continue");
    expect(stopOut.reason).toContain("get_messages");

    // 5. Stop with USER_CANCELLED does not force continue
    expect(
      runHook({
        hook_event_name: "Stop",
        cwd: workspace,
        terminationReason: "USER_CANCELLED",
      }),
    ).toEqual({});
  });

  test("mesh_hook ignores other sessions' inboxes in the same workspace", () => {
    const configDir = join(tempDir, ".gemini", "config");
    const paths = ensureAgyMeshPluginInstalled({ configDir });
    const workspace = join(tempDir, "shared-repo");

    // A live sibling session (`agy#2`) in the SAME workspace whose mesh server
    // was spawned by a different host (ppid 999999). Its pid must be a real,
    // live process so the hook does not prune the record as stale.
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
      // Regression (review HIGH): returning decision:"continue" here would loop
      // forever — this session's get_messages can never drain the sibling inbox.
      expect(JSON.parse(r.stdout.trim())).toEqual({});
    } finally {
      sibling.kill();
    }
  });
});
