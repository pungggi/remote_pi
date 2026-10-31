#!/usr/bin/env node
/**
 * Antigravity (agy) lifecycle hook for the remote-pi agent mesh.
 *
 * Handles:
 *   - PreInvocation: when unread mesh messages are waiting in this workspace's
 *     inbox, injects an ephemeralMessage reminding agy to call `get_messages`.
 *     When inbox is empty, outputs `{}` (zero token overhead).
 *   - Stop: when agy is about to finish a turn (NO_TOOL_CALL) and unread mesh
 *     messages arrived during the turn, outputs `{ decision: "continue", reason }`
 *     so agy automatically continues its turn to handle the incoming message.
 *
 * Session ownership: inbox state files are per-`(cwd, name)` and one workspace
 * can hold several live sessions (pi, Claude, `agy`, `agy#2`, …). Only an
 * inbox whose writer shares this hook's session host (its `ppid`) is ours;
 * without that filter a message addressed to a sibling session would keep
 * returning `decision: "continue"` forever, because this session's
 * `get_messages` can never drain that inbox.
 */

import { existsSync, readdirSync, readFileSync, realpathSync, unlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

function inboxStateDir() {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  return join(root, ".pi", "piper", "sessions", "local", "inbox");
}

function isProcessAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err && err.code === "EPERM";
  }
}

function normalizePath(p) {
  let resolved = resolve(String(p));
  try {
    resolved = realpathSync(resolved);
  } catch {
    // Ignore non-existent paths
  }
  const norm = resolved.replace(/\\/g, "/").replace(/\/+$/, "");
  return process.platform === "win32" ? norm.toLowerCase() : norm;
}

function matchesWorkspace(recordCwd, roots) {
  if (!Array.isArray(roots) || roots.length === 0) return true;
  const normRecord = normalizePath(recordCwd);
  for (const root of roots) {
    if (!root) continue;
    // Exact canonical equality only — parent and child folders are distinct
    // agents, so prefix matching would fire this hook across workspaces.
    if (normRecord === normalizePath(root)) return true;
  }
  return false;
}

/**
 * Parent PID of this hook's own parent (the session host, one level above the
 * hook's immediate parent). Needed only when the hook itself was spawned
 * through a shell — resolved lazily so the common sibling case costs nothing.
 * Returns null when the lookup fails; fail closed (no match) rather than risk
 * an endless Stop-continue loop.
 */
let _hostParent;
function hostParentPid() {
  if (_hostParent !== undefined) return _hostParent;
  _hostParent = null;
  const pid = process.ppid;
  try {
    if (process.platform === "win32") {
      const res = spawnSync(
        "powershell.exe",
        [
          "-NoProfile",
          "-NonInteractive",
          "-Command",
          `(Get-CimInstance Win32_Process -Filter "ProcessId=${pid}").ParentProcessId`,
        ],
        { encoding: "utf8", timeout: 2_000 },
      );
      const parsed = Number.parseInt((res.stdout || "").trim(), 10);
      if (res.error === undefined && Number.isInteger(parsed) && parsed > 0) {
        _hostParent = parsed;
      }
    } else {
      const res = spawnSync("ps", ["-o", "ppid=", "-p", String(pid)], {
        encoding: "utf8",
        timeout: 2_000,
      });
      const parsed = Number.parseInt((res.stdout || "").trim(), 10);
      if (res.error === undefined && Number.isInteger(parsed) && parsed > 0) {
        _hostParent = parsed;
      }
    }
  } catch {
    _hostParent = null;
  }
  return _hostParent;
}

/**
 * Keeps only inbox records written by THIS session's mesh server:
 *   1. fast path — same parent as this hook (both spawned by the session host);
 *   2. lazy path — same parent as the hook's grandparent (shell-wrapped hooks).
 * Records without a recorded `ppid` (legacy) are treated as not ours.
 */
function filterOwnedByThisSession(candidates) {
  if (candidates.length === 0) return [];
  const host = process.ppid;
  const direct = candidates.filter((r) => r.ppid === host);
  if (direct.length > 0) return direct;
  const hostParent = hostParentPid();
  if (hostParent === null) return [];
  return candidates.filter((r) => r.ppid === hostParent);
}

function findUnreadForWorkspace(roots) {
  const dir = inboxStateDir();
  if (!existsSync(dir)) return [];
  let entries = [];
  try {
    entries = readdirSync(dir);
  } catch {
    return [];
  }

  const candidates = [];
  for (const entry of entries) {
    if (!entry.endsWith(".json")) continue;
    const fullPath = join(dir, entry);
    try {
      const parsed = JSON.parse(readFileSync(fullPath, "utf8"));
      if (typeof parsed.pid !== "number" || !isProcessAlive(parsed.pid)) {
        try { unlinkSync(fullPath); } catch { /* ignore */ }
        continue;
      }
      if (typeof parsed.unreadCount !== "number" || parsed.unreadCount <= 0) {
        continue;
      }
      if (typeof parsed.cwd !== "string" || !matchesWorkspace(parsed.cwd, roots)) {
        continue;
      }
      candidates.push(parsed);
    } catch {
      // Ignore malformed/transient files
    }
  }
  return filterOwnedByThisSession(candidates);
}

function extractWorkspaceRoots(input) {
  const roots = [];
  if (typeof input?.cwd === "string" && input.cwd) roots.push(input.cwd);
  if (Array.isArray(input?.workspace_roots)) roots.push(...input.workspace_roots);
  if (Array.isArray(input?.workspacePaths)) roots.push(...input.workspacePaths);
  return roots;
}

function buildSendersSummary(records) {
  const senders = new Set();
  let total = 0;
  for (const r of records) {
    total += r.unreadCount || 0;
    if (Array.isArray(r.preview)) {
      for (const item of r.preview) {
        if (item?.from) senders.add(item.from);
      }
    }
  }
  const fromPart = senders.size > 0 ? ` from ${Array.from(senders).join(", ")}` : "";
  return { total, fromPart };
}

async function readStdinJson() {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

async function main() {
  const input = await readStdinJson();
  const eventName = input.hook_event_name || input.event || "";
  const roots = extractWorkspaceRoots(input);
  const unreadRecords = findUnreadForWorkspace(roots);

  if (unreadRecords.length === 0) {
    process.stdout.write("{}\n");
    return;
  }

  const { total, fromPart } = buildSendersSummary(unreadRecords);
  const msgText =
    `📨 [remote-pi mesh] You have ${total} unread mesh message(s) waiting${fromPart}. ` +
    `Call \`get_messages\` on the \`remote-pi-mesh\` MCP server now to read and handle them.`;

  if (eventName === "PreInvocation") {
    process.stdout.write(
      JSON.stringify({
        injectSteps: [{ ephemeralMessage: msgText }],
      }) + "\n",
    );
    return;
  }

  if (eventName === "Stop") {
    const reason = input.terminationReason || "NO_TOOL_CALL";
    if (reason === "NO_TOOL_CALL") {
      process.stdout.write(
        JSON.stringify({
          decision: "continue",
          reason: msgText,
        }) + "\n",
      );
      return;
    }
  }

  process.stdout.write("{}\n");
}

main().catch(() => {
  process.stdout.write("{}\n");
});
