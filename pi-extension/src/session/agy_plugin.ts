import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const AGY_MESH_PLUGIN_NAME = "remote-pi-mesh";
export const AGY_MESH_SIDECAR_ID = "mesh-watcher";
export const AGY_MESH_SIDECAR_KEY = `${AGY_MESH_PLUGIN_NAME}/${AGY_MESH_SIDECAR_ID}`;

const DEFAULT_PLUGIN_VERSION = "0.8.0";
const DEFAULT_AGY_AGENT_NAME = "agy";
const HOOK_TIMEOUT_SECONDS = 5;

export interface InstallAgyPluginOptions {
  /** Override `~/.gemini/config` root (used by tests or custom AGY_CONFIG_DIR). */
  readonly configDir?: string;
  /** Override node executable path (defaults to `process.execPath`). */
  readonly nodeExecPath?: string;
  /** Override path to `dist/mcp/mesh_server.js`. */
  readonly meshServerPath?: string;
  /** Override package root containing `agy-plugin/` and `skills/`. */
  readonly packageRoot?: string;
}

export interface InstalledAgyPluginPaths {
  readonly pluginDir: string;
  readonly pluginManifestPath: string;
  readonly mcpConfigPath: string;
  readonly agyConfigPath: string;
  readonly hooksConfigPath: string;
  readonly hookScriptPath: string;
  readonly sidecarManifestPath: string;
  readonly sidecarScriptPath: string;
  readonly rulesPath: string;
  readonly skillPath: string;
}

/**
 * Resolves the user's Antigravity configuration directory (`~/.gemini/config` by default).
 */
export function resolveAgyConfigDir(override?: string): string {
  if (override) return resolve(override);
  if (process.env["AGY_CONFIG_DIR"]) return resolve(process.env["AGY_CONFIG_DIR"]);
  const home = process.env["REMOTE_PI_HOME"] || homedir();
  return join(home, ".gemini", "config");
}

function defaultPackageRoot(): string {
  const here = fileURLToPath(import.meta.url);
  return resolve(dirname(here), "..", "..");
}

/**
 * Strips `//` and `/* ... * /` comments and trailing commas outside string
 * literals so JSONC config files (`~/.gemini/config/mcp_config.json`) parse
 * cleanly. Trailing commas are removed during the character scan — a global
 * regex would also rewrite commas that legitimately live inside string
 * literals (e.g. `"abc,}"`), silently corrupting existing server arguments,
 * templates, or credentials when the parsed object is written back.
 */
export function stripJsonComments(input: string): string {
  let out = "";
  let inString = false;
  let escaped = false;
  for (let i = 0; i < input.length; i++) {
    const ch = input[i]!;
    const next = input[i + 1];
    if (inString) {
      out += ch;
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') {
      inString = true;
      out += ch;
      continue;
    }
    if (ch === "/" && next === "/") {
      while (i < input.length && input[i] !== "\n") i++;
      if (i < input.length) out += "\n";
      continue;
    }
    if (ch === "/" && next === "*") {
      i += 2;
      while (i < input.length && !(input[i] === "*" && input[i + 1] === "/")) i++;
      i++;
      continue;
    }
    if (ch === ",") {
      // Lookahead skips whitespace AND comments, so `"a": 1, // note\n}` drops
      // the comma exactly like the old regex did — but only here, outside a
      // string literal.
      const j = skipWhitespaceAndComments(input, i + 1);
      const following = input[j];
      if (following === "}" || following === "]") continue; // trailing comma
    }
    out += ch;
  }
  return out;
}

function skipWhitespaceAndComments(input: string, start: number): number {
  let j = start;
  while (j < input.length) {
    const ch = input[j];
    if (ch === undefined) break;
    if (/\s/.test(ch)) {
      j++;
      continue;
    }
    if (ch === "/" && input[j + 1] === "/") {
      while (j < input.length && input[j] !== "\n") j++;
      continue;
    }
    if (ch === "/" && input[j + 1] === "*") {
      j += 2;
      while (j < input.length && !(input[j] === "*" && input[j + 1] === "/")) j++;
      j += 2;
      continue;
    }
    break;
  }
  return j;
}

function parseExistingJsonObjectFile(filePath: string): Record<string, unknown> {
  if (!existsSync(filePath)) return {};
  const raw = readFileSync(filePath, "utf8").replace(/^\uFEFF/, "");
  if (raw.trim() === "") return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(stripJsonComments(raw));
  } catch (err) {
    throw new Error(
      `${filePath} exists but is not valid JSON (${err instanceof Error ? err.message : String(err)}); ` +
        `refusing to overwrite it. Fix or remove the file, then re-run "remote-pi agy --install-plugin".`,
    );
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(
      `${filePath} does not contain a JSON object; refusing to overwrite it. ` +
        `Fix or remove the file, then re-run "remote-pi agy --install-plugin".`,
    );
  }
  return parsed as Record<string, unknown>;
}

function upsertGlobalMcpConfig(
  mcpConfigPath: string,
  nodeExec: string,
  meshServer: string,
): void {
  const existing = parseExistingJsonObjectFile(mcpConfigPath);
  const mcpServers: Record<string, unknown> =
    existing["mcpServers"] &&
    typeof existing["mcpServers"] === "object" &&
    !Array.isArray(existing["mcpServers"])
      ? { ...(existing["mcpServers"] as Record<string, unknown>) }
      : {};

  mcpServers[AGY_MESH_PLUGIN_NAME] = {
    command: nodeExec,
    args: [meshServer, "--auto-join"],
    env: {
      REMOTE_PI_MCP_NAME: DEFAULT_AGY_AGENT_NAME,
      REMOTE_PI_MCP_AUTO_JOIN: "1",
    },
    disabled: false,
  };

  writeFileSync(
    mcpConfigPath,
    JSON.stringify({ ...existing, mcpServers }, null, 2) + "\n",
    "utf8",
  );
}

/**
 * Enables the `remote-pi-mesh` plugin and the `remote-pi-mesh/mesh-watcher`
 * sidecar in `<configDir>/config.json` (Antigravity disables sidecars by
 * default until explicitly enabled in `config.json`).
 */
function upsertAgyGlobalConfig(agyConfigPath: string): void {
  const existing = parseExistingJsonObjectFile(agyConfigPath);
  const existingPlugins =
    existing["plugins"] &&
    typeof existing["plugins"] === "object" &&
    !Array.isArray(existing["plugins"])
      ? { ...(existing["plugins"] as Record<string, unknown>) }
      : {};
  const existingSidecars =
    existing["sidecars"] &&
    typeof existing["sidecars"] === "object" &&
    !Array.isArray(existing["sidecars"])
      ? { ...(existing["sidecars"] as Record<string, unknown>) }
      : {};

  const prevPluginEntry =
    existingPlugins[AGY_MESH_PLUGIN_NAME] &&
    typeof existingPlugins[AGY_MESH_PLUGIN_NAME] === "object" &&
    !Array.isArray(existingPlugins[AGY_MESH_PLUGIN_NAME])
      ? (existingPlugins[AGY_MESH_PLUGIN_NAME] as Record<string, unknown>)
      : {};
  existingPlugins[AGY_MESH_PLUGIN_NAME] = {
    ...prevPluginEntry,
    enabled: true,
  };

  const prevSidecarEntry =
    existingSidecars[AGY_MESH_SIDECAR_KEY] &&
    typeof existingSidecars[AGY_MESH_SIDECAR_KEY] === "object" &&
    !Array.isArray(existingSidecars[AGY_MESH_SIDECAR_KEY])
      ? (existingSidecars[AGY_MESH_SIDECAR_KEY] as Record<string, unknown>)
      : {};
  existingSidecars[AGY_MESH_SIDECAR_KEY] = {
    ...prevSidecarEntry,
    enabled: true,
  };

  writeFileSync(
    agyConfigPath,
    JSON.stringify(
      {
        ...existing,
        plugins: existingPlugins,
        sidecars: existingSidecars,
      },
      null,
      2,
    ) + "\n",
    "utf8",
  );
}

function copyOrWritePluginManifest(pkgRoot: string, pluginManifestPath: string): void {
  const srcManifest = join(pkgRoot, "agy-plugin", "plugin.json");
  if (existsSync(srcManifest)) {
    copyFileSync(srcManifest, pluginManifestPath);
    return;
  }
  writeFileSync(
    pluginManifestPath,
    JSON.stringify(
      {
        name: AGY_MESH_PLUGIN_NAME,
        version: DEFAULT_PLUGIN_VERSION,
        description: "First-class remote-pi agent mesh integration for Google Antigravity (agy)",
      },
      null,
      2,
    ) + "\n",
    "utf8",
  );
}

function copyOrWriteSidecarManifest(pkgRoot: string, sidecarManifestPath: string): void {
  const srcSidecar = join(
    pkgRoot,
    "agy-plugin",
    "sidecars",
    AGY_MESH_SIDECAR_ID,
    "sidecar.json",
  );
  if (existsSync(srcSidecar)) {
    copyFileSync(srcSidecar, sidecarManifestPath);
    return;
  }
  writeFileSync(
    sidecarManifestPath,
    JSON.stringify(
      {
        command: "node",
        args: ["watcher.mjs"],
        restart_policy: "always",
        display_name: "remote-pi Mesh Watcher",
        description:
          "Monitors the remote-pi agent mesh and wakes idle Antigravity conversations via agentapi when messages arrive.",
      },
      null,
      2,
    ) + "\n",
    "utf8",
  );
}

function copyIfPresent(srcPath: string, destPath: string): void {
  if (existsSync(srcPath)) copyFileSync(srcPath, destPath);
}

/**
 * Writes Antigravity-compliant `hooks.json`.
 *
 * In Antigravity's native `hooks.json` specification, only `PreToolUse` and
 * `PostToolUse` use `{ "matcher": "...", "hooks": [...] }`. `SessionStart`,
 * `PreInvocation`, `PostInvocation`, and `Stop` MUST be flat arrays of handler
 * objects under a named hook group.
 */
function writePluginHooksConfig(
  hooksConfigPath: string,
  nodeExec: string,
  hookScriptPath: string,
): void {
  const makeHandler = (eventName: string) => [
    {
      type: "command",
      command: `"${nodeExec}" "${hookScriptPath}" --event=${eventName}`,
      timeout: HOOK_TIMEOUT_SECONDS,
    },
  ];
  const hooksConfig = {
    [AGY_MESH_PLUGIN_NAME]: {
      SessionStart: makeHandler("SessionStart"),
      PreInvocation: makeHandler("PreInvocation"),
      Stop: makeHandler("Stop"),
    },
  };
  writeFileSync(hooksConfigPath, JSON.stringify(hooksConfig, null, 2) + "\n", "utf8");
}

function removeLegacyPluginMcpConfig(pluginDir: string): void {
  const legacyPluginMcpPath = join(pluginDir, "mcp_config.json");
  try {
    if (existsSync(legacyPluginMcpPath)) unlinkSync(legacyPluginMcpPath);
  } catch {
    // Ignore cleanup errors.
  }
}

/**
 * Installs or updates the native `remote-pi-mesh` Antigravity integration:
 *   - `<configDir>/mcp_config.json`: registers `remote-pi-mesh` at the global
 *     config root so Antigravity spawns `mesh_server.js` with `process.cwd()`
 *     set to the active workspace directory (not the plugin directory).
 *   - `<configDir>/config.json`: enables `plugins["remote-pi-mesh"]` and
 *     `sidecars["remote-pi-mesh/mesh-watcher"]`.
 *   - `<configDir>/plugins/remote-pi-mesh/`:
 *       - `plugin.json`
 *       - `hooks.json` + `scripts/mesh_hook.mjs` (`SessionStart`, `PreInvocation`, `Stop`)
 *       - `sidecars/mesh-watcher/sidecar.json` + `watcher.mjs`
 *       - `rules/AGENTS.md`
 *       - `skills/agent-network/SKILL.md`
 */
export function ensureAgyMeshPluginInstalled(
  options: InstallAgyPluginOptions = {},
): InstalledAgyPluginPaths {
  const pkgRoot = options.packageRoot ? resolve(options.packageRoot) : defaultPackageRoot();
  const nodeExec = options.nodeExecPath ?? process.execPath;
  const meshServer =
    options.meshServerPath ?? resolve(pkgRoot, "dist", "mcp", "mesh_server.js");

  const configDir = resolveAgyConfigDir(options.configDir);
  const pluginDir = join(configDir, "plugins", AGY_MESH_PLUGIN_NAME);
  const scriptsDir = join(pluginDir, "scripts");
  const sidecarDir = join(pluginDir, "sidecars", AGY_MESH_SIDECAR_ID);
  const rulesDir = join(pluginDir, "rules");
  const skillDir = join(pluginDir, "skills", "agent-network");

  mkdirSync(scriptsDir, { recursive: true });
  mkdirSync(sidecarDir, { recursive: true });
  mkdirSync(rulesDir, { recursive: true });
  mkdirSync(skillDir, { recursive: true });

  const paths: InstalledAgyPluginPaths = {
    pluginDir,
    pluginManifestPath: join(pluginDir, "plugin.json"),
    mcpConfigPath: join(configDir, "mcp_config.json"),
    agyConfigPath: join(configDir, "config.json"),
    hooksConfigPath: join(pluginDir, "hooks.json"),
    hookScriptPath: join(scriptsDir, "mesh_hook.mjs"),
    sidecarManifestPath: join(sidecarDir, "sidecar.json"),
    sidecarScriptPath: join(sidecarDir, "watcher.mjs"),
    rulesPath: join(rulesDir, "AGENTS.md"),
    skillPath: join(skillDir, "SKILL.md"),
  };

  removeLegacyPluginMcpConfig(pluginDir);
  copyOrWritePluginManifest(pkgRoot, paths.pluginManifestPath);
  copyIfPresent(join(pkgRoot, "agy-plugin", "scripts", "mesh_hook.mjs"), paths.hookScriptPath);
  copyOrWriteSidecarManifest(pkgRoot, paths.sidecarManifestPath);
  copyIfPresent(
    join(pkgRoot, "agy-plugin", "sidecars", AGY_MESH_SIDECAR_ID, "watcher.mjs"),
    paths.sidecarScriptPath,
  );
  copyIfPresent(join(pkgRoot, "agy-plugin", "rules", "AGENTS.md"), paths.rulesPath);
  copyIfPresent(join(pkgRoot, "skills", "agent-network", "SKILL.md"), paths.skillPath);
  upsertGlobalMcpConfig(paths.mcpConfigPath, nodeExec, meshServer);
  upsertAgyGlobalConfig(paths.agyConfigPath);
  writePluginHooksConfig(paths.hooksConfigPath, nodeExec, paths.hookScriptPath);

  return paths;
}
