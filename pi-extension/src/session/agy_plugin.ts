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
  readonly hooksConfigPath: string;
  readonly hookScriptPath: string;
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

function upsertGlobalMcpConfig(
  mcpConfigPath: string,
  nodeExec: string,
  meshServer: string,
): void {
  let existing: { mcpServers?: Record<string, unknown>; [k: string]: unknown } = {};
  if (existsSync(mcpConfigPath)) {
    const raw = readFileSync(mcpConfigPath, "utf8").replace(/^\uFEFF/, "");
    if (raw.trim() !== "") {
      let parsed: unknown;
      try {
        parsed = JSON.parse(stripJsonComments(raw));
      } catch (err) {
        // Never overwrite a config we could not read: doing so would silently
        // erase every unrelated server entry (args, templates, credentials).
        throw new Error(
          `${mcpConfigPath} exists but is not valid JSON (${err instanceof Error ? err.message : String(err)}); ` +
            `refusing to overwrite it. Fix or remove the file, then re-run "remote-pi agy --install-plugin".`,
        );
      }
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error(
          `${mcpConfigPath} does not contain a JSON object; refusing to overwrite it. ` +
            `Fix or remove the file, then re-run "remote-pi agy --install-plugin".`,
        );
      }
      existing = parsed as { mcpServers?: Record<string, unknown> };
    }
  }
  const mcpServers: Record<string, unknown> =
    existing.mcpServers && typeof existing.mcpServers === "object"
      ? { ...existing.mcpServers }
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

function copyIfPresent(srcPath: string, destPath: string): void {
  if (existsSync(srcPath)) copyFileSync(srcPath, destPath);
}

function writePluginHooksConfig(
  hooksConfigPath: string,
  nodeExec: string,
  hookScriptPath: string,
): void {
  const hookEntry = {
    hooks: [
      {
        type: "command",
        command: `"${nodeExec}" "${hookScriptPath}"`,
        timeout: HOOK_TIMEOUT_SECONDS,
      },
    ],
  };
  const hooksConfig = {
    hooks: {
      PreInvocation: [hookEntry],
      Stop: [hookEntry],
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
 *   - `<configDir>/plugins/remote-pi-mesh/`:
 *       - `plugin.json`
 *       - `hooks.json` + `scripts/mesh_hook.mjs` (`PreInvocation` + `Stop`)
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
  const rulesDir = join(pluginDir, "rules");
  const skillDir = join(pluginDir, "skills", "agent-network");

  mkdirSync(scriptsDir, { recursive: true });
  mkdirSync(rulesDir, { recursive: true });
  mkdirSync(skillDir, { recursive: true });

  const paths: InstalledAgyPluginPaths = {
    pluginDir,
    pluginManifestPath: join(pluginDir, "plugin.json"),
    mcpConfigPath: join(configDir, "mcp_config.json"),
    hooksConfigPath: join(pluginDir, "hooks.json"),
    hookScriptPath: join(scriptsDir, "mesh_hook.mjs"),
    rulesPath: join(rulesDir, "AGENTS.md"),
    skillPath: join(skillDir, "SKILL.md"),
  };

  removeLegacyPluginMcpConfig(pluginDir);
  copyOrWritePluginManifest(pkgRoot, paths.pluginManifestPath);
  copyIfPresent(join(pkgRoot, "agy-plugin", "scripts", "mesh_hook.mjs"), paths.hookScriptPath);
  copyIfPresent(join(pkgRoot, "agy-plugin", "rules", "AGENTS.md"), paths.rulesPath);
  copyIfPresent(join(pkgRoot, "skills", "agent-network", "SKILL.md"), paths.skillPath);
  upsertGlobalMcpConfig(paths.mcpConfigPath, nodeExec, meshServer);
  writePluginHooksConfig(paths.hooksConfigPath, nodeExec, paths.hookScriptPath);

  return paths;
}
