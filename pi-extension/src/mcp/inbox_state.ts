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
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { roomIdFor } from "../rooms.js";

const MAX_PREVIEW_ITEMS = 5;
const MAX_BODY_PREVIEW_CHARS = 120;

export const DEFAULT_WAIT_TIMEOUT_MS = 30_000;
export const MIN_WAIT_TIMEOUT_MS = 50;
export const MAX_WAIT_TIMEOUT_MS = 3_600_000;

export interface InboxMessageLike {
  readonly id: string;
  readonly from: string;
  readonly body: unknown;
  readonly re: string | null;
  readonly at: string;
}

export interface InboxPreviewItem {
  readonly id: string;
  readonly from: string;
  readonly re: string | null;
  readonly at: string;
  readonly bodyPreview: string;
}

export interface InboxStateRecord {
  readonly pid: number;
  /**
   * Parent PID of the process that wrote this record (the session host, e.g.
   * the `agy` process that spawned both the mesh server and the lifecycle
   * hook). Lifecycle hooks use it to tell "my session's inbox" apart from
   * sibling sessions in the same workspace. Optional only for legacy records.
   */
  readonly ppid?: number;
  readonly cwd: string;
  readonly name: string;
  readonly address: string;
  readonly unreadCount: number;
  readonly updatedAt: number;
  readonly preview: readonly InboxPreviewItem[];
}

export interface WriteInboxStateParams {
  readonly cwd: string;
  readonly name: string;
  readonly address: string;
  readonly messages: readonly InboxMessageLike[];
  readonly pid?: number;
  /** Override the recorded parent PID (defaults to `process.ppid`). */
  readonly ppid?: number;
}

/**
 * Directory holding per-node MCP inbox state files.
 * Resolved at call time so tests can isolate via `REMOTE_PI_HOME`.
 */
export function inboxStateDir(): string {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  return join(root, ".pi", "piper", "sessions", "local", "inbox");
}

/**
 * Deterministic state file path for a `(cwd, name)` mesh node.
 */
export function inboxStatePathFor(cwd: string, name: string): string {
  const id = roomIdFor(cwd, name);
  return join(inboxStateDir(), `${id}.json`);
}

/**
 * Formats a concise single-line preview of a message body.
 */
export function formatBodyPreview(body: unknown): string {
  const raw = typeof body === "string" ? body : JSON.stringify(body) ?? String(body);
  const singleLine = raw.replace(/\s+/g, " ").trim();
  if (singleLine.length <= MAX_BODY_PREVIEW_CHARS) return singleLine;
  return `${singleLine.slice(0, MAX_BODY_PREVIEW_CHARS - 1)}…`;
}

/**
 * Checks whether a process PID is currently alive on this OS.
 */
export function isProcessAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    return code === "EPERM";
  }
}

/**
 * Canonicalizes a filesystem path for workspace comparison.
 */
export function normalizeWorkspacePath(p: string): string {
  let resolved = resolve(p);
  try {
    resolved = realpathSync(resolved);
  } catch {
    // Path may not exist on disk in synthetic tests; use resolved path.
  }
  const normalized = resolved.replace(/\\/g, "/").replace(/\/+$/, "");
  return process.platform === "win32" ? normalized.toLowerCase() : normalized;
}

function buildInboxRecord(params: WriteInboxStateParams): InboxStateRecord {
  return {
    pid: params.pid ?? process.pid,
    ppid: params.ppid ?? process.ppid,
    cwd: params.cwd,
    name: params.name,
    address: params.address,
    unreadCount: params.messages.length,
    updatedAt: Date.now(),
    preview: params.messages.slice(0, MAX_PREVIEW_ITEMS).map((m) => ({
      id: m.id,
      from: m.from,
      re: m.re,
      at: m.at,
      bodyPreview: formatBodyPreview(m.body),
    })),
  };
}

/**
 * Persists the current unread inbox state for an MCP mesh node so Antigravity
 * lifecycle hooks (`PreInvocation`, `Stop`) can inspect pending messages in <15ms.
 */
export function writeInboxState(params: WriteInboxStateParams): string {
  mkdirSync(inboxStateDir(), { recursive: true });
  const filePath = inboxStatePathFor(params.cwd, params.name);
  const payload = JSON.stringify(buildInboxRecord(params), null, 2);
  const tmpPath = `${filePath}.${process.pid}.tmp`;
  try {
    writeFileSync(tmpPath, payload, "utf8");
    renameSync(tmpPath, filePath);
  } catch {
    writeFileSync(filePath, payload, "utf8");
    removeInboxState(tmpPath);
  }
  return filePath;
}

/**
 * Non-throwing variant of {@link writeInboxState} for callers whose mesh
 * usability must not depend on disk state (e.g. the MCP mesh server's join
 * path). Returns `null` when the sidecar could not be written.
 */
export function writeInboxStateSafe(params: WriteInboxStateParams): string | null {
  try {
    return writeInboxState(params);
  } catch {
    return null;
  }
}

/**
 * Removes the inbox state file on clean shutdown.
 */
export function removeInboxState(filePath: string | null | undefined): void {
  if (!filePath) return;
  try {
    unlinkSync(filePath);
  } catch {
    // Already removed or never written.
  }
}

function matchesWorkspace(recordCwd: string, roots: readonly string[]): boolean {
  if (roots.length === 0) return true;
  const normRecord = normalizeWorkspacePath(recordCwd);
  for (const root of roots) {
    if (!root) continue;
    const normRoot = normalizeWorkspacePath(root);
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

function parseUnreadInboxFile(
  fullPath: string,
  workspaceRoots: readonly string[],
): InboxStateRecord | null {
  try {
    const parsed = JSON.parse(readFileSync(fullPath, "utf8")) as Partial<InboxStateRecord>;
    if (typeof parsed.pid !== "number" || !isProcessAlive(parsed.pid)) {
      removeInboxState(fullPath);
      return null;
    }
    if (
      typeof parsed.cwd !== "string" ||
      typeof parsed.name !== "string" ||
      typeof parsed.address !== "string" ||
      typeof parsed.unreadCount !== "number" ||
      parsed.unreadCount <= 0 ||
      !matchesWorkspace(parsed.cwd, workspaceRoots)
    ) {
      return null;
    }
    return {
      pid: parsed.pid,
      ...(typeof parsed.ppid === "number" ? { ppid: parsed.ppid } : {}),
      cwd: parsed.cwd,
      name: parsed.name,
      address: parsed.address,
      unreadCount: parsed.unreadCount,
      updatedAt: typeof parsed.updatedAt === "number" ? parsed.updatedAt : 0,
      preview: Array.isArray(parsed.preview) ? parsed.preview : [],
    };
  } catch {
    return null;
  }
}

/**
 * Reads all live inbox state records with `unreadCount > 0` matching the given
 * workspace roots. Automatically unlinks stale state files from dead PIDs.
 */
export function readUnreadInboxStates(workspaceRoots: readonly string[] = []): InboxStateRecord[] {
  const dir = inboxStateDir();
  if (!existsSync(dir)) return [];

  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return [];
  }

  const results: InboxStateRecord[] = [];
  for (const entry of entries) {
    if (!entry.endsWith(".json")) continue;
    const record = parseUnreadInboxFile(join(dir, entry), workspaceRoots);
    if (record) results.push(record);
  }
  return results;
}

export interface WaitForMessageOptions {
  readonly timeoutMs?: number;
  readonly from?: string;
  readonly re?: string;
  /**
   * MCP request abort signal. On cancellation a pending waiter is removed, and
   * a message already handed to the waiter is requeued — the SDK discards the
   * response of an aborted request, so without requeue the message would vanish
   * from `get_messages` and every later wait.
   */
  readonly signal?: AbortSignal;
}

export interface WaitForMessageResult {
  readonly status: "received" | "timeout" | "aborted";
  readonly messages: InboxMessageLike[];
}

interface PendingWaiter {
  matches(msg: InboxMessageLike): boolean;
  resolve(res: WaitForMessageResult): void;
  timer: ReturnType<typeof setTimeout>;
}

/**
 * Formats a list of incoming mesh messages for MCP tool text output.
 */
export function formatIncomingMessages(msgs: readonly InboxMessageLike[]): string {
  if (msgs.length === 0) return "(no messages)";
  return msgs
    .map(
      (m) =>
        `[${m.at}] from=${m.from}${m.re ? ` re=${m.re}` : ""}\nid=${m.id}\n${JSON.stringify(m.body, null, 2)}`,
    )
    .join("\n\n");
}

function matchesFilter(
  msg: InboxMessageLike,
  filter?: { readonly from?: string; readonly re?: string },
): boolean {
  if (!filter) return true;
  if (filter.from && msg.from !== filter.from) return false;
  if (filter.re && msg.re !== filter.re) return false;
  return true;
}

/**
 * In-memory message queue with event-driven `waitForMessage` support and
 * automatic state-file synchronization callback.
 */
export class MeshInbox {
  private readonly messages: InboxMessageLike[] = [];
  private readonly waiters = new Set<PendingWaiter>();
  private readonly onStateChange?: (messages: readonly InboxMessageLike[]) => void;
  private closed = false;

  constructor(onStateChange?: (messages: readonly InboxMessageLike[]) => void) {
    this.onStateChange = onStateChange;
  }

  count(): number {
    return this.messages.length;
  }

  peekAll(): readonly InboxMessageLike[] {
    return this.messages;
  }

  push(msg: InboxMessageLike): void {
    for (const waiter of this.waiters) {
      if (waiter.matches(msg)) {
        clearTimeout(waiter.timer);
        this.waiters.delete(waiter);
        this.notifyStateChange();
        waiter.resolve({ status: "received", messages: [msg] });
        return;
      }
    }
    this.messages.push(msg);
    this.notifyStateChange();
  }

  drainAll(): InboxMessageLike[] {
    if (this.messages.length === 0) return [];
    const drained = this.messages.splice(0);
    this.notifyStateChange();
    return drained;
  }

  private drainMatching(options: WaitForMessageOptions): InboxMessageLike[] {
    const matched: InboxMessageLike[] = [];
    for (let i = 0; i < this.messages.length; ) {
      const candidate = this.messages[i]!;
      if (matchesFilter(candidate, options)) {
        matched.push(candidate);
        this.messages.splice(i, 1);
      } else {
        i++;
      }
    }
    return matched;
  }

  waitForMessage(options: WaitForMessageOptions = {}): Promise<WaitForMessageResult> {
    const signal = options.signal;
    if (signal?.aborted) {
      return Promise.resolve({ status: "aborted", messages: [] });
    }

    const matched = this.drainMatching(options);
    if (matched.length > 0) {
      this.notifyStateChange();
      return Promise.resolve({ status: "received", messages: matched });
    }

    const rawTimeout = options.timeoutMs ?? DEFAULT_WAIT_TIMEOUT_MS;
    const timeoutMs = Math.max(MIN_WAIT_TIMEOUT_MS, Math.min(MAX_WAIT_TIMEOUT_MS, rawTimeout));

    return new Promise<WaitForMessageResult>((resolve) => {
      let consumed: InboxMessageLike[] | null = null;

      const onAbort = () => {
        if (this.closed) return;
        if (consumed) {
          // The waiter already took a message but the client cancelled: the
          // SDK will suppress our response, so put the message back where
          // get_messages / later waits can still see it.
          this.messages.unshift(...consumed);
          this.notifyStateChange();
          return;
        }
        clearTimeout(waiter.timer);
        this.waiters.delete(waiter);
        resolve({ status: "aborted", messages: [] });
      };

      const waiter: PendingWaiter = {
        matches: (msg) => matchesFilter(msg, options),
        resolve: (res) => {
          consumed = res.messages;
          // Deliberately keep the abort listener: if the client cancels in the
          // window between our resolution and the SDK sending the response,
          // onAbort must still requeue `consumed`.
          resolve(res);
        },
        timer: setTimeout(() => {
          this.waiters.delete(waiter);
          signal?.removeEventListener("abort", onAbort);
          resolve({ status: "timeout", messages: [] });
        }, timeoutMs),
      };
      waiter.timer.unref?.();
      signal?.addEventListener("abort", onAbort);
      this.waiters.add(waiter);
      // Cover the race where the signal aborted between the pre-check above
      // and addEventListener — an already-aborted signal never fires listeners.
      if (signal?.aborted) onAbort();
    });
  }

  close(): void {
    this.closed = true;
    for (const waiter of this.waiters) {
      clearTimeout(waiter.timer);
      waiter.resolve({ status: "timeout", messages: [] });
    }
    this.waiters.clear();
    this.messages.length = 0;
  }

  private notifyStateChange(): void {
    try {
      this.onStateChange?.(this.messages);
    } catch {
      // Never fail message delivery on disk state sync errors.
    }
  }
}
