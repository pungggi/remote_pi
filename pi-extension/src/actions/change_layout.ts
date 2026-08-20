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
 *   2. spawn `cockpit orchestrate <path>`
 *   3. relay the CLI's `{ok, created, skipped}` JSON reply to the phone
 *
 * Failure modes are explicit and actionable: unknown layout name, Cockpit CLI
 * not installed, or Cockpit not running (CLI fails to connect).
 */
import { join } from "node:path";
import { existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { spawn } from "node:child_process";
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

/** Locate the `cockpit` CLI: PATH first, then the canonical `~/.cockpit/bin`. */
export function findCockpitCli(): string | null {
  const isWin = process.platform === "win32";
  const exe = isWin ? "cockpit.exe" : "cockpit";
  const candidates = [
    join(homedir(), ".cockpit", "bin", exe),
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  // PATH lookup (no extension juggling — spawn resolves via shell on win32)
  return "cockpit";
}

/** Runs `cockpit orchestrate <path>`; resolves with the CLI's JSON reply. */
export function runCockpitOrchestrate(
  cli: string,
  ckpPath: string,
  timeoutMs = 15000,
): Promise<{ ok: boolean; created: string[]; skipped: string[]; message: string }> {
  return new Promise((resolve) => {
    const child = spawn(cli, ["orchestrate", ckpPath], {
      windowsHide: true,
      shell: process.platform === "win32",
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
      // The CLI prints one JSON line: {ok, data:{created,skipped}} | {ok:false, error}
      const line = out.split("\n").map((l) => l.trim()).filter((l) => l.startsWith("{")).pop();
      if (line) {
        try {
          const j = JSON.parse(line) as { ok?: boolean; data?: { created?: string[]; skipped?: string[] }; error?: string };
          if (j.ok) {
            resolve({
              ok: true,
              created: j.data?.created ?? [],
              skipped: j.data?.skipped ?? [],
              message: "",
            });
            return;
          }
          resolve({ ok: false, created: [], skipped: [], message: j.error ?? "cockpit orchestrate failed" });
          return;
        } catch { /* fall through to raw */ }
      }
      resolve({
        ok: code === 0,
        created: [],
        skipped: [],
        message: code === 0 ? out.trim() : (err.trim() || `cockpit exited with ${code}`),
      });
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

  const result = await runCockpitOrchestrate(cli, layout.path);
  reply(result.ok, result.created, result.skipped, result.message);
}
