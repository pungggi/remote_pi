#!/usr/bin/env node
/**
 * MCP server that bridges Claude Code and Google Antigravity (agy) to the
 * remote-pi agent mesh.
 *
 * Spawned as an MCP server subprocess (stdio).
 * Joins the mesh through the shared `MeshNode` abstraction — the SAME
 * composition the Pi extension uses — so Claude and Agy are first-class mesh
 * participants: they can lead the local UDS/Named Pipe broker when no Pi/daemon
 * is up, and (as leader) bring up their own cross-PC relay bridge with their
 * own Pi-key. As a follower they ride the existing leader's bridge.
 *
 * Launched by `remote-pi claude`, `remote-pi agy`, or the `remote-pi-mesh`
 * Antigravity plugin.
 * Args: [--cwd <path>] [--name <agentName>] [--auto-join] [--no-bridge]
 * Env: REMOTE_PI_MCP_CWD, REMOTE_PI_MCP_NAME, REMOTE_PI_MCP_AUTO_JOIN
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { MeshNode } from "../session/mesh_node.js";
import { loadLocalConfig, defaultAgentName, localConfigExists } from "../session/local_config.js";
import { formatMeshAckResult } from "./mesh_result.js";
import {
  DEFAULT_WAIT_TIMEOUT_MS,
  MAX_WAIT_TIMEOUT_MS,
  MIN_WAIT_TIMEOUT_MS,
  MeshInbox,
  formatIncomingMessages,
  readUnreadInboxStates,
  removeInboxState,
  writeInboxStateSafe,
  type InboxMessageLike,
} from "./inbox_state.js";
import {
  findConversationForInbox,
  maybeWakeIdleConversationForInbox,
} from "../session/conversation_registry.js";
import { sessionSockPath, sessionAuditPath, LOCAL_SESSION_NAME } from "../session/global_config.js";
import { resolveRelayUrl } from "../config.js";
import { acquireNamedCwdLock, type NamedAcquiredLock } from "../session/cwd_lock.js";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const MCP_ROOTS_TIMEOUT_MS = 1_000;
const MCP_INIT_TIMEOUT_MS = 2_000;
const JOIN_RETRY_MS = 2_000;
const MAX_JOIN_ATTEMPTS = 4;
const DIRECT_WAKE_FALLBACK_DELAY_MS = 300;
const DIRECT_WAKE_BUSY_RETRY_MS = 1_000;

// ── Args / config ─────────────────────────────────────────────────────────────

const _argv = process.argv.slice(2);
let _explicitCwd = Boolean(process.env["REMOTE_PI_MCP_CWD"]);
let _cwd = process.env["REMOTE_PI_MCP_CWD"] ?? process.cwd();
let _nameOverride = process.env["REMOTE_PI_MCP_NAME"];
let _autoJoin = process.env["REMOTE_PI_MCP_AUTO_JOIN"] === "1";
let _bridgeEnabled = true;

for (let i = 0; i < _argv.length; i++) {
  if (_argv[i] === "--cwd" && _argv[i + 1]) { _cwd = _argv[++i]!; _explicitCwd = true; }
  else if (_argv[i] === "--name" && _argv[i + 1]) { _nameOverride = _argv[++i]; }
  else if (_argv[i] === "--auto-join") { _autoJoin = true; }
  else if (_argv[i] === "--no-bridge") { _bridgeEnabled = false; }
}

function canonicalizeCwd(rawCwd: string): string {
  try {
    return realpathSync(rawCwd);
  } catch {
    return rawCwd;
  }
}

function resolveBaseAgentName(cwd: string, nameOverride?: string): string {
  const cfg = loadLocalConfig(cwd);
  return nameOverride ?? cfg.agent_name ?? defaultAgentName(cwd);
}

let _canonCwd = canonicalizeCwd(_cwd);
let _baseAgentName = resolveBaseAgentName(_cwd, _nameOverride);
let _lockedAgentName = _baseAgentName;

const BROKER_SOCK = sessionSockPath(LOCAL_SESSION_NAME);
const AUDIT_PATH = sessionAuditPath(LOCAL_SESSION_NAME);
const { url: relayUrl } = resolveRelayUrl();

function logErr(msg: string): void {
  process.stderr.write(`[remote-pi-mesh ${isoNow()}] ${msg}\n`);
}

process.on("unhandledRejection", (reason) => {
  logErr(`unhandledRejection: ${reason instanceof Error ? (reason.stack ?? reason.message) : String(reason)}`);
});
process.on("uncaughtException", (err) => {
  logErr(`uncaughtException: ${err.stack ?? err.message}`);
});

// ── Incoming message buffer + state file sync ─────────────────────────────────

let _mesh: MeshNode | null = null;
let _inboxStatePath: string | null = null;
let _fallbackWakeTimer: ReturnType<typeof setTimeout> | null = null;

function clearFallbackWakeTimer(): void {
  if (_fallbackWakeTimer) {
    clearTimeout(_fallbackWakeTimer);
    _fallbackWakeTimer = null;
  }
}

function scheduleFallbackAgentApiWake(delayMs = DIRECT_WAKE_FALLBACK_DELAY_MS): void {
  if (_shuttingDown) return;
  if (!process.env["ANTIGRAVITY_LS_ADDRESS"] && !process.env["ANTIGRAVITY_AGENTAPI_EXE"]) {
    return;
  }
  clearFallbackWakeTimer();
  _fallbackWakeTimer = setTimeout(() => {
    _fallbackWakeTimer = null;
    if (_shuttingDown || inbox.count() === 0) return;
    try {
      const states = readUnreadInboxStates([_canonCwd]);
      const mine = states.find((s) => s.pid === process.pid);
      if (!mine || mine.unreadCount <= 0) return;

      const woken = maybeWakeIdleConversationForInbox(mine);
      if (woken) return;

      // If the conversation is currently busy (e.g. a message arrived mid-turn)
      // and that turn later ends without draining (such as `USER_CANCELLED`),
      // re-check after the turn transitions back to `idle`.
      const conv = findConversationForInbox(mine);
      if (conv && conv.state === "busy" && inbox.count() > 0 && !_shuttingDown) {
        scheduleFallbackAgentApiWake(DIRECT_WAKE_BUSY_RETRY_MS);
      }
    } catch {
      // Best-effort fallback when SidecarManager is inactive (e.g. standalone agy CLI).
    }
  }, delayMs);
  _fallbackWakeTimer.unref?.();
}

function syncInboxState(messages: readonly InboxMessageLike[]): void {
  const address = _mesh?.address() ?? `${_canonCwd}@${_lockedAgentName}`;
  const path = writeInboxStateSafe({
    cwd: _canonCwd,
    name: _lockedAgentName,
    address,
    messages,
  });
  if (path === null) {
    // The sidecar only feeds Antigravity lifecycle hooks — it must never take
    // the connected mesh down (a throw here previously landed in the join
    // catch AFTER _joined was set, permanently disabling every mesh tool).
    logErr("inbox sidecar write failed — hooks cannot see unread messages until it succeeds");
    return;
  }
  _inboxStatePath = path;
  if (messages.length > 0) {
    scheduleFallbackAgentApiWake();
  } else {
    clearFallbackWakeTimer();
  }
}

const inbox = new MeshInbox((messages) => {
  syncInboxState(messages);
});

let meshReady = false;
let degradedReason = "connecting to the mesh…";

// ── MCP server setup ──────────────────────────────────────────────────────────

const mcp = new McpServer(
  { name: "remote-pi-mesh", version: "0.8.0" },
  {
    capabilities: { experimental: { "claude/channel": {} } },
    instructions: [
      `You are connected to the remote-pi agent mesh in "${_canonCwd}" (base name "${_baseAgentName}").`,
      "At the start of each turn (or when notified by hook/channel) call get_messages to check for incoming messages from other agents.",
      "Use list_peers to discover available agents and mesh_status to inspect your own canonical mesh address.",
      "Use agent_send to send messages — pass the exact address returned by list_peers (form `<cwd>@<name>`, `<pc>:` prefix cross-PC) VERBATIM; never build one by hand.",
      "Use wait_for_message when you have sent a request to another agent and want to block until their reply arrives.",
      'Use "broadcast" as the target to send to all peers in your folder (cwd) at once.',
      "Follow the agent-network protocol for ACK statuses, replies via re, `<cwd>@<name>` addresses, and cross-PC `<pc>:` prefixes.",
    ].join("\n"),
  },
);

function notReady() {
  return {
    content: [{ type: "text" as const, text: `Mesh not available yet — ${degradedReason}` }],
    isError: true,
  };
}

mcp.registerTool("list_peers", {
  description: "List all agents currently in the mesh (local + remote PCs).",
  inputSchema: {},
}, async () => {
  if (!meshReady || !_mesh) return notReady();
  try {
    const peers = await _mesh.listPeers();
    return { content: [{ type: "text" as const, text: peers.length > 0 ? peers.join("\n") : "(no peers)" }] };
  } catch (e) {
    return { content: [{ type: "text" as const, text: `list_peers failed: ${String(e)}` }], isError: true };
  }
});

mcp.registerTool("mesh_status", {
  description: "Return this agent's canonical mesh address, role, bridge status, and unread inbox count.",
  inputSchema: {},
}, async () => {
  const status = {
    joined: meshReady,
    name: _lockedAgentName,
    cwd: _canonCwd,
    address: _mesh?.address() ?? `${_canonCwd}@${_lockedAgentName}`,
    role: _mesh?.currentRole() ?? null,
    hasBridge: _mesh?.hasBridge() ?? false,
    unreadCount: inbox.count(),
    statusReason: meshReady ? "connected" : degradedReason,
  };
  return {
    content: [{ type: "text" as const, text: JSON.stringify(status, null, 2) }],
  };
});

mcp.registerTool("agent_send", {
  description: 'Send a message to another agent. Use "broadcast" to send to all peers.',
  inputSchema: {
    to: z.string().describe('Peer address from list_peers (form "<cwd>@<name>", or "<pc>:<cwd>@<name>" cross-PC) echoed verbatim, or "broadcast"'),
    body: z.unknown().describe("Message body — any JSON value"),
    re: z.string().optional().describe("Optional: id of the message you are replying to"),
  },
}, async ({ to, body, re }) => {
  if (!meshReady || !_mesh) return notReady();
  if (to === _mesh.address() || to === _mesh.name()) {
    return { content: [{ type: "text" as const, text: "Cannot send to yourself" }], isError: true };
  }
  try {
    if (to === "broadcast") {
      await _mesh.send(to, body, re ?? null);
      return { content: [{ type: "text" as const, text: "Broadcast sent" }] };
    }
    const ack = await _mesh.sendWithAck(to, body, re ?? null);
    return formatMeshAckResult(to, ack);
  } catch (e) {
    return { content: [{ type: "text" as const, text: `send failed: ${String(e)}` }], isError: true };
  }
});

mcp.registerTool("get_messages", {
  description: "Return and clear all pending incoming messages from other agents. Call at the start of each turn or when notified.",
  inputSchema: {},
}, async () => {
  const msgs = inbox.drainAll();
  return { content: [{ type: "text" as const, text: formatIncomingMessages(msgs) }] };
});

mcp.registerTool("wait_for_message", {
  description: "Wait for an incoming message from another agent (or return immediately if one is already in the inbox).",
  inputSchema: {
    timeout_ms: z
      .number()
      .min(MIN_WAIT_TIMEOUT_MS)
      .max(MAX_WAIT_TIMEOUT_MS)
      .optional()
      .describe(`Max milliseconds to wait before returning timeout (default: ${DEFAULT_WAIT_TIMEOUT_MS}, max: ${MAX_WAIT_TIMEOUT_MS})`),
    from: z
      .string()
      .optional()
      .describe("Optional: only wake for messages from this exact peer address"),
    re: z
      .string()
      .optional()
      .describe("Optional: only wake for replies matching this message id"),
  },
}, async ({ timeout_ms, from, re }, extra) => {
  if (!meshReady || !_mesh) return notReady();
  const res = await inbox.waitForMessage({
    timeoutMs: timeout_ms,
    from,
    re,
    // Honour client cancellation: without it an abandoned waiter would eat the
    // next matching message and the SDK would discard it with our response.
    signal: extra.signal,
  });
  if (res.status === "aborted") {
    return {
      content: [{ type: "text" as const, text: "(wait cancelled — no message consumed)" }],
    };
  }
  if (res.status === "timeout") {
    return {
      content: [
        {
          type: "text" as const,
          text: `(timeout: no matching messages after ${timeout_ms ?? DEFAULT_WAIT_TIMEOUT_MS}ms)`,
        },
      ],
    };
  }
  return {
    content: [{ type: "text" as const, text: formatIncomingMessages(res.messages) }],
  };
});

// ── Main ──────────────────────────────────────────────────────────────────────

function isoNow(): string {
  return new Date().toISOString();
}

let _lock: NamedAcquiredLock | null = null;
let _lockRetryTimer: ReturnType<typeof setTimeout> | null = null;
let _lockAttempt = 0;
let _joined = false;
let _shuttingDown = false;

function createConfiguredMeshNode(agentName: string): MeshNode {
  const node = new MeshNode({
    sockPath: BROKER_SOCK,
    name: agentName,
    cwd: _canonCwd,
    auditPath: AUDIT_PATH,
    ...(_bridgeEnabled ? { bridge: { relayUrl, cwd: _cwd } } : {}),
    log: () => { /* no-op */ },
  });

  node.onMessage((env) => {
    if (env.from === "broker" || env.from.endsWith(":broker")) return;

    const msg: InboxMessageLike = {
      from: env.from,
      body: env.body,
      id: env.id,
      re: env.re,
      at: isoNow(),
    };
    inbox.push(msg);
    void mcp.server.notification({
      method: "notifications/claude/channel",
      params: { content: `📨 Message from ${msg.from}:\n${JSON.stringify(msg.body, null, 2)}` },
    }).catch(() => { /* channels not enabled — hooks / get_messages / wait_for_message cover it */ });
  });

  return node;
}

async function maybeResolveCwdFromMcpRoots(): Promise<void> {
  if (_explicitCwd) return;
  let timer: ReturnType<typeof setTimeout> | null = null;
  try {
    const timeoutPromise = new Promise<null>((resolve) => {
      timer = setTimeout(() => resolve(null), MCP_ROOTS_TIMEOUT_MS);
      timer.unref?.();
    });
    const rootsRes = await Promise.race([mcp.server.listRoots(), timeoutPromise]);
    const firstUri = rootsRes?.roots?.[0]?.uri;
    if (firstUri && firstUri.startsWith("file://")) {
      const rootPath = fileURLToPath(firstUri);
      if (rootPath) {
        _cwd = rootPath;
        _canonCwd = canonicalizeCwd(_cwd);
        _baseAgentName = resolveBaseAgentName(_cwd, _nameOverride);
        _lockedAgentName = _baseAgentName;
      }
    }
  } catch {
    // Host does not implement roots/list — keep process.cwd().
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function waitForClientInitialized(timeoutMs: number): Promise<void> {
  // `mcp.connect()` only starts the transport; the client's initialize/
  // initialized handshake arrives afterwards. Sending roots/list before it
  // violates the MCP init sequence and makes strict hosts reject the request,
  // which permanently falls back to process.cwd() for bare `agy` sessions.
  if (
    mcp.server.getClientVersion() !== undefined ||
    mcp.server.getClientCapabilities() !== undefined
  ) {
    return;
  }
  await new Promise<void>((resolve) => {
    const timer = setTimeout(() => {
      mcp.server.oninitialized = undefined;
      resolve();
    }, timeoutMs);
    timer.unref?.();
    mcp.server.oninitialized = () => {
      clearTimeout(timer);
      mcp.server.oninitialized = undefined;
      resolve();
    };
  });
}

async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  transport.onclose = shutdown;
  process.stdin.on("end", shutdown);
  process.stdin.on("close", shutdown);
  await mcp.connect(transport);
  await waitForClientInitialized(MCP_INIT_TIMEOUT_MS);
  await maybeResolveCwdFromMcpRoots();

  if (localConfigExists(_cwd) || _nameOverride !== undefined || _autoJoin) {
    void tryJoinMesh();
  } else {
    degradedReason =
      `this folder is not a remote-pi agent (no config). Run "remote-pi agy" or "remote-pi claude" ` +
      `here to make it one. Mesh tools are idle.`;
  }
}

/**
 * Acquire a per-(cwd, name) lock with `#2..#1000` collision fallback so Pi,
 * Claude, and Agy can coexist in the same folder, then join the mesh.
 */
async function tryJoinMesh(): Promise<void> {
  if (_joined || _shuttingDown) return;

  const res = await acquireNamedCwdLock(_canonCwd, _baseAgentName);
  if (!res.ok) {
    _lockAttempt++;
    if (_lockAttempt >= MAX_JOIN_ATTEMPTS) {
      _failLoud(`folder lock exhausted for ${_baseAgentName} (lock: ${res.lockPath})`);
    }
    degradedReason = `folder busy (lock ${res.lockPath}); attempt ${_lockAttempt}/${MAX_JOIN_ATTEMPTS}`;
    _scheduleJoinRetry(JOIN_RETRY_MS);
    return;
  }
  _lock = res;
  _lockedAgentName = res.lockedName;

  const node = createConfiguredMeshNode(_lockedAgentName);
  _mesh = node;

  try {
    await node.connect();
    // Sidecar sync is last-but-non-throwing; only flip the "up" flags once
    // everything that the join contract needs has succeeded — otherwise the
    // catch below would release the lock while _joined=true suppresses retries.
    syncInboxState(inbox.peekAll());
    meshReady = true;
    _joined = true;
    _lockAttempt = 0;
  } catch (e) {
    _lockAttempt++;
    meshReady = false;
    try { _lock.release(); } catch { /* best-effort */ }
    _lock = null;
    _mesh = null;
    void Promise.resolve(node.close()).catch(() => { /* best-effort */ });
    if (_lockAttempt >= MAX_JOIN_ATTEMPTS) {
      _failLoud(`mesh join failed: ${String(e)}`);
    }
    degradedReason = `mesh join failed (attempt ${_lockAttempt}/${MAX_JOIN_ATTEMPTS}): ${String(e)}`;
    _scheduleJoinRetry(JOIN_RETRY_MS);
  }
}

function _scheduleJoinRetry(delayMs: number): void {
  if (_lockRetryTimer || _joined || _shuttingDown) return;
  const t = setTimeout(() => {
    _lockRetryTimer = null;
    void tryJoinMesh();
  }, delayMs);
  t.unref?.();
  _lockRetryTimer = t;
}

function _failLoud(reason: string): never {
  logErr(
    `FATAL: ${reason}. Exiting so the failure is visible. cwd=${_cwd}. ` +
    `Launch via "remote-pi agy" or "remote-pi claude" from the project dir.`,
  );
  process.exit(1);
}

function shutdown(): void {
  if (_shuttingDown) return;
  _shuttingDown = true;
  if (_lockRetryTimer) { clearTimeout(_lockRetryTimer); _lockRetryTimer = null; }
  clearFallbackWakeTimer();
  inbox.close();
  removeInboxState(_inboxStatePath);
  try { _lock?.release(); } catch { /* OS frees the UDS lock on exit anyway */ }
  const node = _mesh;
  _mesh = null;
  void Promise.resolve(node?.close())
    .catch(() => { /* best-effort */ })
    .finally(() => process.exit(0));
}

main().catch((err: unknown) => {
  process.stderr.write(`[remote-pi-mesh] fatal: ${String(err)}\n`);
  process.exit(1);
});
