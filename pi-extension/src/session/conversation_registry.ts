import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import {
  isProcessAlive,
  normalizeWorkspacePath,
  type InboxStateRecord,
} from "../mcp/inbox_state.js";

export type ConversationTurnState = "busy" | "idle";

const AGENTAPI_TIMEOUT_MS = 10_000;

export interface ConversationRecord {
  readonly conversationId: string;
  readonly workspacePath: string;
  readonly hostPid: number;
  readonly state: ConversationTurnState;
  readonly lastWokenMessageId: string | null;
  readonly lastWokenKey: string | null;
  readonly updatedAt: number;
}

export interface WriteConversationRecordParams {
  readonly conversationId: string;
  readonly workspacePath: string;
  readonly hostPid: number;
  readonly state?: ConversationTurnState;
  readonly lastWokenMessageId?: string | null;
  readonly lastWokenKey?: string | null;
  readonly updatedAt?: number;
}

/**
 * Directory holding active Antigravity conversation registry files.
 * Resolved at call time so tests can isolate via `REMOTE_PI_HOME`.
 */
export function conversationsDir(): string {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  return join(root, ".pi", "piper", "sessions", "local", "conversations");
}

function sanitizeConversationId(conversationId: string): string {
  const trimmed = conversationId.trim();
  if (!trimmed) {
    throw new Error("conversationId must not be empty");
  }
  return trimmed.replace(/[^a-zA-Z0-9_-]/g, "_");
}

/**
 * Deterministic registry file path for a `conversationId`.
 */
export function conversationFilePath(conversationId: string): string {
  const safeId = sanitizeConversationId(conversationId);
  return join(conversationsDir(), `${safeId}.json`);
}

/**
 * Builds the deterministic deduplication key for a wakeup event.
 */
export function buildWakeDedupKey(
  conversationId: string,
  lastMessageId: string | null,
  unreadCount: number,
): string {
  return `${conversationId}:${lastMessageId ?? ""}:${unreadCount}`;
}

export function removeConversationRecord(filePath: string | null | undefined): void {
  if (!filePath) return;
  try {
    unlinkSync(filePath);
  } catch {
    // Already removed or never written.
  }
}

function parseConversationFile(fullPath: string): ConversationRecord | null {
  try {
    const parsed = JSON.parse(readFileSync(fullPath, "utf8")) as Partial<ConversationRecord>;
    if (
      typeof parsed.conversationId !== "string" ||
      !parsed.conversationId.trim() ||
      typeof parsed.workspacePath !== "string" ||
      !parsed.workspacePath.trim() ||
      typeof parsed.hostPid !== "number"
    ) {
      return null;
    }
    if (!isProcessAlive(parsed.hostPid)) {
      removeConversationRecord(fullPath);
      return null;
    }
    const state: ConversationTurnState = parsed.state === "busy" ? "busy" : "idle";
    return {
      conversationId: parsed.conversationId,
      workspacePath: normalizeWorkspacePath(parsed.workspacePath),
      hostPid: parsed.hostPid,
      state,
      lastWokenMessageId:
        typeof parsed.lastWokenMessageId === "string" ? parsed.lastWokenMessageId : null,
      lastWokenKey: typeof parsed.lastWokenKey === "string" ? parsed.lastWokenKey : null,
      updatedAt: typeof parsed.updatedAt === "number" ? parsed.updatedAt : 0,
    };
  } catch {
    return null;
  }
}

/**
 * Reads a single conversation record if it exists and its `hostPid` is still alive.
 */
export function readConversationRecord(conversationId: string): ConversationRecord | null {
  const filePath = conversationFilePath(conversationId);
  if (!existsSync(filePath)) return null;
  return parseConversationFile(filePath);
}

/**
 * Atomically writes or updates a conversation registry record.
 * Preserves existing `lastWokenMessageId` / `lastWokenKey` when omitted so
 * lifecycle hook updates do not erase wakeup deduplication state.
 */
export function writeConversationRecord(params: WriteConversationRecordParams): string {
  mkdirSync(conversationsDir(), { recursive: true });
  const filePath = conversationFilePath(params.conversationId);
  const existing = existsSync(filePath) ? parseConversationFile(filePath) : null;

  const record: ConversationRecord = {
    conversationId: params.conversationId.trim(),
    workspacePath: normalizeWorkspacePath(params.workspacePath),
    hostPid: params.hostPid,
    state: params.state ?? existing?.state ?? "idle",
    lastWokenMessageId:
      params.lastWokenMessageId !== undefined
        ? params.lastWokenMessageId
        : (existing?.lastWokenMessageId ?? null),
    lastWokenKey:
      params.lastWokenKey !== undefined ? params.lastWokenKey : (existing?.lastWokenKey ?? null),
    updatedAt: params.updatedAt ?? Date.now(),
  };

  const payload = JSON.stringify(record, null, 2);
  const tmpPath = `${filePath}.${process.pid}.tmp`;
  try {
    writeFileSync(tmpPath, payload, "utf8");
    renameSync(tmpPath, filePath);
  } catch {
    writeFileSync(filePath, payload, "utf8");
    removeConversationRecord(tmpPath);
  }
  return filePath;
}

export function writeConversationRecordSafe(
  params: WriteConversationRecordParams,
): string | null {
  try {
    return writeConversationRecord(params);
  } catch {
    return null;
  }
}

/**
 * Lists all live conversation records, automatically pruning records whose
 * `hostPid` is no longer alive. Sorted by `updatedAt` descending.
 */
export function listLiveConversations(): ConversationRecord[] {
  const dir = conversationsDir();
  if (!existsSync(dir)) return [];

  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return [];
  }

  const records: ConversationRecord[] = [];
  for (const entry of entries) {
    if (!entry.endsWith(".json")) continue;
    const record = parseConversationFile(join(dir, entry));
    if (record) records.push(record);
  }
  records.sort((a, b) => b.updatedAt - a.updatedAt);
  return records;
}

/**
 * Finds the active Antigravity conversation corresponding to an inbox record.
 *
 * Matches by canonicalized `workspacePath` AND session host PID (`hostPid === inbox.ppid`)
 * so coexisting agents in the same folder (`pi`, `claude`, `agy`, `agy#2`) never
 * cross-trigger each other's conversation wakeup.
 */
export function findConversationForInbox(
  inbox: Pick<InboxStateRecord, "cwd" | "ppid" | "name">,
): ConversationRecord | null {
  const normCwd = normalizeWorkspacePath(inbox.cwd);
  const candidates = listLiveConversations().filter((c) => c.workspacePath === normCwd);
  if (candidates.length === 0) return null;

  if (typeof inbox.ppid === "number" && inbox.ppid > 0) {
    const exactHostMatch = candidates.find((c) => c.hostPid === inbox.ppid);
    return exactHostMatch ?? null;
  }

  if (!inbox.name.startsWith("agy")) {
    return null;
  }
  return candidates.length === 1 ? (candidates[0] ?? null) : null;
}

/**
 * Records that `conversationId` has been woken for `(lastMessageId, unreadCount)`.
 */
export function markConversationWoken(
  conversationId: string,
  lastMessageId: string | null,
  unreadCount: number,
): ConversationRecord | null {
  const existing = readConversationRecord(conversationId);
  if (!existing) return null;
  const dedupKey = buildWakeDedupKey(conversationId, lastMessageId, unreadCount);
  writeConversationRecordSafe({
    conversationId: existing.conversationId,
    workspacePath: existing.workspacePath,
    hostPid: existing.hostPid,
    state: existing.state,
    lastWokenMessageId: lastMessageId,
    lastWokenKey: dedupKey,
  });
  return readConversationRecord(conversationId);
}

/**
 * Formats the prompt injected via `agentapi send-message` when waking an idle
 * Antigravity conversation.
 */
export function buildWakeNotificationMessage(
  inbox: Pick<InboxStateRecord, "unreadCount" | "preview">,
): string {
  const senders = new Set<string>();
  const previews: string[] = [];
  for (const item of inbox.preview) {
    if (item.from) senders.add(item.from);
    if (item.bodyPreview) {
      previews.push(`[from ${item.from}]: ${item.bodyPreview}`);
    }
  }
  const fromPart = senders.size > 0 ? ` from ${Array.from(senders).join(", ")}` : "";
  const previewBlock = previews.length > 0 ? `\nPreview:\n${previews.join("\n")}\n` : " ";
  return (
    `📨 [remote-pi mesh] ${inbox.unreadCount} unread mesh message(s) arrived${fromPart}.${previewBlock}` +
    `Call \`get_messages\` on the \`remote-pi-mesh\` MCP server now to read and handle them.`
  );
}

/**
 * Resolves the executable and argument list for `agentapi send-message` without
 * using `shell: true` (preventing command injection on Windows when message
 * previews contain shell metacharacters).
 *
 * When `ANTIGRAVITY_AGENTAPI_EXE` is provided by Antigravity's `SidecarManager`,
 * it points to the language server / `agy` executable where `agentapi` is a
 * subcommand (`["agentapi", "send-message", ...]`), unless the binary itself is
 * a standalone `agentapi` shim.
 */
export function resolveAgentApiInvocation(
  conversationId: string,
  notification: string,
  env: NodeJS.ProcessEnv = process.env,
  platform: NodeJS.Platform = process.platform,
): { readonly file: string; readonly args: readonly string[] } {
  const exe = env["ANTIGRAVITY_AGENTAPI_EXE"]?.trim();
  const file = exe || (platform === "win32" ? "agy.exe" : "agentapi");
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
 * Invokes `agentapi send-message <conversationId> <notification>` via `execFileSync`.
 */
export function invokeAgentApiSendMessage(
  conversationId: string,
  notification: string,
  env: NodeJS.ProcessEnv = process.env,
): void {
  const { file, args } = resolveAgentApiInvocation(conversationId, notification, env);
  execFileSync(file, args, {
    encoding: "utf8",
    env,
    timeout: AGENTAPI_TIMEOUT_MS,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

/**
 * Checks whether `inbox` belongs to an `idle` Antigravity conversation that has
 * not yet been woken for its latest unread state, and if so claims the wake key
 * on disk before invoking `agentapi` (rolling back the claim if `agentapi` fails).
 */
export function maybeWakeIdleConversationForInbox(
  inbox: InboxStateRecord,
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  if (inbox.unreadCount <= 0) return false;
  const conv = findConversationForInbox(inbox);
  if (!conv || conv.state !== "idle") return false;

  const lastMsgId =
    inbox.lastMessageId ??
    (inbox.preview.length > 0 ? (inbox.preview[inbox.preview.length - 1]?.id ?? null) : null);
  const dedupKey = buildWakeDedupKey(conv.conversationId, lastMsgId, inbox.unreadCount);
  if (conv.lastWokenKey === dedupKey) return false;

  // Claim the wake key BEFORE invoking agentapi so a concurrent sidecar or
  // fallback timer sees `lastWokenKey === dedupKey` while agentapi is running.
  const prevWokenId = conv.lastWokenMessageId;
  const prevWokenKey = conv.lastWokenKey;
  markConversationWoken(conv.conversationId, lastMsgId, inbox.unreadCount);

  const notification = buildWakeNotificationMessage(inbox);
  try {
    invokeAgentApiSendMessage(conv.conversationId, notification, env);
    return true;
  } catch (err) {
    // Roll back the woken claim on failure while preserving any `state` update
    // (e.g. `PreInvocation` setting `state: "busy"`) that occurred in the meantime.
    const current = readConversationRecord(conv.conversationId);
    if (current && current.lastWokenKey === dedupKey) {
      writeConversationRecordSafe({
        conversationId: current.conversationId,
        workspacePath: current.workspacePath,
        hostPid: current.hostPid,
        state: current.state,
        lastWokenMessageId: prevWokenId,
        lastWokenKey: prevWokenKey,
      });
    }
    throw err;
  }
}
