/**
 * `change_layout_request` handler (api.changeLayout) — applies a NAMED
 * `.ckp` layout on the PC via the Cockpit CLI.
 *
 * The Cockpit multiplexer already owns named layouts: each `*.ckp` file
 * (tmuxinator-style YAML) IS a layout, and the internal `cockpit` CLI exposes
 * `cockpit orchestrate <file.ckp>` which applies it to the active workspace
 * (idempotent merge — panes with existing labels are skipped). This handler
 * bridges the phone's `changeLayout(name)` onto that surface:
 *
 *   1. resolve `name` → absolute `.ckp` path (search under the configured
 *      projects roots — same `projectsRoots()` the Projects list uses)
 *   2. discover the Cockpit status endpoint (review fix: the daemon is NOT a
 *      Cockpit terminal — it has no COCKPIT_STATUS_SOCK/PORT env — so without
 *      injecting the endpoint the CLI exits "not inside a Cockpit terminal")
 *   3. spawn `cockpit orchestrate <path> --json`
 *   4. parse the CLI's `{created, skipped}` JSON line (the `--json` success
 *      shape — NOT the socket wire's `{ok, data}`) and relay it to the phone
 *
 * Failure modes are explicit and actionable: unknown layout name, Cockpit CLI
 * not installed, or Cockpit not running (no endpoint published / connect
 * refused).
 */
import { join } from "node:path";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { execFileSync, spawn } from "node:child_process";
import type { ClientMessage, ServerMessage } from "../protocol/types.js";
import type { ActionReplySender } from "./handlers.js";
import { projectsRoots } from "../config.js";

type ChangeLayoutRequestMsg = Extract<
  ClientMessage,
  { type: "change_layout_request" }
>;

export interface NamedLayout {
  /** Layout name (basename without extension). */
  name: string;
  /** Absolute path of the `.ckp` file. */
  path: string;
}

/** Max subdirectory depth to search below each root when resolving a name.
 *  Mirrors the Projects discovery budget (plan/121) so resolution cost is
 *  bounded on giant trees. */
const MAX_DEPTH = 2;

/** Directories never descended into while resolving a layout name. */
const SKIP_DIRS = new Set([".git", "node_modules", ".pi", "target", "build", "dist", "out"]);

/**
 * Resolve a layout name to its `.ckp` path. Pure fs — exported for tests.
 * First match wins; roots are searched in configured order. `null` when no
 * matching `<name>.ckp` exists at any searched depth (case-sensitive: names
 * are file basenames).
 */
export function resolveNamedLayout(name: string, roots: readonly string[]): NamedLayout | null {
  const clean = name.trim();
  if (!clean || clean.includes("/") || clean.includes("\\") || clean.includes("..")) {
    return null; // names are plain basenames — never a traversal vector
  }
  const target = `${clean}.ckp`;
  const visit = (dir: string, depth: number): NamedLayout | null => {
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return null;
    }
    // Files first: a layout at this level wins before deeper ones.
    if (entries.includes(target)) {
      const p = join(dir, target);
      try {
        if (statSync(p).isFile()) return { name: clean, path: p };
      } catch { /* raced away — keep searching */ }
    }
    if (depth >= MAX_DEPTH) return null;
    for (const entry of entries) {
      if (SKIP_DIRS.has(entry) || entry.startsWith(".")) continue;
      const child = join(dir, entry);
      try {
        if (!statSync(child).isDirectory()) continue;
      } catch {
        continue;
      }
      const hit = visit(child, depth + 1);
      if (hit) return hit;
    }
    return null;
  };
  for (const root of roots) {
    if (!root || !root.trim()) continue;
    const hit = visit(root.trim(), 0);
    if (hit) return hit;
  }
  return null;
}

/** Discover every named layout under the roots (for future list UIs + tests). */
export function listNamedLayouts(roots: readonly string[]): NamedLayout[] {
  const found = new Map<string, NamedLayout>();
  const visit = (dir: string, depth: number): void => {
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.endsWith(".ckp")) {
        const p = join(dir, entry);
        try {
          if (statSync(p).isFile()) {
            const name = entry.slice(0, -".ckp".length);
            if (!found.has(name)) found.set(name, { name, path: p });
          }
        } catch { /* raced — skip */ }
        continue;
      }
      if (depth >= MAX_DEPTH) continue;
      if (SKIP_DIRS.has(entry) || entry.startsWith(".")) continue;
      const child = join(dir, entry);
      try {
        if (statSync(child).isDirectory()) visit(child, depth + 1);
      } catch { /* skip */ }
    }
  };
  for (const root of roots) {
    if (root && root.trim()) visit(root.trim(), 0);
  }
  return [...found.values()].sort((a, b) => a.name.localeCompare(b.name));
}

/** Locate the `cockpit` CLI. Absolute candidates first — BOTH flavors
 *  (release `~/.cockpit/bin` and dev `~/.cockpit/bin-debug`, mirroring the
 *  app's `cockpitCliDir()`), then PATH. Windows: spawn runs WITHOUT a shell
 *  (a shell would split paths containing spaces and interpret
 *  metacharacters — review finding), and a bare name does not resolve without
 *  one, so the PATH lookup goes through `where` and returns an absolute
 *  `.exe` (real executable only — `.cmd`/`.bat` shims are not spawnable
 *  shell-less on modern Node) or `null`. POSIX: bare `cockpit` is fine
 *  (spawn's own PATH lookup handles it). */
export function findCockpitCli(): string | null {
  const isWin = process.platform === "win32";
  const exe = isWin ? "cockpit.exe" : "cockpit";
  const home = homedir();
  for (const dir of ["bin", "bin-debug"]) {
    const c = join(home, ".cockpit", dir, exe);
    if (existsSync(c)) return c;
  }
  if (!isWin) return "cockpit";
  try {
    const out = execFileSync("where", ["cockpit"], { encoding: "utf8" });
    const hit = out
      .split(/\r?\n/)
      .map((l) => l.trim())
      .find((l) => /\.exe$/i.test(l) && existsSync(l));
    return hit ?? null;
  } catch {
    return null;
  }
}

/** The live Cockpit status-server endpoint, as published by the app. */
export type CockpitEndpoint =
  | { transport: "sock"; sock: string }
  | { transport: "tcp"; port: number; token?: string };

/** Read the Cockpit status endpoint (review fix: the daemon is not a Cockpit
 *  terminal, so it must NOT rely on inheriting COCKPIT_STATUS_* env). Primary
 *  source: the `status-endpoint[-debug].json` file the app publishes on
 *  start (Windows publishes its ephemeral TCP port + anti-spoof token there —
 *  otherwise unknowable). POSIX fallback for pre-endpoint-file Cockpits: the
 *  conventional, deterministic UDS paths. `null` when Cockpit appears to be
 *  not running at all. */
export function readCockpitEndpoint(homeDir = homedir()): CockpitEndpoint | null {
  const base = join(homeDir, ".cockpit");
  for (const name of ["status-endpoint.json", "status-endpoint-debug.json"]) {
    try {
      const j = JSON.parse(
        readFileSync(join(base, name), "utf8"),
      ) as { sock?: unknown; port?: unknown; token?: unknown };
      if (typeof j.sock === "string" && j.sock) {
        return { transport: "sock", sock: j.sock };
      }
      if (typeof j.port === "number" && Number.isInteger(j.port) && j.port > 0) {
        return {
          transport: "tcp",
          port: j.port,
          ...(typeof j.token === "string" && j.token ? { token: j.token } : {}),
        };
      }
    } catch {
      /* missing or malformed — try the next source */
    }
  }
  for (const sock of [join(base, "status.sock"), join(base, "status-debug.sock")]) {
    if (existsSync(sock)) return { transport: "sock", sock };
  }
  return null;
}

/** Child env for a `cockpit` CLI invocation from OUTSIDE a Cockpit terminal:
 *  the transport vars the CLI normally inherits from its tab's PTY. */
export function cockpitChildEnv(
  endpoint: CockpitEndpoint,
  base: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  if (endpoint.transport === "sock") {
    return { ...base, COCKPIT_STATUS_SOCK: endpoint.sock };
  }
  return {
    ...base,
    COCKPIT_STATUS_PORT: String(endpoint.port),
    ...(endpoint.token ? { COCKPIT_STATUS_TOKEN: endpoint.token } : {}),
  };
}

/** CLI args for orchestrate. `--json` is REQUIRED (review fix): without it
 *  the CLI prints human text (`created: a, b`) and the merge report is lost.
 *  The path goes through verbatim — no quoting; spawn must run shell-less. */
export function orchestrateArgs(ckpPath: string): string[] {
  return ["orchestrate", "--json", ckpPath];
}

export interface OrchestrateRun {
  ok: boolean;
  created: string[];
  skipped: string[];
  message: string;
}

/** Parse the CLI's process result (exported for tests). Success = exit 0 +
 *  one stdout JSON line in the `--json` shape `{created, skipped}` — NOT the
 *  socket wire's `{ok, data}` (that envelope is CLI→app; the CLI strips it
 *  before printing). Nonzero exit (e.g. 1 app-reported error, 3 no terminal /
 *  connect refused): message from stderr. */
export function parseOrchestrateReply(
  code: number | null,
  stdout: string,
  stderr: string,
): OrchestrateRun {
  const line = stdout
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.startsWith("{"))
    .pop();
  if (code === 0 && line) {
    try {
      const j = JSON.parse(line) as { created?: unknown; skipped?: unknown };
      return {
        ok: true,
        created: Array.isArray(j.created) ? j.created.filter((x): x is string => typeof x === "string") : [],
        skipped: Array.isArray(j.skipped) ? j.skipped.filter((x): x is string => typeof x === "string") : [],
        message: "",
      };
    } catch {
      /* unexpected shape — fall through to the failure path, loudly */
    }
  }
  return {
    ok: false,
    created: [],
    skipped: [],
    message: stderr.trim() || stdout.trim() || `cockpit exited with code ${code ?? "signal"}`,
  };
}

/** Runs `cockpit orchestrate <path> --json` with the Cockpit endpoint env
 *  injected; resolves with the parsed report. Spawns WITHOUT a shell (review
 *  fix): `shell:true` on Windows would re-split the command line and break on
 *  layout paths containing spaces, and interpret shell metacharacters. */
export function runCockpitOrchestrate(
  cli: string,
  ckpPath: string,
  env: NodeJS.ProcessEnv = process.env,
  timeoutMs = 15000,
): Promise<OrchestrateRun> {
  return new Promise((resolve) => {
    const child = spawn(cli, orchestrateArgs(ckpPath), {
      windowsHide: true,
      env,
    });
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      child.kill();
      resolve({ ok: false, created: [], skipped: [], message: "cockpit orchestrate timed out" });
    }, timeoutMs);
    child.stdout?.on("data", (d: Buffer) => (out += d.toString("utf8")));
    child.stderr?.on("data", (d: Buffer) => (err += d.toString("utf8")));
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ ok: false, created: [], skipped: [], message: `cockpit CLI failed to start: ${e.message}` });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve(parseOrchestrateReply(code, out, err));
    });
  });
}

export async function handleChangeLayout(
  sender: ActionReplySender,
  msg: ChangeLayoutRequestMsg,
): Promise<void> {
  const reply = (ok: boolean, created: string[], skipped: string[], message: string): void => {
    const m: ServerMessage = {
      type: "change_layout_result",
      in_reply_to: msg.id,
      ok,
      created,
      skipped,
      ...(message ? { message } : {}),
    };
    sender.send(m);
  };

  const layout = resolveNamedLayout(msg.layout, projectsRoots());
  if (!layout) {
    const known = listNamedLayouts(projectsRoots()).map((l) => l.name);
    reply(
      false,
      [],
      [],
      known.length
        ? `no layout named "${msg.layout}" (.ckp) under the projects roots. Known: ${known.slice(0, 20).join(", ")}`
        : `no layout named "${msg.layout}" (.ckp) under the projects roots (none found at all)`,
    );
    return;
  }

  const cli = findCockpitCli();
  if (!cli) {
    reply(false, [], [], "Cockpit CLI not found — install Cockpit on this PC (api.changeLayout needs it)");
    return;
  }

  // Review fix: the daemon is not a Cockpit terminal — discover the app's
  // published endpoint and inject it, or the CLI exits "not inside a Cockpit
  // terminal" before even trying to connect.
  const endpoint = readCockpitEndpoint();
  if (!endpoint) {
    reply(
      false,
      [],
      [],
      process.platform === "win32"
        ? "Cockpit is not running (or is an older build without a published status endpoint) — start/update the Cockpit app, then retry"
        : "Cockpit is not running — start the Cockpit app, then retry (no status socket found)",
    );
    return;
  }

  const result = await runCockpitOrchestrate(cli, layout.path, cockpitChildEnv(endpoint));
  reply(result.ok, result.created, result.skipped, result.message);
}
