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
 */

import { existsSync, readdirSync, readFileSync, realpathSync, unlinkSync } from "node:fs";
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
    const normRoot = normalizePath(root);
    if (
      normRecord === normRoot ||
      normRecord.startsWith(`${normRoot}/`) ||
      normRoot.startsWith(`${normRecord}/`)
    ) {
      return true;
    }
  }
  return false;
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

  const unread = [];
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
      unread.push(parsed);
    } catch {
      // Ignore malformed/transient files
    }
  }
  return unread;
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
