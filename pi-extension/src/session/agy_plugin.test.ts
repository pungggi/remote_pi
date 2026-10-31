import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
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

    // 2. Populate unread message in workspace
    writeInboxState({
      cwd: workspace,
      name: "agy",
      address: `${workspace}@agy`,
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
});
