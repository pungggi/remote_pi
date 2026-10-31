#!/usr/bin/env node
/**
 * Antigravity (agy) native sidecar daemon for the remote-pi agent mesh.
 *
 * Watches `~/.pi/piper/sessions/local/inbox/` and
 * `~/.pi/piper/sessions/local/conversations/` for unread mesh messages targeting
 * idle Antigravity sessions, and wakes the owning conversation via:
 *   `agentapi send-message <conversationId> <notification>`
 */

import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  watch,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";

const DEBOUNCE_MS = 100;
const FALLBACK_POLL_MS = 2_000;
const AGENTAPI_TIMEOUT_MS = 10_000;
const PENDING_WAKE_TTL_MS = AGENTAPI_TIMEOUT_MS + 5_000;

function inboxStateDir() {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  return join(root, ".pi", "piper", "sessions", "local", "inbox");
}

function conversationsDir() {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  return join(root, ".pi", "piper", "sessions", "local", "conversations");
}

function sidecarDataFilePath() {
  const dataDir = process.env["ANTIGRAVITY_EXECUTABLE_DATA_DIR"];
  if (!dataDir) return null;
  return join(dataDir, "woken_state.json");
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

function safeUnlink(filePath) {
  try {
    unlinkSync(filePath);
  } catch {
    // Ignore
  }
}

function loadPersistedWokenMap() {
  const filePath = sidecarDataFilePath();
  if (!filePath || !existsSync(filePath)) return new Map();
  try {
    const raw = JSON.parse(readFileSync(filePath, "utf8"));
    if (raw && typeof raw === "object" && !Array.isArray(raw)) {
      return new Map(Object.entries(raw));
    }
  } catch {
    // Ignore malformed file
  }
  return new Map();
}

function savePersistedWokenMap(map) {
  const filePath = sidecarDataFilePath();
  if (!filePath) return;
  try {
    mkdirSync(resolve(filePath, ".."), { recursive: true });
    const obj = Object.fromEntries(map.entries());
    const payload = JSON.stringify(obj, null, 2);
    const tmpPath = `${filePath}.${process.pid}.tmp`;
    writeFileSync(tmpPath, payload, "utf8");
    renameSync(tmpPath, filePath);
  } catch {
    // Ignore persistence errors
  }
}

function parsePendingWake(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  if (
    typeof raw.key !== "string" ||
    !raw.key ||
    typeof raw.pid !== "number" ||
    typeof raw.claimedAt !== "number"
  ) {
    return null;
  }
  return {
    key: raw.key,
    pid: raw.pid,
    claimedAt: raw.claimedAt,
  };
}

function isPendingWakeActive(claim, dedupKey) {
  if (!claim || claim.key !== dedupKey) return false;
  if (Date.now() - claim.claimedAt > PENDING_WAKE_TTL_MS) return false;
  return isProcessAlive(claim.pid);
}

function readSingleConversation(fullPath) {
  try {
    const parsed = JSON.parse(readFileSync(fullPath, "utf8"));
    if (
      typeof parsed.conversationId !== "string" ||
      !parsed.conversationId.trim() ||
      typeof parsed.workspacePath !== "string" ||
      typeof parsed.hostPid !== "number"
    ) {
      return null;
    }
    if (!isProcessAlive(parsed.hostPid)) {
      safeUnlink(fullPath);
      return null;
    }
    return {
      filePath: fullPath,
      conversationId: parsed.conversationId.trim(),
      workspacePath: normalizePath(parsed.workspacePath),
      hostPid: parsed.hostPid,
      state: parsed.state === "busy" ? "busy" : "idle",
      lastWokenMessageId:
        typeof parsed.lastWokenMessageId === "string" ? parsed.lastWokenMessageId : null,
      lastWokenKey: typeof parsed.lastWokenKey === "string" ? parsed.lastWokenKey : null,
      pendingWake: parsePendingWake(parsed.pendingWake),
      updatedAt: typeof parsed.updatedAt === "number" ? parsed.updatedAt : 0,
    };
  } catch {
    return null;
  }
}

function readLiveConversations() {
  const dir = conversationsDir();
  if (!existsSync(dir)) return [];
  let entries = [];
  try {
    entries = readdirSync(dir);
  } catch {
    return [];
  }

  const results = [];
  for (const entry of entries) {
    if (!entry.endsWith(".json")) continue;
    const conv = readSingleConversation(join(dir, entry));
    if (conv) results.push(conv);
  }
  results.sort((a, b) => b.updatedAt - a.updatedAt);
  return results;
}

function readSingleUnreadInbox(fullPath) {
  try {
    const parsed = JSON.parse(readFileSync(fullPath, "utf8"));
    if (typeof parsed.pid !== "number" || !isProcessAlive(parsed.pid)) {
      safeUnlink(fullPath);
      return null;
    }
    if (typeof parsed.unreadCount !== "number" || parsed.unreadCount <= 0) {
      return null;
    }
    if (typeof parsed.cwd !== "string" || typeof parsed.name !== "string") {
      return null;
    }
    return { ...parsed, filePath: fullPath };
  } catch {
    return null;
  }
}

function readUnreadInboxes() {
  const dir = inboxStateDir();
  if (!existsSync(dir)) return [];
  let entries = [];
  try {
    entries = readdirSync(dir);
  } catch {
    return [];
  }

  const results = [];
  for (const entry of entries) {
    if (!entry.endsWith(".json")) continue;
    const inbox = readSingleUnreadInbox(join(dir, entry));
    if (inbox) results.push(inbox);
  }
  return results;
}

function matchConversation(inbox, conversations) {
  const normCwd = normalizePath(inbox.cwd);
  const candidates = conversations.filter((c) => c.workspacePath === normCwd);
  if (candidates.length === 0) return null;

  if (typeof inbox.ppid === "number" && inbox.ppid > 0) {
    return candidates.find((c) => c.hostPid === inbox.ppid) || null;
  }
  if (!String(inbox.name).startsWith("agy")) {
    return null;
  }
  return candidates.length === 1 ? candidates[0] : null;
}

function buildWakeNotification(inbox) {
  const senders = new Set();
  const previews = [];
  if (Array.isArray(inbox.preview)) {
    for (const item of inbox.preview) {
      if (item?.from) senders.add(item.from);
      if (item?.bodyPreview) {
        previews.push(`[from ${item.from}]: ${item.bodyPreview}`);
      }
    }
  }
  const fromPart = senders.size > 0 ? ` from ${Array.from(senders).join(", ")}` : "";
  const previewBlock = previews.length > 0 ? `\nPreview:\n${previews.join("\n")}\n` : " ";
  return (
    `📨 [remote-pi mesh] ${inbox.unreadCount} unread mesh message(s) arrived${fromPart}.${previewBlock}` +
    `Call \`get_messages\` on the \`remote-pi-mesh\` MCP server now to read and handle them.`
  );
}

function resolveAgentApiInvocation(conversationId, notification) {
  const exe = (process.env["ANTIGRAVITY_AGENTAPI_EXE"] || "").trim();
  const file = exe || (process.platform === "win32" ? "agy.exe" : "agentapi");
  const base = basename(file).toLowerCase();
  const isStandaloneAgentApi =
    base === "agentapi" ||
    base === "agentapi.exe" ||
    base.startsWith("agentapi-") ||
    base.startsWith("agentapi_");
  const usesSubcommand =
    !isStandaloneAgentApi &&
    (Boolean(exe) || base === "agy.exe" || base === "agy" || base.startsWith("language_server"));
  const subArgs = usesSubcommand
    ? ["agentapi", "send-message", conversationId, notification]
    : ["send-message", conversationId, notification];
  if (base.endsWith(".mjs") || base.endsWith(".cjs") || base.endsWith(".js")) {
    return {
      file: process.execPath,
      args: [file, ...subArgs],
    };
  }
  return { file, args: subArgs };
}

/**
 * Re-reads `filePath` from disk before writing updates so any concurrent
 * `state: "busy"` transition written by `PreInvocation` is preserved.
 */
function updateConversationFile(filePath, fallbackConv, patch) {
  try {
    const current = readSingleConversation(filePath) || fallbackConv;
    if (!current) return;
    const updated = {
      conversationId: current.conversationId,
      workspacePath: current.workspacePath,
      hostPid: current.hostPid,
      state: patch.state !== undefined ? patch.state : current.state,
      lastWokenMessageId:
        patch.lastWokenMessageId !== undefined
          ? patch.lastWokenMessageId
          : current.lastWokenMessageId,
      lastWokenKey:
        patch.lastWokenKey !== undefined ? patch.lastWokenKey : current.lastWokenKey,
      pendingWake:
        patch.pendingWake !== undefined ? patch.pendingWake : current.pendingWake,
      updatedAt: Date.now(),
    };
    const payload = JSON.stringify(updated, null, 2);
    const tmpPath = `${filePath}.${process.pid}.tmp`;
    try {
      writeFileSync(tmpPath, payload, "utf8");
      renameSync(tmpPath, filePath);
    } catch {
      writeFileSync(filePath, payload, "utf8");
      safeUnlink(tmpPath);
    }
  } catch {
    // Ignore write failure
  }
}

const wokenMap = loadPersistedWokenMap();

function checkAndWakeAll() {
  const inboxes = readUnreadInboxes();
  if (inboxes.length === 0) return;

  const conversations = readLiveConversations();
  if (conversations.length === 0) return;

  for (const rawInbox of inboxes) {
    // Re-read the inbox file on each iteration in case an earlier iteration's
    // blocking execFileSync gave this session time to drain its inbox.
    const inbox = readSingleUnreadInbox(rawInbox.filePath);
    if (!inbox) continue;

    const matched = matchConversation(inbox, conversations);
    if (!matched) continue;

    // Re-read the conversation record right before claiming to observe the
    // freshest `state`, `lastWokenKey`, and `pendingWake` on disk.
    const conv = readSingleConversation(matched.filePath);
    if (!conv || conv.state !== "idle") continue;

    const previewArr = Array.isArray(inbox.preview) ? inbox.preview : [];
    const fallbackId = previewArr.length > 0 ? previewArr[previewArr.length - 1]?.id : null;
    const lastMsgId =
      typeof inbox.lastMessageId === "string" && inbox.lastMessageId
        ? inbox.lastMessageId
        : (fallbackId || "");
    const dedupKey = `${conv.conversationId}:${lastMsgId}:${inbox.unreadCount}`;

    if (
      conv.lastWokenKey === dedupKey ||
      wokenMap.get(conv.conversationId) === dedupKey ||
      isPendingWakeActive(conv.pendingWake, dedupKey)
    ) {
      continue;
    }

    // Record a PID-scoped `pendingWake` claim BEFORE calling execFileSync so
    // the 300ms MCP fallback does not double-send while agentapi runs, while
    // ensuring that if this sidecar crashes before execFileSync completes,
    // `isProcessAlive(pendingWake.pid)` becomes false and the wake is retried.
    updateConversationFile(conv.filePath, conv, {
      pendingWake: {
        key: dedupKey,
        pid: process.pid,
        claimedAt: Date.now(),
      },
    });

    const notification = buildWakeNotification(inbox);
    const { file, args } = resolveAgentApiInvocation(conv.conversationId, notification);
    try {
      execFileSync(file, args, {
        encoding: "utf8",
        env: process.env,
        timeout: AGENTAPI_TIMEOUT_MS,
        stdio: ["ignore", "pipe", "pipe"],
      });
      wokenMap.set(conv.conversationId, dedupKey);
      savePersistedWokenMap(wokenMap);
      updateConversationFile(conv.filePath, conv, {
        lastWokenMessageId: lastMsgId || null,
        lastWokenKey: dedupKey,
        pendingWake: null,
      });
    } catch (err) {
      const afterErr = readSingleConversation(conv.filePath);
      if (afterErr && afterErr.pendingWake?.pid === process.pid) {
        updateConversationFile(conv.filePath, afterErr, {
          pendingWake: null,
        });
      }
      process.stderr.write(
        `[remote-pi-mesh watcher] agentapi send-message failed for ${conv.conversationId}: ${err instanceof Error ? err.message : String(err)}\n`,
      );
    }
  }
}

function main() {
  const once = process.argv.includes("--once");
  const inDir = inboxStateDir();
  const convDir = conversationsDir();
  mkdirSync(inDir, { recursive: true });
  mkdirSync(convDir, { recursive: true });

  checkAndWakeAll();
  if (once) return;

  let debounceTimer = null;
  const scheduleCheck = (_eventType, filename) => {
    if (filename && !String(filename).endsWith(".json")) {
      // Ignore atomic write temp files (*.tmp)
      return;
    }
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      debounceTimer = null;
      checkAndWakeAll();
    }, DEBOUNCE_MS);
  };

  const inWatcher = watch(inDir, scheduleCheck);
  const convWatcher = watch(convDir, scheduleCheck);
  const pollInterval = setInterval(checkAndWakeAll, FALLBACK_POLL_MS);

  const shutdown = () => {
    if (debounceTimer) clearTimeout(debounceTimer);
    clearInterval(pollInterval);
    try { inWatcher.close(); } catch { /* ignore */ }
    try { convWatcher.close(); } catch { /* ignore */ }
    process.exit(0);
  };

  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main();
