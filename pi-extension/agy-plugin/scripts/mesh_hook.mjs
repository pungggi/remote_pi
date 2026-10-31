#!/usr/bin/env node
/**
 * Antigravity (agy) lifecycle hook for the remote-pi agent mesh.
 *
 * Handles:
 *   - SessionStart: records the active conversationId, workspacePath, and
 *     session hostPid (`ppid`) in `~/.pi/piper/sessions/local/conversations/`
 *     with `state: "busy"`.
 *   - PreInvocation: records `state: "busy"`, and when unread mesh messages
 *     are waiting in this session's inbox, injects an `ephemeralMessage`
 *     reminding agy to call `get_messages`. When inbox is empty, outputs `{}`
 *     (zero token overhead).
 *   - Stop: when agy is about to finish a turn (`NO_TOOL_CALL`) and unread mesh
 *     messages arrived during the turn, keeps `state: "busy"` and outputs
 *     `{ decision: "continue", reason }` so agy automatically continues its
 *     turn. Otherwise records `state: "idle"` and outputs `{}` so the
 *     `mesh-watcher` sidecar knows the conversation is idle and can wake it via
 *     `agentapi send-message` when a future message arrives.
 *
 * Session ownership: inbox state files are per-`(cwd, name)` and one workspace
 * can hold several live sessions (pi, Claude, `agy`, `agy#2`, …). Only an
 * inbox whose writer shares this hook's session host (`ppid`) is ours.
 */

import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

function inboxStateDir() {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  return join(root, ".pi", "piper", "sessions", "local", "inbox");
}

function conversationsDir() {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  return join(root, ".pi", "piper", "sessions", "local", "conversations");
}

function sanitizeConversationId(conversationId) {
  return String(conversationId).trim().replace(/[^a-zA-Z0-9_-]/g, "_");
}

function isProcessAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return Boolean(err && err.code === "EPERM");
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
 * through a shell — resolved lazily so the common direct-spawn case costs nothing.
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

function readExistingConversation(conversationId) {
  if (!conversationId) return null;
  const filePath = join(conversationsDir(), `${sanitizeConversationId(conversationId)}.json`);
  if (!existsSync(filePath)) return null;
  try {
    const parsed = JSON.parse(readFileSync(filePath, "utf8"));
    if (typeof parsed.hostPid === "number" && isProcessAlive(parsed.hostPid)) {
      return parsed;
    }
  } catch {
    // Ignore malformed file
  }
  return null;
}

/**
 * Resolves the session host PID (`agy` process) that owns this conversation.
 * Fast-paths when an existing live conversation record is already on disk so we
 * never pay `powershell.exe` startup cost on empty-inbox turns.
 */
function resolveSessionHostPid(existingConv, workspaceInboxes) {
  if (existingConv && typeof existingConv.hostPid === "number" && isProcessAlive(existingConv.hostPid)) {
    return existingConv.hostPid;
  }
  const direct = workspaceInboxes.find((r) => r.ppid === process.ppid);
  if (direct) return process.ppid;
  if (workspaceInboxes.length > 0) {
    const parent = hostParentPid();
    if (parent !== null && workspaceInboxes.some((r) => r.ppid === parent)) {
      return parent;
    }
  }
  return process.ppid;
}

function writeConversationState({
  conversationId,
  workspacePath,
  hostPid,
  state,
  existingConv,
  lastWokenMessageId,
  lastWokenKey,
}) {
  if (!conversationId || !workspacePath) return;
  try {
    const dir = conversationsDir();
    mkdirSync(dir, { recursive: true });
    const filePath = join(dir, `${sanitizeConversationId(conversationId)}.json`);
    const record = {
      conversationId: String(conversationId).trim(),
      workspacePath: normalizePath(workspacePath),
      hostPid,
      state,
      lastWokenMessageId:
        lastWokenMessageId !== undefined
          ? lastWokenMessageId
          : (existingConv?.lastWokenMessageId ?? null),
      lastWokenKey:
        lastWokenKey !== undefined ? lastWokenKey : (existingConv?.lastWokenKey ?? null),
      updatedAt: Date.now(),
    };
    const payload = JSON.stringify(record, null, 2);
    const tmpPath = `${filePath}.${process.pid}.tmp`;
    try {
      writeFileSync(tmpPath, payload, "utf8");
      renameSync(tmpPath, filePath);
    } catch {
      writeFileSync(filePath, payload, "utf8");
      try { unlinkSync(tmpPath); } catch { /* ignore */ }
    }
  } catch {
    // Never fail hook execution on registry write error
  }
}

/**
 * Keeps only inbox records written by THIS session's mesh server:
 *   1. fast path — same parent as this hook (or known `knownHostPid`);
 *   2. lazy path — same parent as the hook's grandparent (shell-wrapped hooks).
 * Records without a recorded `ppid` (legacy) are treated as not ours.
 */
function filterOwnedByThisSession(candidates, knownHostPid) {
  if (candidates.length === 0) return [];
  const host = process.ppid;
  const direct = candidates.filter(
    (r) => r.ppid === host || (typeof knownHostPid === "number" && r.ppid === knownHostPid),
  );
  if (direct.length > 0) return direct;
  const hostParent = hostParentPid();
  if (hostParent === null) return [];
  return candidates.filter((r) => r.ppid === hostParent);
}

function readWorkspaceInboxes(roots) {
  const dir = inboxStateDir();
  if (!existsSync(dir)) return [];
  let entries = [];
  try {
    entries = readdirSync(dir);
  } catch {
    return [];
  }

  const matches = [];
  for (const entry of entries) {
    if (!entry.endsWith(".json")) continue;
    const fullPath = join(dir, entry);
    try {
      const parsed = JSON.parse(readFileSync(fullPath, "utf8"));
      if (typeof parsed.pid !== "number" || !isProcessAlive(parsed.pid)) {
        try { unlinkSync(fullPath); } catch { /* ignore */ }
        continue;
      }
      if (typeof parsed.cwd !== "string" || !matchesWorkspace(parsed.cwd, roots)) {
        continue;
      }
      matches.push(parsed);
    } catch {
      // Ignore malformed/transient files
    }
  }
  return matches;
}

function extractWorkspaceRoots(input) {
  const roots = [];
  if (typeof input?.cwd === "string" && input.cwd) roots.push(input.cwd);
  if (Array.isArray(input?.workspace_roots)) roots.push(...input.workspace_roots);
  if (Array.isArray(input?.workspacePaths)) roots.push(...input.workspacePaths);
  return roots;
}

/**
 * Resolves the lifecycle event name in priority order:
 *   1. `--event=<Name>` (or `--event <Name>`) CLI argument from `hooks.json`
 *   2. `input.hook_event_name || input.event` (backward compatibility)
 *   3. Antigravity protojson payload field inference (`terminationReason` -> Stop,
 *      `invocationNum` -> PreInvocation, `conversationId` -> SessionStart).
 */
function resolveEventName(argv, input) {
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i] || "";
    if (arg.startsWith("--event=")) {
      const val = arg.slice("--event=".length).trim();
      if (val) return val;
    }
    if (arg === "--event" && argv[i + 1]) {
      return String(argv[i + 1]).trim();
    }
  }
  if (typeof input?.hook_event_name === "string" && input.hook_event_name) {
    return input.hook_event_name;
  }
  if (typeof input?.event === "string" && input.event) {
    return input.event;
  }
  if (typeof input?.terminationReason === "string") return "Stop";
  if (typeof input?.invocationNum === "number") return "PreInvocation";
  if (typeof input?.conversationId === "string") return "SessionStart";
  return "";
}

function buildSendersSummary(records) {
  const senders = new Set();
  let total = 0;
  let lastMsgId = null;
  for (const r of records) {
    total += r.unreadCount || 0;
    if (typeof r.lastMessageId === "string" && r.lastMessageId) {
      lastMsgId = r.lastMessageId;
    }
    if (Array.isArray(r.preview)) {
      for (const item of r.preview) {
        if (item?.from) senders.add(item.from);
        if (!lastMsgId && item?.id) lastMsgId = item.id;
      }
    }
  }
  const fromPart = senders.size > 0 ? ` from ${Array.from(senders).join(", ")}` : "";
  return { total, fromPart, lastMsgId };
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
  const eventName = resolveEventName(process.argv.slice(2), input);
  const roots = extractWorkspaceRoots(input);
  const primaryWorkspace = roots[0] || process.cwd();
  const conversationId =
    typeof input?.conversationId === "string" && input.conversationId.trim()
      ? input.conversationId.trim()
      : null;

  const existingConv = readExistingConversation(conversationId);
  const workspaceInboxes = readWorkspaceInboxes(roots);
  const hostPid = resolveSessionHostPid(existingConv, workspaceInboxes);
  const unreadCandidates = workspaceInboxes.filter(
    (r) => typeof r.unreadCount === "number" && r.unreadCount > 0,
  );
  const unreadRecords = filterOwnedByThisSession(unreadCandidates, hostPid);

  if (unreadRecords.length === 0) {
    if (conversationId) {
      const nextState = eventName === "Stop" ? "idle" : "busy";
      writeConversationState({
        conversationId,
        workspacePath: primaryWorkspace,
        hostPid,
        state: nextState,
        existingConv,
      });
    }
    process.stdout.write("{}\n");
    return;
  }

  const { total, fromPart, lastMsgId } = buildSendersSummary(unreadRecords);
  const msgText =
    `📨 [remote-pi mesh] You have ${total} unread mesh message(s) waiting${fromPart}. ` +
    `Call \`get_messages\` on the \`remote-pi-mesh\` MCP server now to read and handle them.`;
  const wokenKey = conversationId ? `${conversationId}:${lastMsgId ?? ""}:${total}` : null;

  if (eventName === "PreInvocation") {
    if (conversationId) {
      writeConversationState({
        conversationId,
        workspacePath: primaryWorkspace,
        hostPid,
        state: "busy",
        existingConv,
        lastWokenMessageId: lastMsgId,
        lastWokenKey: wokenKey,
      });
    }
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
      if (conversationId) {
        writeConversationState({
          conversationId,
          workspacePath: primaryWorkspace,
          hostPid,
          state: "busy",
          existingConv,
          lastWokenMessageId: lastMsgId,
          lastWokenKey: wokenKey,
        });
      }
      process.stdout.write(
        JSON.stringify({
          decision: "continue",
          reason: msgText,
        }) + "\n",
      );
      return;
    }

    if (conversationId) {
      writeConversationState({
        conversationId,
        workspacePath: primaryWorkspace,
        hostPid,
        state: "idle",
        existingConv,
      });
    }
    process.stdout.write("{}\n");
    return;
  }

  if (conversationId) {
    writeConversationState({
      conversationId,
      workspacePath: primaryWorkspace,
      hostPid,
      state: "busy",
      existingConv,
    });
  }
  process.stdout.write("{}\n");
}

main().catch(() => {
  process.stdout.write("{}\n");
});
