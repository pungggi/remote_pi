#!/usr/bin/env node
/**
 * pi-extension — remote-pi slash commands + AgentBridge wiring
 *
 * Exported as ExtensionFactory (default export) to be loaded by Pi SDK:
 *   pi -e $(pwd)/dist/index.js
 *
 * State machine:  idle → started → paired
 *   /remote-pi start   connects to relay (idle → started)
 *   /remote-pi pair    shows QR for new peers (started, async → paired via auto-listener)
 *   /remote-pi stop    closes everything (any → idle)
 *
 * Pairing (post plano 06 — sem Noise XX):
 *   App envia inner `pair_request` (id, token, device_name) sobre canal opaco.
 *   Pi valida o token via qrSession.consumeToken, salva peer em peers.json
 *   {name, remote_epk, paired_at} e responde com `pair_ok` (ou `pair_error`).
 *   `ct` é base64(JSON.stringify(inner)) — sem cifra, sem MAC.
 *
 * Reconexão de peer conhecido:
 *   Se uma mensagem chega em estado `started` vinda de um epk presente em
 *   peers.json, o auto-listener promove direto pra `paired` sem novo
 *   pair_request, criando o PlainPeerChannel e roteando a mensagem.
 *
 * Architecture note — why we don't use AgentBridge directly here:
 *   AgentBridge.beforeToolCallHook is designed to be passed to createAgentSession().
 *   Inside an extension Pi already owns the AgentSession, so we can't re-bind
 *   beforeToolCall after the fact. The equivalent is pi.on("tool_call", …) which
 *   fires BEFORE execution and supports { block: true }.
 *   AgentBridge (src/session/agent_bridge.ts) remains the tested, mockable unit
 *   for integration tests.
 */

import { Type } from "typebox";
import { createHash, randomUUID } from "node:crypto";
import type {
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionContext,
  ExtensionFactory,
} from "@earendil-works/pi-coding-agent";
import { SettingsManager, convertToPng } from "@earendil-works/pi-coding-agent";
import { type Ed25519Keypair } from "./pairing/crypto.js";
import { buildQRUri, qrSession, renderQRAscii, clampPairTtlMs, TOKEN_TTL_MS } from "./pairing/qr.js";
import {
  addPeer,
  getOrCreateEd25519Keypair,
  KeyringUnavailableError,
  listPeers,
  markPeerSigning,
  removePeer,
  snapshotOwnerPubkeys,
  conditionalRemovePeer,
  type PeerRecord,
} from "./pairing/storage.js";
import { signInnerCt, signInnerCtV2, verifyInnerDual } from "./transport/inner_sig.js";
import { MeshClient } from "./mesh/client.js";
import {
  canonicalizeEd25519PublicKey,
  decodeEd25519PublicKey,
  publicKeyFingerprint,
} from "./mesh/encoding.js";
import { SelfRevoke } from "./mesh/self_revoke.js";
import type { MeshTopologySnapshot } from "./mesh/siblings.js";
import type {
  ClientMessage,
  PairErrorCode,
  ServerMessage,
  SessionHistoryEvent,
  ThinkingLevel,
  WireImage,
  QueuedMessageItem,
} from "./protocol/types.js";
import { RelayClient, RoomAlreadyOpenError } from "./transport/relay_client.js";
import { PlainPeerChannel } from "./transport/peer_channel.js";
import {
  createExtensionUiBridge,
  type ExtensionUiBridge,
} from "./extension_ui_bridge.js";
import { roomIdFor } from "./rooms.js";
import { registerAgentTools } from "./session/tools.js";
import {
  resolveCurrentSessionFile,
  refreshIndex,
  readMessages,
  streamPageBefore,
  decodeCursor,
  encodeCursor,
  type FileIndexEntry,
} from "./session/file_index.js";
import { formatPeerInventory } from "./session/peer_inventory.js";
import { MeshNode } from "./session/mesh_node.js";
import {
  handleSessionCompact,
  handleModelSet,
  handleThinkingSet,
  handleListModels,
  type ActionCtx,
  type ActionModelRegistry,
} from "./actions/handlers.js";
import { handleGitStatus, getGitStatus } from "./actions/git_status.js";
import type { WireGitStatus } from "./protocol/types.js";
import { handleOpenTerminal, handleListWorktrees, handleRemoveWorktree } from "./actions/open_terminal.js";
import { handleStartSession } from "./actions/start_session.js";
import { handleListProjects } from "./projects/handlers.js";
import { handleChangeLayout } from "./actions/change_layout.js";
import { ensureModelRegistry } from "./actions/registry.js";
import {
  ensureGlobalDirs,
  LOCAL_SESSION_NAME,
  sessionAuditPath,
  sessionSockPath,
  skillsDir,
} from "./session/global_config.js";
import { acquireCwdLock, type AcquiredLock } from "./session/cwd_lock.js";
import { addDaemon, listDaemons, removeDaemon } from "./daemon/registry.js";
import { callSupervisor, supervisorOnline, SupervisorOfflineError } from "./daemon/client.js";
import type { ControlRequest, DaemonInfo } from "./daemon/control_protocol.js";
import { EXIT_DAEMON_FRESH_SESSION } from "./daemon/rpc_child.js";
import { installService, uninstallService, linkCliBinaries, unlinkCliBinaries, LAUNCHD_LABEL, SYSTEMD_UNIT, WINDOWS_TASK_NAME } from "./daemon/install.js";
import {
  defaultAgentName,
  effectiveAutoStartRelay,
  loadLocalConfig,
  localConfigExists,
  saveLocalConfig,
} from "./session/local_config.js";
import { runSetupWizard, type WizardUI } from "./session/setup_wizard.js";
import { updateFooter, type FooterState } from "./ui/footer.js";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chmodSync, mkdtempSync, mkdirSync, copyFileSync, existsSync, unlinkSync, readFileSync, statSync, writeFileSync, realpathSync } from "node:fs";
import { createInterface } from "node:readline";
import { spawnSync } from "node:child_process";
import { hostname, tmpdir } from "node:os";
import {
  kDefaultRelayUrl,
  resolveRelayUrl,
  resolveAdvertisedRelayUrl,
  saveConfig,
  isValidRelayUrl,
  isWebSocketScheme,
  toWebSocketUrl,
} from "./config.js";
import { toPhoneReachableUrl } from "./lan.js";
import { Box, Container, Image, Text } from "@earendil-works/pi-tui";
import {
  ext,
  type RemoteState,
  type RelayConnectivity,
  type WireContextUsage,
  type FullSdkModel,
  type ReceivedImageDetails,
  type BufferMsg,
  type PendingSteer,
  type AndroidQueuedItem,
  type MeshEnvelope,
} from "./extension-state.js";
import {
  registerShowImageTool,
  registerShowFileTool,
  registerReceivedImageRenderer,
  flushPendingReceivedImagePreviews,
  emitReceivedImagePreviews,
  shouldDeferReceivedImagePreview,
  filterReceivedImageMessagesFromContext,
  contentFromUserMessage,
  type ReceivedImagePreviewDelivery,
  type ImagePipelineDeps,
} from "./images/pipeline.js";
import {
  cmdCreate, cmdRemove, cmdDaemonsList, cmdDaemonStatus, cmdDaemonStart,
  cmdDaemonStop, cmdDaemonRestart, cmdDaemonSend, cmdCron, cmdInstall,
  cmdUninstall,
} from "./commands/fleet.js";
import { enrichToolArgs, stringifyContent, stringifyToolResult } from "./tools/format.js";
import { startGitRefresh, stopGitRefresh } from "./git/refresh.js";
// Preserve the public type export surface (these were `export type` in the monolith).
export type { RemoteState, RelayConnectivity } from "./extension-state.js";

// ── State machine ─────────────────────────────────────────────────────────────
//
// Pre-2026-05-23: `idle` → `started` → `paired` (one owner at a time, gate-kept
// by `_appPeerId`/`_peerChannel` singletons). The transition to `paired` was
// what unblocked the app from sending application messages.
//
// Now: `idle` → `started`. The `paired` state is a derived metric
// (`ext.activePeers.size > 0`) — N owners can be connected at once, each with
// its own `PlainPeerChannel` in `ext.activePeers`. Plan/24 W2D ("multi-channel
// broadcast"): pairing a second device no longer disconnects the first, and
// every connected owner receives the same agent stream in parallel.



/** Relay connectivity as seen by an RPC client (Cockpit). Derived from
 *  `ext.state` + `ext.relay`: "disconnected" = relay off (idle); "connected" = live
 *  WS; "reconnecting" = was on, WS dropped, retrying. Surfaced via the
 *  `remote-pi:relay-state` custom message (see `_emitRelayState`). */

/** Last `RelayConnectivity` emitted, for change-dedup. Starts "disconnected"
 *  (the process boots with the relay down). */

/** Sentinel prefix for a transparent control message an RPC client sends on the
 *  `prompt` channel (stdin). The `input` hook intercepts it, runs the action,
 *  and swallows it (`action:"handled"`) so it never becomes an LLM turn or a
 *  transcript entry. Starts with NUL so it can't collide with real user input
 *  and doesn't begin with "/" (which would route to the command parser). */
export const CTRL_PREFIX = "\x00remote-pi-ctrl:";
/**
 * Owners currently connected via the relay. Key = app peer pubkey (Ed25519,
 * base64 standard); value = the dedicated PlainPeerChannel routing messages
 * to/from that owner.
 *
 * Operational notes:
 *   - Adding/removing entries is exclusively in `_attachPeerChannel` and
 *     `_detachPeerChannel` (or `_goIdle` for the bulk teardown). Don't mutate
 *     directly elsewhere — those helpers keep the footer/log/state in sync.
 *   - `paired` UX state is `ext.activePeers.size > 0`. The footer and the
 *     `/remote-pi status` output both derive from this.
 */


// Plan/114 — hard cap on a raw image file the agent may push to the user via
// `show_image`. Bounds the inline base64 payload on the wire (double-base64
// ≈ +77%). Server-side resize (sharp) + a binary relay channel are deferred
// follow-ups; until then oversized files are rejected with a clear message.

// Plan/126 — hard caps on raw DOCUMENT files the agent may push to the user via
// `show_file` (markdown / text / code / html / pdf). Text-y kinds are bounded
// small (exceeding 1 MiB is unusual and a 1 MiB single text blob janks the
// viewer); PDFs are allowed larger but pay the same double-base64 wire tax
// (risk #1). As with `show_image`, no server-side resize/transcode in the MVP.


// Plan/28 Wave D.1: `thinking` published alongside `model` so the app's
// Quick Actions sheet hydrates the thinking segmented control on first
// open instead of starting null. The SDK fires `thinking_level_select`
// on every change (initial load + user toggle), mirrored to room_meta
// the same way model is — apps subscribe to one channel for both.
/** Context-window fill the Pi-extension publishes as `room_meta.context_usage`
 *  (opaque to the relay — the app parses it). Mirrors the `WireGitStatus` passthrough. */


// ── Plan/109 — one-shot model override (per-message model send) ───────────────
// When an app sends a user_message with `model: {provider,id}`, we switch the
// LIVE session model, inject the message, then revert on turn_end. The default
// model is never persisted (setModel is live-only). The temp model PROPAGATES
// to room_meta (and the app header) for the turn, then reverts — the earlier
// display-freeze was removed so the user can see which model runs the message
// (flicker on other subscribed devices is accepted).
// The SDK's full Model shape (what `ExtensionAPI.setModel` expects). Handlers'
// registry/ctx expose a narrow `SdkModelLike`; the runtime objects are real
// Models, so we bridge with a cast at the setModel call sites.

// ── Agent-network session (plano 19) ──────────────────────────────────────────
// MeshNode owns both the local UDS mesh (SessionPeer) and the optional
// cross-PC relay bridge (BrokerRemote + PiForwardClient). The bridge is
// attached via `ext.meshNode.attachBridge()` once the relay WS is up and this
// Pi is the leader; MeshNode re-attaches it across UDS failovers.
// Invalidates an in-flight MeshNode.connect() before it can publish globally.
// Set true by `session_shutdown`. Connecting is async, so shutdown can land
// while `_cmdRoot` has not published either candidate yet. `ext.disposed` blocks
// the outgoing continuation until a same-module `session_start` rearms it;
// relay/mesh generations below permanently distinguish the old candidates from
// that replacement lifecycle even after `ext.disposed` becomes false again.
// True once the auto-init has run on the first session_start for this
// process. Prevents re-running on session replacements (those re-init via
// the ext.disposed re-arm path above). The session_start handler below auto-starts
// remote-pi for ANY session whose local config has auto_start_relay (default
// true) — interactive AND daemon — instead of only REMOTE_PI_DAEMON=1.

// Cached state of global pairings (`peers.json`). Pairing is per-machine, so a
// device paired in any Pi process is paired everywhere. Refreshed on boot,
// after addPeer (handle_pair_request), and after removePeer (revoke).

/** Reads peers.json and updates the global-pairings cache + footer. Fire and
 *  forget; failures keep the previous cached value. */
function _refreshPairingsCache(): void {
  void listPeers()
    .then((peers) => {
      ext.hasGlobalPairings = peers.length > 0;
      _refreshFooter();
    })
    .catch(() => { /* keep prior cached value */ });
}

/** Re-queries the broker for the authoritative peer list. The broker's map is
 *  the source of truth — incremental +1/-1 counters drift after failover, lost
 *  `peer_left` broadcasts (e.g., leader leaves), or any dropped event. Called
 *  on every `peer_joined`/`peer_left` and once on join. Fire-and-forget. */
function _refreshSessionPeerCount(
  peer: MeshNode,
  ctx?: Pick<ExtensionContext, "ui"> | null,
): void {
  void peer.request("broker", { type: "list_peers" }, 2000)
    .then((reply) => {
      const peers = (reply.body as { peers?: string[] } | null)?.peers;
      if (Array.isArray(peers)) {
        ext.sessionPeerCount = peers.length;
        _refreshFooter(ctx);
      }
    })
    .catch(() => { /* older broker without list_peers — keep prior count */ });
}

/** Friendly model name for room_meta (plano 18). undefined when SDK has none yet. */
function _currentModelName(): string | undefined {
  return ext.currentModel;
}

/**
 * Cache the active model name and fan it out to subscribed apps via a
 * `room_meta_update`. The relay push is a no-op when the room isn't up yet —
 * the next `room_meta` hello carries the cached value instead. Shared by the
 * `model_select` event and the connect/turn-start seeding, so a daemon that
 * just runs its DEFAULT model still reports it: `model_select` only fires on an
 * explicit set/cycle (never on settings load), so default-model daemons would
 * otherwise never surface their model.
 */
function _setCurrentModel(name: string): void {
  ext.currentModel = name;
  if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, model: name };
  if (ext.relay && ext.myRoomId) {
    ext.relay.sendControl({ type: "room_meta_update", room_id: ext.myRoomId, meta: { model: name } });
  }
}

/**
 * Plan/32: publish the `working` flag as room_meta (raw, no debounce — the
 * app debounces). Same shape as model/thinking updates. Used by turn_start/end
 * AND by the compaction handlers: `compact()` doesn't run a turn (it
 * disconnects the agent + aborts, emitting compaction_start, NOT turn_start),
 * so room_meta.working must be bracketed manually around compaction.
 */
function _publishWorking(working: boolean): void {
  if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, working };
  if (ext.relay && ext.myRoomId) {
    ext.relay.sendControl({ type: "room_meta_update", room_id: ext.myRoomId, meta: { working } });
  }
}

/**
 * Publish live context-window usage as `room_meta.context_usage` (opaque blob
 * — the relay forwards it verbatim, the app parses tokens/contextWindow/percent).
 * Same shape as the model/thinking/working/git updates.
 */
function _publishContextUsage(usage: WireContextUsage): void {
  if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, context_usage: usage };
  if (ext.relay && ext.myRoomId) {
    ext.relay.sendControl({ type: "room_meta_update", room_id: ext.myRoomId, meta: { context_usage: usage } });
  }
}

/** Read the live context usage from the SDK (when known) and fan it out. No-op until the first response reports usage. */
function _refreshContextUsage(): void {
  const usage = ext.lastEventCtx?.getContextUsage?.();
  if (usage) _publishContextUsage(usage);
}

/**
 * Plan/32 hardening — re-publish the full cached room_meta (incl `working`)
 * right after a successful relay (re)connect.
 *
 * The reconnect `hello` only fans out to subscribers as a `room_announced` on
 * the FIRST conn for a room; and if the app was itself mid-reconnect at the
 * same instant (common since plan/114 reacts to network changes on BOTH the
 * app and the Pi), it can miss that announce. Its cached `working` then stays
 * stale for the whole turn — the Home session-list dot stays green even though
 * the agent is mid-turn. An explicit `room_meta_update` here re-syncs EVERY
 * subscriber regardless of announce timing. Idempotent: the relay dedups
 * no-op patches, and the app dedups unchanged room_meta too.
 */
function _republishRoomMeta(): void {
  if (!ext.relay || !ext.myRoomId || !ext.myRoomMeta) return;
  const meta: Record<string, unknown> = { working: ext.myRoomMeta.working ?? false };
  if (ext.myRoomMeta.model) meta.model = ext.myRoomMeta.model;
  if (ext.myRoomMeta.thinking !== undefined) meta.thinking = ext.myRoomMeta.thinking;
  if (ext.myRoomMeta.git !== undefined) meta.git = ext.myRoomMeta.git;
  if (ext.myRoomMeta.context_usage !== undefined) meta.context_usage = ext.myRoomMeta.context_usage;
  ext.relay.sendControl({ type: "room_meta_update", room_id: ext.myRoomId, meta });
}

function _echoUserMessage(msg: ClientUserMessage, forceSteer = false): void {
  // Plan/127 — echo the inbound streaming_behavior (steer | followUp) so
  // every owner renders the matching bubble. `forceSteer` (queued-message
  // drain) coerces to steer for back-compat.
  const echoBehavior = forceSteer ? "steer" : msg.streaming_behavior;
  _broadcastToActive({
    type: "user_message",
    id: msg.id,
    text: msg.text,
    ...(msg.images && msg.images.length > 0 ? { images: msg.images } : {}),
    ...(echoBehavior ? { streaming_behavior: echoBehavior } : {}),
    // Plan/109 — echo the one-shot override model so other owners see it.
    ...(msg.model ? { model: msg.model } : {}),
  });
}

async function _deliverImageUserMessage(
  sender: PlainPeerChannel,
  msg: ClientUserMessage,
  shouldSteer: boolean,
): Promise<void> {
  const previewDelivery: ReceivedImagePreviewDelivery =
    shouldSteer || ext.currentTurnId !== null || ext.myRoomMeta?.working === true
      ? "defer"
      : "immediate";
  const emitPreview = async () => {
    try {
      await emitReceivedImagePreviews(msg, previewDelivery);
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      console.error(`[remote-pi] failed emitting image preview id=${msg.id}: ${detail}`);
    }
  };
  if (previewDelivery === "immediate") {
    await emitPreview();
  } else {
    void emitPreview().finally(() => {
      if (!shouldDeferReceivedImagePreview()) flushPendingReceivedImagePreviews();
    });
  }

  const previousTurnId = ext.currentTurnId;
  const seededTurnId = !shouldSteer || ext.currentTurnId === null;
  if (seededTurnId) ext.currentTurnId = msg.id;

  const wake = _wakeAgent(
    contentFromUserMessage(msg),
    `app user_message id=${msg.id} (+${msg.images?.length ?? 0} image)`,
    "steer",
  );
  if (!wake.ok) {
    if (seededTurnId) ext.currentTurnId = previousTurnId;
    sender.send({
      type: "error",
      code: "internal_error",
      in_reply_to: msg.id,
      message: `Agent rejected incoming message: ${wake.detail}`,
    });
    return;
  }

  if (shouldSteer) _trackPendingSteer(msg.id, msg.text);
  _echoUserMessage(msg, shouldSteer);
}

// ── Cross-PC mesh wiring (plan/25 Wave B/C) ───────────────────────────────────

/**
 * Hand the live relay to MeshNode so it can bring up the cross-PC bridge
 * (BrokerRemote + sibling discovery) — but only when this Pi is the leader
 * (broker host). MeshNode is idempotent + re-attaches across UDS failovers,
 * so this is safe to call from `_cmdStart`, relay reconnect, or SelfRevoke.
 * No-op until the relay WS + cached identity are both present.
 */
function _attachBridgeIfReady(): void {
  if (!ext.meshNode || !ext.relay || !ext.relayUrl || !ext.cachedEd25519) return;
  // A newly-created SelfRevoke producer must publish its own initial verified
  // or fallback snapshot before any retained topology is allowed to attach.
  if (ext.selfRevoke !== null) {
    if (
      ext.selfRevokeTopologyReadyEpoch !== ext.selfRevokeEpoch ||
      ext.selfRevokeTopology === null
    ) {
      return;
    }
    if (!ext.meshNode.hasTopology()) ext.meshNode.setTopology(ext.selfRevokeTopology);
  }
  void ext.meshNode
    .attachBridge({ relay: ext.relay, relayUrl: ext.relayUrl, keypair: ext.cachedEd25519 })
    .catch(() => { /* best-effort — UDS mesh works regardless */ });
}

/**
 * Prefer an explicit ctx, then the always-fresh session_start ctx, then the
 * last command ctx. Relay/async paths must not rely on `ext.lastCtx` alone —
 * the SDK marks captured command ctxs stale after session replacement.
 * @see https://github.com/jacobaraujo7/remote_pi/issues/55
 */
function _liveCtx(
  preferred?: { ui?: unknown } | null,
): { ui?: unknown } | null {
  return preferred ?? ext.lastEventCtx ?? ext.lastCtx ?? null;
}

/**
 * Read `ctx.ui` without letting a stale-ctx getter become an uncaughtException.
 * Optional chaining does NOT protect against a throwing getter.
 */
function _ctxUi(preferred?: { ui?: unknown } | null): {
  setStatus?: (k: string, v: string | undefined) => void;
  setTitle?: (t: string) => void;
  notify?: (message: string, level?: string) => void;
} | null {
  const target = _liveCtx(preferred);
  if (!target) return null;
  try {
    return (target.ui as {
      setStatus?: (k: string, v: string | undefined) => void;
      setTitle?: (t: string) => void;
      notify?: (message: string, level?: string) => void;
    } | null | undefined) ?? null;
  } catch {
    // Stale after newSession/fork/switchSession/reload — caller no-ops.
    return null;
  }
}

/** Best-effort TUI notify; never throws (relay reconnect must not crash pi). */
function _safeNotify(message: string, level: "info" | "warning" | "error" = "info"): void {
  try {
    const ui = _ctxUi();
    if (ui && typeof ui.notify === "function") ui.notify(message, level);
  } catch {
    /* never let notify take down the process */
  }
}

/** Refreshes the Pi TUI footer slots from current module state. Safe no-op when ctx lacks ui. */
function _refreshFooter(ctx?: { ui?: { setStatus?: unknown; setTitle?: unknown } } | null): void {
  // Prefer live session_start ctx over capturable-stale command ctx (issue #55).
  let ui: {
    setStatus?: (k: string, v: string | undefined) => void;
    setTitle?: (t: string) => void;
  } | null;
  try {
    ui = _ctxUi(ctx);
  } catch {
    return;
  }
  if (!ui || typeof ui.setStatus !== "function" || typeof ui.setTitle !== "function") return;
  try {
    const state: FooterState = {
      session: ext.sessionName ?? undefined,
      peerCount: ext.sessionPeerCount,
      relayOn: ext.state !== "idle",
      // `devicePaired` now reflects "any owner currently attached" — picks one
      // shortid representatively (multi-owner UX detail surfaces in the
      // `/remote-pi status` line, not the footer slot).
      devicePaired: _anyPeerActive() ? ext.peerShort : undefined,
      hasPairings: ext.hasGlobalPairings,
      agentName: ext.meshNode?.name(),
    };
    updateFooter(
      { ui: { setStatus: ui.setStatus.bind(ui), setTitle: ui.setTitle.bind(ui) } },
      state,
    );
  } catch {
    // setStatus/setTitle can also throw if the runner went stale mid-call.
  }
}

// Epoch ms when the state machine entered 'started' (last /remote-pi start).
// Used by session_sync to let the app detect Pi restarts (and force a full
// replay). Cleared on _goIdle.

// Snapshot of agent messages, captured on every agent_end event. Used to
// answer session_sync. Cleared on _goIdle.
function _queuedStateMessage(): ServerMessage {
  const first = ext.queuedItems[0];
  return {
    type: "queued_message_state",
    ...(first ? { id: first.id, text: first.text } : {}),
    items: ext.queuedItems.map((item) => ({ ...item })),
  };
}

function _sendQueuedState(sender: PlainPeerChannel): void {
  sender.send(_queuedStateMessage());
}

function _broadcastQueuedState(): void {
  _broadcastToActive(_queuedStateMessage());
}

function _resetQueuedItems({ broadcast = false }: { broadcast?: boolean } = {}): void {
  ext.queuedItems = [];
  if (broadcast) _broadcastQueuedState();
}

function _upsertQueuedItem(item: AndroidQueuedItem): void {
  const index = ext.queuedItems.findIndex((existing) => existing.id === item.id);
  if (index === -1) {
    ext.queuedItems = [...ext.queuedItems, item];
  } else {
    ext.queuedItems = [
      ...ext.queuedItems.slice(0, index),
      item,
      ...ext.queuedItems.slice(index + 1),
    ];
  }
  _broadcastQueuedState();
}

function _clearQueuedItems(targetId?: string): void {
  ext.queuedItems = targetId
    ? ext.queuedItems.filter((item) => item.id !== targetId)
    : [];
  _broadcastQueuedState();
}

function _isBusyForQueueDrain(): boolean {
  return ext.currentTurnId !== null || ext.myRoomMeta?.working === true;
}

function _normalizeSteerText(text: string): string {
  return text.trim();
}

function _trackPendingSteer(id: string, text: string): void {
  const key = _normalizeSteerText(text);
  if (!key) return;
  ext.pendingSteers.push({ id, text: key });
}

function _consumePendingSteerForStartedUser(text: string): string | null {
  if (ext.pendingSteers.length === 0) return null;
  const key = _normalizeSteerText(text);
  const index = key ? ext.pendingSteers.findIndex((item) => item.text === key) : -1;
  const [item] = ext.pendingSteers.splice(index >= 0 ? index : 0, 1);
  return item?.id ?? null;
}

function _broadcastConsumedSteerForUserContent(content: unknown): void {
  const text = stringifyContent(content);
  if (ext.lastConsumedSteerText === text) {
    ext.lastConsumedSteerText = null;
    return;
  }
  const id = _consumePendingSteerForStartedUser(text);
  if (!id) return;
  ext.lastConsumedSteerText = text;
  _broadcastToActive({ type: "steer_consumed", id });
}

function _maybeDrainQueuedItem(): void {
  if (_isBusyForQueueDrain()) return;
  const item = ext.queuedItems.shift();
  if (!item) return;
  _broadcastQueuedState();

  const previousTurnId = ext.currentTurnId;
  ext.currentTurnId = item.id;
  const msg: ClientUserMessage = { type: "user_message", id: item.id, text: item.text };
  const wake = _wakeAgent(item.text, `queued app user_message id=${item.id}`, "steer");
  if (!wake.ok) {
    ext.currentTurnId = previousTurnId;
    ext.queuedItems = [item, ...ext.queuedItems];
    _broadcastQueuedState();
    _broadcastToActive({
      type: "error",
      code: "internal_error",
      in_reply_to: item.id,
      message: `Agent rejected queued message: ${wake.detail}`,
    });
    return;
  }
  _echoUserMessage(msg, false);
}

/**
 * Plan/127 — drain one pending follow-up when the room is idle. Mirrors
 * `_maybeDrainQueuedItem`: sets `currentTurnId` to the follow-up id BEFORE
 * waking the agent, so the follow-up's turn streams back attributed to that
 * id (the app already rendered the committed follow-up bubble at send time).
 * The follow-up is NOT re-echoed here — it was echoed when the app sent it.
 */
function _maybeDrainFollowUp(): void {
  if (_isBusyForQueueDrain()) return;
  const item = ext.pendingFollowUps.shift();
  if (!item) return;
  const previousTurnId = ext.currentTurnId;
  ext.currentTurnId = item.id;
  const wake = _wakeAgent(item.text, `app follow-up user_message id=${item.id}`);
  if (!wake.ok) {
    ext.currentTurnId = previousTurnId;
    ext.pendingFollowUps = [item, ...ext.pendingFollowUps];
    _broadcastToActive({
      type: "error",
      code: "internal_error",
      in_reply_to: item.id,
      message: `Agent rejected follow-up message: ${wake.detail}`,
    });
  }
}

/** Test-only override of the message buffer. */
/**
 * Test-only: emulate what `/remote-pi` does on the returning-user path
 * (join the local mesh, then start the relay) without touching the FS for
 * a `localConfigExists()` lookup. Lets tests bring the relay up without
 * mocking the wizard or the local config storage.
 *
 * Typed loosely to accept any ctx shape with `ui.notify` + `cwd` — the
 * unit tests use minimal mocks that don't satisfy the full
 * `ExtensionContext` interface.
 */
export async function _connectForTest(ctx: unknown): Promise<void> {
  const real = ctx as Parameters<typeof _cmdJoin>[0];
  await _cmdJoin(real);
  await _cmdStart(real);
}

/** Test-only: tear everything down (mirrors `/remote-pi stop`). */
export async function _stopForTest(ctx: unknown): Promise<void> {
  await _cmdStop(ctx as Parameters<typeof _cmdStop>[0]);
}

/** Test-only: read/reset the `ext.disposed` flag. Production clears it only when
 *  a host reuses this module for a replacement session; tests share one module
 *  across cases, so they also reset it to avoid cross-test pollution. */
export function _getDisposedForTest(): boolean { return ext.disposed; }
export function _setDisposedForTest(v: boolean): void { ext.disposed = v; }

/** Test-only: reset the once-per-session auto-init gate so session_start re-runs it. */
export function _resetAutoInitedForTest(): void { ext.autoInited = false; }

/** Test-only: set the auto-init gate for lifecycle replacement tests. */
export function _setAutoInitedForTest(value: boolean): void { ext.autoInited = value; }

/** Test-only: true when this instance holds a live local-mesh node. */
export function _hasMeshNodeForTest(): boolean { return ext.meshNode !== null; }

/** Test-only: drive the current real SelfRevoke producer through one sweep. */
export async function _checkSelfRevokeForTest(): Promise<void> {
  await ext.selfRevoke?.checkOnce();
}

/** Test-only: the effective (possibly `#N`-suffixed) name the cwd-lock reserved. */
export function _getLockedNameForTest(): string | null { return ext.lockedName; }

/** Test-only: release + clear the cwd lock (the lock normally survives stop). */
export function _resetCwdLockForTest(): void {
  try { ext.cwdLock?.release(); } catch { /* ignored */ }
  ext.cwdLock = null;
  ext.lockedName = null;
}

/**
 * Test-only: relay-only startup, no UDS mesh join. Replaces the old
 * `remote-pi relay start` handler that some tests captured to bring up
 * the relay in isolation (e.g. ping/pong tests that don't care about the
 * agent-network broker).
 */
export async function _startRelayForTest(ctx: unknown): Promise<void> {
  await _cmdStart(ctx as Parameters<typeof _cmdStart>[0]);
}

/** Test-only: public marker for canceled-keypair cache regression checks. */
export function _getCachedPublicKeyForTest(): string | null {
  return ext.cachedEd25519
    ? Buffer.from(ext.cachedEd25519.publicKey).toString("base64")
    : null;
}

export function _setMessageBufferForTest(msgs: unknown[]): void {
  ext.messageBuffer = msgs as BufferMsg[];
}

/** Test-only accessor: returns a defensive copy of the buffer. */
export function _getMessageBufferForTest(): unknown[] {
  return [...ext.messageBuffer];
}

/** Plan/128 — test-only: drop the cached durable-history index (between tests). */
export function _resetHistoryIndexForTest(): void {
  ext.historyIndex = null;
}

/** Test-only override of session started timestamp. */
export function _setSessionStartedAtForTest(ts: number | null): void {
  ext.sessionStartedAt = ts;
}

/** Test-only: reset the cached model name (between tests). */
export function _setCurrentModelForTest(name: string | undefined): void {
  ext.currentModel = name;
}

/** Test-only: read the active turn id used for plain `cancel` routing. */
export function _getCurrentTurnIdForTest(): string | null {
  return ext.currentTurnId;
}

export function _getPendingSteerIdsForTest(text: string): string[] {
  const key = _normalizeSteerText(text);
  return ext.pendingSteers.filter((item) => item.text === key).map((item) => item.id);
}

/** Test-only: override the bound AgentSession so a spy can capture the
 *  content handed to `sendUserMessage` (plan/30 multimodal ingest). */
export function _setPiForTest(pi: unknown): void {
  ext.pi = pi as typeof ext.pi;
}

/**
 * Persist a model change to the PROJECT settings (`<cwd>/.pi/settings.json`) so
 * a model picked from the app survives a Pi/daemon restart. `pi.setModel` only
 * sets the LIVE model — on the next restart a fresh session reads the saved
 * default and reverts (the reported bug). We write the PROJECT scope, NOT
 * global, deliberately: the SDK merges global←project with PROJECT winning
 * (`SettingsManager`), so a folder that already has a project default (every
 * created daemon does) would shadow a global write like the TUI's. Project
 * scope is also correct for a fleet — each daemon keeps its own model rather
 * than leaking one default globally.
 *
 * Read-merge-write + best-effort: preserves other keys and never throws (a
 * settings write must not fail the live model change, which already applied).
 */
function _persistModelDefault(provider: string, modelId: string): void {
  try {
    const path = join(process.cwd(), ".pi", "settings.json");
    let obj: Record<string, unknown> = {};
    try {
      const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
      if (parsed && typeof parsed === "object") obj = parsed as Record<string, unknown>;
    } catch { /* no existing/parseable file → start fresh */ }
    obj["defaultProvider"] = provider;
    obj["defaultModel"] = modelId;
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, JSON.stringify(obj, null, 2));
  } catch { /* best-effort — model change already applied live */ }
}

type ClientUserMessage = Extract<ClientMessage, { type: "user_message" }>;

// Per-turn messaging state

// Module-level pi reference

// Plan/100 — Bridge to pi-ask's clarification-flow events. null until the
// extension factory wires it (and null if the SDK exposes no events bus).


// Cached keypair (loaded once, reused across start/pair cycles)

// Mesh-membership poller (plan/24 Wave 3). Lives across the relay
// connection lifecycle: started in _cmdStart after the WS is up, stopped
// in _goIdle when the relay is torn down.

// Per-cwd lock acquired by the first `/remote-pi` invocation in this
// process. Holds the UDS socket open until the process exits (OS auto-
// releases on crash too). Stays held across `/remote-pi stop` cycles —
// only released when the Node process itself dies.
// Effective mesh name this instance locked. Equals the configured/derived name,
// OR a `#N`-suffixed variant when another agent already holds that (cwd, name)
// in this folder (same-name agents coexist instead of being refused). `_cmdJoin`
// registers under this name; the broker confirms it (and may bump it again under
// a live race). Null until the lock is acquired.

// ── Session sync limit (plan/128 payload guard) ─────────────────────────────────────
//
// Configurable via REMOTE_PI_SYNC_LIMIT (positive int, default 2000). Read on
// every session_sync. This is a wire payload GUARD, not the old mirror-cache
// 30-event window: the client's `limit` is honored up to this max, and when the
// client omits `limit` the whole page (up to this default) is served — a few
// thousand events so a typical session loads in one initial sync.
const SYNC_LIMIT_DEFAULT = 2000;
function _getSyncLimit(): number {
  const raw = process.env["REMOTE_PI_SYNC_LIMIT"];
  const parsed = raw ? parseInt(raw, 10) : NaN;
  return Number.isFinite(parsed) && parsed > 0 ? parsed : SYNC_LIMIT_DEFAULT;
}

// ── Relay reconnect state ─────────────────────────────────────────────────────
// Backoffs in ms: 1s, 2s, 5s, 10s, 30s, then stays at 30s.
const RECONNECT_BACKOFFS_MS = [1_000, 2_000, 5_000, 10_000, 30_000];

// Every initial connect/reconnect candidate captures this generation. Stop,
// relay-off, and an unexpected close invalidate older async continuations.
// Root startup has pre-candidate awaits (cwd lock, wizard) that relay/mesh
// generations cannot safely represent: child startup intentionally advances
// those generations. Stop/off/session replacement advance this separate epoch
// so a queued root can never regain authority by creating a newer child.
// Coalesces concurrent `/remote-pi` startup paths inside ONE extension instance.
// Separate Pi processes still keep the existing #N behavior via the cwd lock.

type RootRestartAuthority = Readonly<{
  rootLifecycleGeneration: number;
}>;

function _isCurrentRootLifecycle(generation: number): boolean {
  return !ext.disposed && generation === ext.rootLifecycleGeneration;
}

/** Test-only: exposes pending reconnect timer state. */
export function _hasPendingReconnect(): boolean {
  return ext.reconnectTimer !== null;
}

/**
 * Public state-snapshot helper. Returns the derived UX state, not the raw
 * `ext.state` enum: the W2D refactor collapsed the internal machine to
 * `idle | started` and made `paired` a derived metric
 * (`ext.activePeers.size > 0`). Tests and the footer keep the three-state
 * mental model via this getter.
 */
export function _getState(): "idle" | "started" | "paired" {
  if (ext.state === "idle") return "idle";
  return ext.activePeers.size > 0 ? "paired" : "started";
}

/** Test-only: number of owners currently attached via PlainPeerChannel. */
export function _getActivePeerCountForTest(): number {
  return ext.activePeers.size;
}

/** Test-only: true if a specific peer (base64 std) has an attached channel. */
export function _hasActivePeerForTest(appPeerIdStd: string): boolean {
  return ext.activePeers.has(appPeerIdStd);
}


// ── Multi-channel helpers ─────────────────────────────────────────────────────

/**
 * Sends `msg` to every currently-attached owner channel. The default
 * dispatch for application-level events that are part of "the agent
 * session is doing X" (agent_chunk, tool_request, tool_result, agent_done,
 * user_input mirror, room_meta_update, etc.) — all paired devices see the
 * same stream.
 *
 * Per-request responses (e.g. `session_history` answering a specific
 * `session_sync` query, or `pair_ok` answering `pair_request`) must NOT
 * use this — they go to the sender channel directly.
 */
function _broadcastToActive(msg: ServerMessage): void {
  _probeBroadcast(msg);
  for (const ch of ext.activePeers.values()) {
    try { ch.send(msg); } catch { /* best-effort per channel */ }
  }
}

// [probe 2026-08-21] send-side span per turn — pairs with the app's
// StreamProbe SUMMARY to attribute arrival lag upstream (relay/network)
// vs on-device (verify chain / UI). stdout → supervisord.log.
let _probeSendFirst = 0;
let _probeSendCount = 0;
let _probeSendChars = 0;
let _probeSendLast = 0;
function _probeBroadcast(msg: ServerMessage): void {
  if (msg.type === "agent_chunk") {
    const t = Date.now();
    if (_probeSendCount === 0) _probeSendFirst = t;
    _probeSendCount++;
    _probeSendChars += msg.delta?.length ?? 0;
    _probeSendLast = t;
  } else if (msg.type === "agent_done") {
    if (_probeSendCount > 0) {
      console.log(
        `[probe] daemon turn: chunks=${_probeSendCount} chars=${_probeSendChars} ` +
        `sendSpan=${_probeSendLast - _probeSendFirst}ms doneAt=${_probeSendLast}`,
      );
      _probeSendCount = 0;
      _probeSendChars = 0;
      _probeSendFirst = 0;
    }
  }
}

/** Returns true when at least one owner is attached. Derived `paired` UX. */
function _anyPeerActive(): boolean {
  return ext.activePeers.size > 0;
}

// ── Agent-chunk coalescing (perf 2026-08-21) ─────────────────────────────────
// The SDK emits text_delta at token rate (often 30-60/s while generating).
// Every agent_chunk is one signed frame, and the phone verifies each
// inbound frame with pure-Dart Ed25519 serialized in its arrival-order
// chain — bursts outrun verification (notably on the debug/JIT build) and
// streaming text visibly lags, catching up only when a tool call pauses
// the token stream. Coalescing deltas into ≤50ms frames cuts frame count
// 3-6x with no wire change (the delta is just longer); the app already
// paints on its own 16ms cadence, so granularity is imperceptible.
// Turn/tool/done/idle boundaries flush synchronously so
// text→tool→text→done ordering on the phone is preserved.
let _chunkPending = "";
let _chunkPendingTurn: string | null = null;
let _chunkFlushTimer: ReturnType<typeof setTimeout> | null = null;
const CHUNK_COALESCE_MS = 50;

function _flushAgentChunks(): void {
  if (_chunkFlushTimer !== null) {
    clearTimeout(_chunkFlushTimer);
    _chunkFlushTimer = null;
  }
  const delta = _chunkPending;
  const turn = _chunkPendingTurn;
  _chunkPending = "";
  _chunkPendingTurn = null;
  if (delta === "" || turn === null) return;
  if (!_anyPeerActive()) return;
  _broadcastToActive({ type: "agent_chunk", in_reply_to: turn, delta });
}

function _bufferAgentChunk(delta: string, turn: string): void {
  if (turn !== _chunkPendingTurn) {
    // Turn boundary (steer/follow-up): flush the old turn's text first so
    // one frame never mixes in_reply_to targets.
    _flushAgentChunks();
    _chunkPendingTurn = turn;
  }
  _chunkPending += delta;
  if (_chunkFlushTimer === null) {
    _chunkFlushTimer = setTimeout(() => {
      _chunkFlushTimer = null;
      _flushAgentChunks();
    }, CHUNK_COALESCE_MS);
  }
}

/**
 * Adds an owner's channel to `ext.activePeers`. Also updates the UX hint
 * `ext.peerShort` (last-attached shortid) so the footer + status can pick
 * a representative device when only one is connected.
 */
function _attachPeerChannel(appPeerId: string, channel: PlainPeerChannel): void {
  ext.activePeers.set(appPeerId, channel);
  ext.peerShort = appPeerId.slice(0, 8);
}

/** Detaches a single owner's channel + removes it from the map. Used by
 *  `_onPeerDisconnect`, `_cmdRevoke`, and the SelfRevoke callback. */
function _detachPeerChannel(appPeerId: string): void {
  const ch = ext.activePeers.get(appPeerId);
  if (!ch) return;
  try { ch.detach(); } catch { /* best-effort */ }
  ext.activePeers.delete(appPeerId);
  if (ext.peerShort === appPeerId.slice(0, 8)) {
    // Pick a different remaining peer for the UX hint, or clear when none.
    const next = ext.activePeers.keys().next().value;
    ext.peerShort = next ? next.slice(0, 8) : "";
  }
}

// ── Display-name helpers ──────────────────────────────────────────────────────

/**
 * Resolves the name this Pi shows to the mobile app and the relay's
 * `room_meta.name`. Single source of truth for "what does this Pi call
 * itself when talking to others".
 *
 * Resolution order:
 *   1. Broker-assigned name (when this Pi is on the local UDS mesh) — may
 *      carry a `#N` suffix from a name collision. Matches what other
 *      agents see, so the mobile UI shows the exact same string.
 *   2. `agent_name` from `<cwd>/.pi/remote-pi/config.json` — set by the
 *      wizard on first run; this is "the name the user configured".
 *   3. `defaultAgentName(cwd)` (parent/folder) — fallback when no config
 *      exists yet and the mesh hasn't been joined.
 *
 * Pre-2026-05-23 callers computed `cwd.split('/').slice(-2).join('/')`
 * inline at three different sites (pair_ok, room_meta, QR URI); this
 * helper consolidates them and lifts the user's configured name above
 * the raw cwd path.
 */
function _displayName(cwd: string): string {
  if (ext.meshNode) return ext.meshNode.name();
  const local = loadLocalConfig(cwd);
  return local.agent_name || defaultAgentName(cwd);
}

// ── Peer lookup helpers ───────────────────────────────────────────────────────

interface InspectedPeerRecord {
  readonly record: PeerRecord;
  readonly rawHandle: string;
  readonly runtimeKey: string | null;
}

function _rawOwnerFingerprint(rawValue: unknown): string {
  let fingerprintInput: string;
  if (typeof rawValue === "string") {
    fingerprintInput = rawValue;
  } else {
    try {
      const serialized = JSON.stringify(rawValue);
      const type = rawValue === null ? "null" : typeof rawValue;
      fingerprintInput = `${type}:${serialized ?? ""}`;
    } catch {
      fingerprintInput = `${typeof rawValue}:unserializable`;
    }
  }
  return createHash("sha256")
    .update(fingerprintInput, "utf8")
    .digest("hex")
    .slice(0, 8);
}

function _runtimeOwnerFingerprint(runtimeKey: string): string {
  try {
    return publicKeyFingerprint(
      decodeEd25519PublicKey(runtimeKey, "Owner runtime key"),
    );
  } catch {
    // Relay authentication guarantees canonical keys in production. This
    // fallback keeps diagnostics metadata-only at defensive/test boundaries.
    return _rawOwnerFingerprint(runtimeKey);
  }
}

function _inspectPeerRecord(record: unknown): InspectedPeerRecord | null {
  if (!record || typeof record !== "object") {
    const fingerprint = _rawOwnerFingerprint(record);
    console.warn(`[remote-pi] event=invalid_owner_record owner_fp=${fingerprint}`);
    return null;
  }

  const candidate = record as Partial<Record<keyof PeerRecord, unknown>>;
  const rawHandle = candidate.remote_epk;
  if (typeof rawHandle !== "string") {
    const fingerprint = _rawOwnerFingerprint(rawHandle);
    console.warn(`[remote-pi] event=invalid_owner_record owner_fp=${fingerprint}`);
    return null;
  }

  const safeRecord: PeerRecord = {
    name: typeof candidate.name === "string" ? candidate.name : "Unknown Owner",
    remote_epk: rawHandle,
    paired_at: typeof candidate.paired_at === "string" ? candidate.paired_at : "",
  };
  try {
    const runtimeKey = canonicalizeEd25519PublicKey(
      rawHandle,
      "stored Owner public key",
    );
    return { record: safeRecord, rawHandle, runtimeKey };
  } catch {
    const fingerprint = _rawOwnerFingerprint(rawHandle);
    console.warn(`[remote-pi] event=invalid_owner_record owner_fp=${fingerprint}`);
    return { record: safeRecord, rawHandle, runtimeKey: null };
  }
}

function _reportRevocationByFingerprint(canonicalOwnerPubkey: string): void {
  const fingerprint = _runtimeOwnerFingerprint(canonicalOwnerPubkey);
  ext.pi?.sendMessage({
    customType: "remote-pi:mesh-revoked",
    content:
      `🔒 Revoked by Owner ${fingerprint}…\n\n` +
      `The mobile app for this Owner removed this PC from the mesh. ` +
      `Re-pair via /remote-pi pair if this was unexpected.`,
    display: true,
  });
}

function _revokeActiveOwnerRuntime(canonicalOwnerPubkey: string): void {
  if (!ext.activePeers.has(canonicalOwnerPubkey)) return;
  _refreshPairingsCache();
  _detachPeerChannel(canonicalOwnerPubkey);
  _refreshFooter();
  _reportRevocationByFingerprint(canonicalOwnerPubkey);
}

async function _findKnownPeer(appPeerIdStd: string): Promise<PeerRecord | null> {
  let runtimeKey: string;
  try {
    runtimeKey = canonicalizeEd25519PublicKey(appPeerIdStd, "Relay Owner key");
  } catch {
    return null;
  }
  for (const record of await listPeers()) {
    const inspected = _inspectPeerRecord(record);
    if (inspected?.runtimeKey === runtimeKey) return inspected.record;
  }
  return null;
}

// ── Transition helpers ────────────────────────────────────────────────────────

/**
 * Full teardown: stop listener, detach channel, close relay → idle.
 *
 * `byeReason` (optional): when present and the channel is up, sends a
 * `{type:"bye", reason}` to the app before detaching so it sees offline
 * immediately instead of waiting ~50s for a ping miss. Fire-and-forget —
 * if the WS already failed (e.g., `relay.on("close")` callback) skip it
 * by omitting the reason; app falls back to ping miss naturally.
 */
function _goIdle(byeReason?: import("./protocol/types.js").ByeReason): void {
  ext.rootLifecycleGeneration += 1;
  ext.relayLifecycleGeneration += 1;

  // Broadcast bye to every still-attached owner so each app surfaces
  // "offline" immediately instead of waiting ~50s for a ping miss.
  // Flush any coalesced agent text first — up to 50ms of a turn's tail
  // would otherwise vanish on stop/idle.
  _flushAgentChunks();
  if (byeReason && ext.state !== "idle" && _anyPeerActive()) {
    _broadcastToActive({ type: "bye", reason: byeReason });
  }

  // Cancel any pending reconnect attempt. Critical: /remote-pi stop must
  // win the race against a scheduled reconnect.
  if (ext.reconnectTimer !== null) {
    clearTimeout(ext.reconnectTimer);
    ext.reconnectTimer = null;
  }
  ext.reconnectAttempt = 0;

  ext.stopAutoListener?.();
  ext.stopAutoListener = null;

  if (ext.queuedItems.length > 0) _resetQueuedItems({ broadcast: true });

  // Tear down every per-owner channel and clear the map.
  for (const ch of ext.activePeers.values()) {
    try { ch.detach(); } catch { /* best-effort */ }
  }
  ext.activePeers.clear();
  ext.peerShort = "";
  ext.currentTurnId = null;
  ext.pendingReceivedImagePreviews.length = 0;
  ext.pendingSteers = [];
  ext.pendingFollowUps = [];
  ext.lastConsumedSteerText = null;
  _resetQueuedItems();

  // Invalidate async producers and bridge ownership before closing the host
  // Relay. A synchronous/delayed close callback must observe stale identity.
  const producer = ext.selfRevoke;
  ext.selfRevoke = null;
  ext.selfRevokeEpoch += 1;
  ext.selfRevokeTopologyReadyEpoch = -1;
  ext.selfRevokeTopology = null;
  producer?.stop();

  ext.meshNode?.detachBridge();

  const relay = ext.relay;
  ext.relay = null;
  ext.relayUrl = null;
  relay?.close();

  // Preserve ext.sessionStartedAt + ext.messageBuffer across stop/start cycles.
  // The Pi agent session outlives the relay connection — `message_end` keeps
  // firing for terminal turns even while idle, and the buffer must survive
  // so those turns appear in the next session_sync. Only a Pi process
  // restart resets these (init-time values).

  ext.state = "idle";
  _refreshFooter();
  _emitRelayState();  // → disconnected
}

/**
 * Called when the relay WS closes unexpectedly (network drop, relay restart,
 * etc.). Does a **partial** teardown — keeps `ext.sessionStartedAt`, `ext.messageBuffer`,
 * `ext.relayUrl`, `ext.cachedEd25519`, `ext.peerShort` so the session can resume on
 * reconnect — and schedules an `_attemptReconnect`.
 *
 * Peer (app) reconnect after a successful relay reconnect is handled by the
 * existing auto-listener via `peers.json` lookup, so we don't need to track
 * the prior peer here; we just go back to `started` and wait.
 */
function _onRelayClose(closedRelay: RelayClient): void {
  if (ext.relay !== closedRelay) return; // delayed close from a replaced Relay
  if (ext.state === "idle") return;  // already torn down (e.g. /remote-pi stop)

  ext.relayLifecycleGeneration += 1;
  ext.stopAutoListener?.();
  ext.stopAutoListener = null;
  stopGitRefresh(); // Plan/107b — halt room_meta.git polling until reconnect

  // Detach every per-owner channel — relay is gone, none can route. The
  // auto-listener re-attaches owners after `_attemptReconnect` succeeds
  // (via the same known-peer + pair_request paths used on first connect).
  for (const ch of ext.activePeers.values()) {
    try { ch.detach(); } catch { /* best-effort */ }
  }
  if (ext.queuedItems.length > 0) _resetQueuedItems({ broadcast: true });
  ext.activePeers.clear();
  ext.peerShort = "";
  ext.currentTurnId = null;
  ext.pendingSteers = [];
  ext.pendingFollowUps = [];
  ext.lastConsumedSteerText = null;
  _resetQueuedItems();

  ext.relay = null;  // ext.relayUrl preserved for retry

  // Cross-PC routing relies on ext.relay; bring it down. Will be re-instated
  // by _attemptReconnect on success.
  ext.meshNode?.detachBridge();

  ext.state = "started";
  _refreshFooter();
  _emitRelayState();  // → reconnecting

  const reconnectUrl = ext.relayUrl;
  if (reconnectUrl) {
    _scheduleReconnect(ext.relayLifecycleGeneration, reconnectUrl);
  }
}

function _isCurrentReconnect(
  lifecycleGeneration: number,
  url: string,
): boolean {
  return (
    lifecycleGeneration === ext.relayLifecycleGeneration &&
    ext.state === "started" &&
    ext.relay === null &&
    ext.relayUrl === url
  );
}

function _scheduleReconnect(
  lifecycleGeneration: number,
  url: string,
): void {
  if (ext.reconnectTimer !== null) return;  // already scheduled
  if (!ext.cachedEd25519) return;  // can't reconnect without the cached identity
  if (!_isCurrentReconnect(lifecycleGeneration, url)) return;

  const idx = Math.min(ext.reconnectAttempt, RECONNECT_BACKOFFS_MS.length - 1);
  const delay = RECONNECT_BACKOFFS_MS[idx]!;
  ext.reconnectAttempt += 1;

  // The timer belongs to the lifecycle that scheduled it. Re-check that exact
  // generation + URL before constructing a candidate so a dequeued old timer
  // cannot act on a newer stop/start lifecycle.
  ext.reconnectTimer = setTimeout(() => {
    ext.reconnectTimer = null;
    if (!_isCurrentReconnect(lifecycleGeneration, url)) return;
    void _attemptReconnect(lifecycleGeneration, url);
  }, delay);
}

async function _attemptReconnect(
  lifecycleGeneration: number,
  url: string,
): Promise<void> {
  if (!ext.cachedEd25519) return;
  if (!_isCurrentReconnect(lifecycleGeneration, url)) return;

  const edKp = ext.cachedEd25519;
  // ext.relayUrl is stored in canonical http(s):// form — convert at the
  // WS boundary, same as _cmdStart.
  const relay = new RelayClient(toWebSocketUrl(url), edKp);

  try {
    // Replay the same room identity from _cmdStart. Without this the relay
    // would log this WS as a default-room peer and the app would see a
    // phantom "legacy session" appear (regression of plano 17 + 18).
    await relay.connect({
      ...(ext.myRoomId ? { roomId: ext.myRoomId } : {}),
      ...(ext.myRoomMeta ? { roomMeta: ext.myRoomMeta } : {}),
    });
  } catch {
    // A reconnect candidate stays local until publication; every rejected
    // candidate is deterministically closed before stale-return or retry.
    try { relay.close(); } catch { /* best-effort rejected candidate cleanup */ }
    if (!_isCurrentReconnect(lifecycleGeneration, url)) return;
    _scheduleReconnect(lifecycleGeneration, url);
    return;
  }

  if (!_isCurrentReconnect(lifecycleGeneration, url)) {
    try { relay.close(); } catch { /* best-effort stale candidate cleanup */ }
    return;
  }

  ext.relay = relay;
  ext.reconnectAttempt = 0;

  relay.on("close", () => _onRelayClose(relay));
  ext.stopAutoListener = _installAutoListener(relay);
  startGitRefresh(); // Plan/107b — resume room_meta.git polling

  // Plan/25 Wave B/C: relay is back; bring cross-PC routing back online.
  _attachBridgeIfReady();

  // Plan/32 — re-sync the cached room_meta (esp. `working`) to subscribers.
  // Closes the race where a turn_start fired during the disconnect window
  // (cached locally but never pushed) leaves the Home dot green.
  _republishRoomMeta();

  // ext.state stays "started"; peer reconnect (if previously paired) flows
  // through _installAutoListener → _findKnownPeer → _promoteToPaired
  // automatically when the app sends any inner.
  _emitRelayState();
}

// ── Relay state event + transparent control channel (Cockpit toggle) ─────────

/** Current relay connectivity, derived from `ext.state` + `ext.relay`. */
function _relayStatus(): RelayConnectivity {
  if (_getState() === "idle") return "disconnected";
  return ext.relay ? "connected" : "reconnecting";
}

/**
 * Emit the `remote-pi:relay-state` custom message so an RPC client (Cockpit)
 * can render a relay on/off indicator. Pure data (`display:false`) — never
 * shown in the transcript. De-duped on the connectivity value; pass
 * `force=true` to answer an explicit `relay:status` query regardless.
 */
function _emitRelayState(force = false): void {
  const status = _relayStatus();
  if (!force && status === ext.lastRelayStatus) return;
  ext.lastRelayStatus = status;
  ext.pi?.sendMessage({
    customType: "remote-pi:relay-state",
    content: `Relay ${status}`,
    details: {
      status,
      connected: status === "connected",
      ...(ext.relayUrl ? { relayUrl: ext.relayUrl } : {}),
      ...(ext.myRoomId ? { room: ext.myRoomId } : {}),
    },
    display: false,
  });
}

/** Minimal ctx for relay start/stop driven by a control message (no command
 *  ctx is available in the `input` hook). cwd matches the daemon's launch dir,
 *  so the derived relay room is identical to the one `_cmdStart` first used. */
function _controlCtx(): Pick<ExtensionContext, "ui" | "cwd"> {
  return {
    ui: _headlessUi(),
    cwd: process.cwd(),
  } as unknown as Pick<ExtensionContext, "ui" | "cwd">;
}

/**
 * `ui.notify` for headless contexts (daemon auto-init + control channel). There
 * is no TUI, and the RPC client (Cockpit) already gets everything it needs via
 * structured events (`remote-pi:relay-state`, `remote-pi:name-assigned`,
 * room_meta) — so routine INFO chatter would just pollute the client's captured
 * stderr. We drop info and forward only warnings/errors (kept for the
 * supervisor's journal / genuine failures). The interactive Pi keeps its normal
 * footer/notify path — this only affects headless ctxs.
 */
function _headlessUi(): { notify: (msg: string, type?: "info" | "warning" | "error") => void } {
  return {
    notify: (msg: string, type?: "info" | "warning" | "error") => {
      if (type === "warning" || type === "error") process.stderr.write(`${msg}\n`);
    },
  };
}

/**
 * Handle a transparent control command from an RPC client (Cockpit), received
 * as a `CTRL_PREFIX`-tagged input the `input` hook swallowed. Toggles the relay
 * WITHOUT leaving the local mesh (relay-only: `_cmdStart` up / `_goIdle` down),
 * then emits the fresh state. `relay:status` just re-emits (no change) so the
 * client can sync its button after (re)attaching to the RPC stream.
 */
export async function _handleControl(cmd: string): Promise<void> {
  // `rename:<new-name>` carries an argument, so it's matched before the
  // fixed-verb switch. Renames the agent live (broker re-register + relay room
  // swap) WITHOUT restarting the process or losing the SDK session.
  if (cmd.startsWith("rename:")) {
    await _renameAgent(cmd.slice("rename:".length).trim());
    return;
  }
  switch (cmd) {
    case "relay:on":
      if (_getState() === "idle") await _cmdStart(_controlCtx());
      _emitRelayState(true);
      return;
    case "relay:off":
      if (_getState() !== "idle") _goIdle("peer_stop");
      else {
        ext.rootLifecycleGeneration += 1;
        ext.relayLifecycleGeneration += 1;
      }
      _emitRelayState(true);
      return;
    case "relay:toggle":
      if (_getState() === "idle") await _cmdStart(_controlCtx());
      else _goIdle("peer_stop");
      _emitRelayState(true);
      return;
    case "relay:status":
      _emitRelayState(true);
      return;
    default:
      // Unknown control verb — ignore (forward-compat: a newer client may send
      // verbs an older extension doesn't know).
      return;
  }
}

/**
 * Rename the agent LIVE (plan/38/41), without restarting the process or losing
 * the SDK session/conversation. Touches two layers:
 *   1. **Broker (mesh)**: `MeshNode.rename` does a soft leave+rejoin → new
 *      address `<cwd>@<newName>` (broker may add `#N` on a same-(cwd,name)
 *      collision — we use the assigned result).
 *   2. **Relay room (App↔Pi)**: the room is keyed by `(cwd, name)`, so the new
 *      name = a new room. We cycle the relay (`_goIdle` → `_cmdStart`) so the
 *      room follows; the app re-keys the conversation onto the new tile (the
 *      inherent cost of room-per-name). Skipped when the relay was off.
 * Finally re-emits `remote-pi:name-assigned` so the Cockpit updates its label.
 *
 * The explicit name IS persisted (decision E only skips the runtime `#N`).
 */
async function _renameAgent(newName: string): Promise<void> {
  if (!newName) return;  // empty rename → no-op
  const ctx = _controlCtx();
  const cwd = process.cwd();
  saveLocalConfig(cwd, { agent_name: newName });

  if (!ext.meshNode) {
    // Not on the mesh yet — config persisted; applies on the next join.
    return;
  }

  // Relay room is derived from the name → cycle it so it follows. Tear down
  // first (also detaches the bridge) so the broker re-register below starts
  // clean; bring it back up after with the new name.
  const wasStarted = _getState() !== "idle";
  if (wasStarted) _goIdle("peer_stop");

  let assigned = newName;
  try {
    assigned = await ext.meshNode.rename(newName);  // broker soft rejoin
  } catch (err) {
    ctx.ui.notify(`[remote-pi] rename failed: ${String(err)}`, "error");
  }

  if (wasStarted && !ext.disposed) await _cmdStart(ctx);  // relay back up → roomIdFor(cwd, assigned)

  ext.pi?.sendMessage({
    customType: "remote-pi:name-assigned",
    content: assigned === newName
      ? `Mesh name: ${assigned}`
      : `Mesh name reassigned: "${newName}" → "${assigned}" (collision)`,
    details: { requested: newName, assigned, changed: assigned !== newName },
    display: false,
  });
}

/**
 * Per-owner disconnect callback. Fires when one specific owner's channel
 * detaches (e.g. relay told us the peer is gone). Other owners' channels
 * keep running — relay stays "started".
 *
 * Exported so tests can trigger the disconnect path for a specific peer.
 *
 * Backward-compat: a no-arg call (legacy tests / pre-W2D callers) falls
 * back to detaching the most recently attached peer, mirroring the old
 * singleton semantics.
 */
export function _onPeerDisconnect(appPeerId?: string): void {
  if (ext.state === "idle") return;
  const target = appPeerId ?? [...ext.activePeers.keys()].pop();
  if (!target) return;
  if (!ext.activePeers.has(target)) return;

  _detachPeerChannel(target);
  if (_anyPeerActive()) {
    // Other owners still attached — keep ext.currentTurnId so they continue
    // seeing the in-flight agent stream.
    _refreshFooter();
    return;
  }

  // No owner left. Conservatively clear the turn so the next pair_request
  // starts cleanly.
  ext.currentTurnId = null;
  _refreshFooter();
  _safeNotify("[remote-pi] All app peers disconnected, listening for reconnect", "info");
  // Auto-listener stays up — same listener catches the reconnect on any peer.
}

/**
 * Attaches a new owner channel to the multi-owner set. Replaces the
 * pre-W2D singleton `_promoteToPaired` which set `ext.state = "paired"` and
 * a single `_peerChannel`. The relay state remains `started`; pairing
 * status is derived from `ext.activePeers.size`.
 *
 * Idempotent for the same `appPeerId` (re-attaching tears down the prior
 * channel and installs a fresh one — covers reconnect from the same
 * device without leaking listeners).
 */
function _attachOwner(
  relay: RelayClient,
  appPeerId: string,
  peerName: string,
  firstInner?: ClientMessage,
): PlainPeerChannel {
  const peerShort = appPeerId.slice(0, 8);

  // Drop any stale channel for this owner before re-attaching.
  if (ext.activePeers.has(appPeerId)) _detachPeerChannel(appPeerId);

  // Prefer always-fresh session_start ctx for async relay routing — `ext.lastCtx`
  // is a captured command ctx that goes stale after session replacement (#55).
  const channel = new PlainPeerChannel(
    relay,
    appPeerId,
    ext.myRoomId ?? undefined,
    (msg) => _routeClientMessageFrom(channel, msg, (_liveCtx() as typeof _noopCtx) ?? _noopCtx),
    () => _onPeerDisconnect(appPeerId),
    _innerSigPolicy(),
  );

  _attachPeerChannel(appPeerId, channel);
  _refreshFooter();

  _safeNotify(
    `[remote-pi] Owner attached: peer=${peerShort}, name=${peerName} ` +
    `(${ext.activePeers.size} active)`,
    "info",
  );

  if (firstInner) {
    // The PlainPeerChannel listener fired on the same line that triggered
    // attachment in some flows; we route explicitly here too to ensure the
    // inner reaches the handler exactly once.
    void firstInner;
  }
  return channel;
}

// ── Auto-listener ─────────────────────────────────────────────────────────────
//
// Installed while in 'started' state. Decodes the outer envelope as
// base64(JSON) and dispatches per sender peer_id:
//   • Sender already in `ext.activePeers` → ignored here (the per-owner
//     PlainPeerChannel listens on the same relay event and handles its own
//     traffic via its `remotePeerId` filter)
//   • `pair_request` from a new peer → validate token, persist peer, send
//     pair_ok/pair_error, attach a new channel
//   • Non-pair message from a known peer (peers.json) without an active
//     channel yet → attach + route the inner (reconnect path)
//   • Anything else (unknown peer + non-pair) → emit `error: unknown_peer`

/**
 * Security fix 2026-08 — inner-envelope signature policy for channels created
 * by this process. Signs outbound, verifies inbound, ratchets peers.json.
 * Returns undefined when the cached keypair isn't available yet (pre-start).
 *
 * The enforcement ratchet is an in-memory map so delivery decisions stay
 * synchronous (a per-frame file read would break same-tick replies). Warmed
 * once at policy creation; flipped in-memory the moment a valid signature is
 * verified, and persisted to peers.json best-effort.
 */
const _signingRatchet = new Map<string, boolean>();
let _signingRatchetWarm = false;

let _ratchetWarmPromise: Promise<void> | null = null;

function _warmSigningRatchet(): void {
  if (_signingRatchetWarm || _ratchetWarmPromise) return;
  _signingRatchetWarm = true;
  // PR #25 review #2: the ratchet must be LOADed before any unsigned-frame
  // decision is made — an async gap here reopens the strip/forge window for
  // persisted peers right after restart. Auto-listener entry awaits this.
  _ratchetWarmPromise = (async () => {
    try {
      const peers = await listPeers();
      for (const peer of peers) {
        if (peer?.signing !== true) continue;
        // PR #24 follow-up (#3): key the ratchet by the CANONICAL spelling —
        // peers.json preserves raw handles (possibly base64url) while the
        // relay asserts standard base64. Raw-keyed entries would never match
        // at verify time and the ratchet would silently vanish on restart.
        try {
          _signingRatchet.set(
            canonicalizeEd25519PublicKey(peer.remote_epk, "stored Owner public key"),
            true,
          );
        } catch {
          // Unparseable handle — cannot match any relay peer id; skip.
        }
      }
    } catch {
      _signingRatchetWarm = false; // retry on next policy creation
      _ratchetWarmPromise = null;
    }
  })();
}

/** Awaits the ratchet warm-up (instant when already loaded). Every inbound
 *  unsigned-frame decision waits here — closes the restart race (#25 #2). */
function _awaitRatchetWarm(): Promise<void> {
  _warmSigningRatchet();
  return _ratchetWarmPromise ?? Promise.resolve();
}

/** Peers that demonstrated v2 (verified sig2) — v1-only from them drops. */
const _peerV2 = new Map<string, boolean>();

/** Policy-level replay dedup, per peer, bounded LRU (survives reconnects —
 *  PR #25 review #3). */
const _seenIdsByPeer = new Map<string, string[]>();
const _seenIdsByPeerSet = new Map<string, Set<string>>();
const SEEN_IDS_PER_PEER = 2048;

function _seenIdFor(peerId: string, id: string): boolean {
  let order = _seenIdsByPeer.get(peerId);
  let set = _seenIdsByPeerSet.get(peerId);
  if (!order || !set) {
    order = [];
    set = new Set();
    _seenIdsByPeer.set(peerId, order);
    _seenIdsByPeerSet.set(peerId, set);
  }
  if (set.has(id)) return true;
  if (order.length >= SEEN_IDS_PER_PEER) {
    const oldest = order.shift();
    if (oldest !== undefined) set.delete(oldest);
  }
  order.push(id);
  set.add(id);
  return false;
}

/** Test-only: clears the module-level signature-ratchet/v2/dedup state so
 *  suite tests don't share replay-dedup entries (each test re-pairs the same
 *  peer id with the same message ids). */
export function _resetInnerSigStateForTest(): void {
  _signingRatchet.clear();
  _signingRatchetWarm = false;
  _ratchetWarmPromise = null;
  _peerV2.clear();
  _seenIdsByPeer.clear();
  _seenIdsByPeerSet.clear();
}

function _innerSigPolicy() {
  const kp = ext.cachedEd25519;
  if (!kp) return undefined;
  _warmSigningRatchet();
  return {
    keypair: kp,
    ownPeerId: Buffer.from(kp.publicKey).toString("base64"),
    now: () => Date.now(),
    requiresSignature: (peerId: string) => _signingRatchet.get(peerId) === true,
    peerV2: (peerId: string) => _peerV2.get(peerId) === true,
    seenId: (peerId: string, id: string) => _seenIdFor(peerId, id),
    onSignaturePresent: (peerId: string) => {
      // Flip in-memory synchronously (review #4 — close the async gap before
      // verification completes). Persisting waits for a VALID v2 signature:
      // a present-but-garbage sig flips only the in-memory flag, which is
      // equivalent to the relay stripping future sigs — no new power.
      _signingRatchet.set(peerId, true);
    },
    onV2Verified: (peerId: string) => {
      _peerV2.set(peerId, true);
    },
    onSignatureVerified: (peerId: string) => {
      void markPeerSigning(peerId).catch(() => {
        // Best-effort persist — the in-memory flag already enforces for this
        // process; peers.json catches up on the next verified frame or restart.
      });
    },
  };
}

/** Verdict for auto-listener paths (pair_request + reconnect). */
type InboundOuterVerdict =
  | { ok: true; version: 1 | 2 }
  | { ok: false };

/**
 * Verifies an inbound outer envelope for the paths that bypass a live
 * PlainPeerChannel (pair_request + reconnect, both in the auto-listener).
 * Dual-sig scheme: `sig2` strict v2 (dest + ts), `sig`-only = legacy v1
 * (dropped when the peer is v2-ratcheted — downgrade strip). Callers MUST
 * have awaited [_awaitRatchetWarm] before calling this (restart race #2).
 */
function _verifyInboundOuter(
  peer: string,
  ct: string,
  sig: string | undefined,
  sig2: string | undefined,
  ts: unknown,
): InboundOuterVerdict {
  const policy = _innerSigPolicy();
  if (!policy) return { ok: true, version: 1 }; // pre-start — legacy behavior
  const hasSig2 = typeof sig2 === "string" && sig2.length > 0;
  const hasSig = typeof sig === "string" && sig.length > 0;
  if (hasSig2 || hasSig) policy.onSignaturePresent(peer);
  if (hasSig2) {
    const verdict = verifyInnerDual(peer, policy.ownPeerId, ct, sig, sig2, ts, policy.now());
    if (!verdict.ok) return { ok: false };
    policy.onV2Verified(peer);
    policy.onSignatureVerified(peer);
    return { ok: true, version: 2 };
  }
  if (hasSig) {
    if (policy.peerV2(peer)) return { ok: false }; // downgrade strip
    const verdict = verifyInnerDual(peer, policy.ownPeerId, ct, sig, undefined, undefined, policy.now());
    if (!verdict.ok) return { ok: false };
    return { ok: true, version: 1 };
  }
  return policy.requiresSignature(peer) ? { ok: false } : { ok: true, version: 1 };
}

/** Signs a raw outer envelope body when the cached keypair is available. */
function _signedOuterBody(
  peer: string,
  ct: string,
): Record<string, string | number> {
  const kp = ext.cachedEd25519;
  if (!kp) return { peer, ct };
  // Dual-sign (PR #25 review #1): v1 `sig` keeps legacy recipients verifying;
  // v2 `sig2`+`ts` carries the recipient binding + replay window.
  const ts = Date.now();
  return {
    peer,
    ct,
    ts,
    sig: signInnerCt(kp.secretKey, ct),
    sig2: signInnerCtV2(kp.secretKey, peer, ts, ct),
  };
}

function _installAutoListener(relay: RelayClient): () => void {
  const listenerGeneration = ext.relayLifecycleGeneration;
  const hasListenerAuthority = (): boolean =>
    !ext.disposed &&
    ext.state === "started" &&
    ext.relay === relay &&
    ext.relayLifecycleGeneration === listenerGeneration;
  const onMsg = async (line: string) => {
    let outer: { peer?: string; ct?: string; sig?: string; sig2?: string; ts?: unknown };
    try { outer = JSON.parse(line) as { peer?: string; ct?: string; sig?: string }; }
    catch { return; }

    if (!outer.peer || !outer.ct) return;

    // PR #25 review #2 — block every unsigned-frame decision until the
    // persisted ratchet has loaded; right after restart this closes the
    // window where a forged unsigned frame would pass `requiresSignature`.
    await _awaitRatchetWarm();
    if (!hasListenerAuthority()) return;
    // Already-attached owners: their PlainPeerChannel handles routing.
    if (ext.activePeers.has(outer.peer)) return;

    // Decode inner envelope (base64 JSON)
    let inner: ClientMessage;
    try {
      const plaintext = Buffer.from(outer.ct, "base64").toString("utf8");
      const parsed = JSON.parse(plaintext) as unknown;
      if (
        !parsed ||
        typeof parsed !== "object" ||
        typeof (parsed as Record<string, unknown>).type !== "string"
      ) return;
      inner = parsed as ClientMessage;
    } catch { return; }

    const appPeerId = outer.peer;

    if (inner.type === "pair_request") {
      // Security fix 2026-08 — a pair_request with a BAD signature is dropped
      // outright; a valid v2 one ratchets the peer to `signing` (below); a
      // v1/unsigned one is the legacy path (token still gates pairing).
      const verdict = _verifyInboundOuter(appPeerId, outer.ct, outer.sig, outer.sig2, outer.ts);
      if (!verdict.ok) return;
      await _handlePairRequest(
        relay,
        appPeerId,
        inner,
        hasListenerAuthority,
        verdict.version === 2,
      );
      return;
    }

    // Reconnect path: known peer (peers.json) without an active channel
    // sends a non-pair message → attach + route through the new channel.
    // See pairing.md §Reconexão.
    const known = await _findKnownPeer(appPeerId);
    if (!hasListenerAuthority()) return;
    if (known) {
      // Security fix 2026-08 — same gate as the live channel applies (invalid
      // sig drops; unsigned drops once the peer has ratcheted).
      if (!_verifyInboundOuter(appPeerId, outer.ct, outer.sig, outer.sig2, outer.ts).ok) return;
      const channel = _attachOwner(relay, appPeerId, known.name);
      // PR #25 review #3 — route the triggering ct through the channel's
      // normal pipeline (parse → POLICY dedup → dispatch) instead of
      // bypassing _deliver: a reconnect-time replay of a captured frame hits
      // the same seen-id LRU and is dropped.
      channel.deliverVerified(outer.ct);
      return;
    }

    // Unknown peer with non-pair_request inner — signal so the app can react
    // (peer was revoked / never paired). pair_request from unknown peer was
    // already handled above as a legitimate path. We never log inner contents,
    // only inner.type.
    const errReply: ServerMessage = {
      type: "error",
      code: "unknown_peer",
      message: "Peer not paired — re-scan QR",
    };
    const errCt = Buffer.from(JSON.stringify(errReply)).toString("base64");
    relay.send(JSON.stringify(_signedOuterBody(appPeerId, errCt)));
  };

  relay.on("message", onMsg);
  return () => relay.off("message", onMsg);
}

/**
 * Plan/27 Wave A: lazily resolve the pi-extension package version from
 * disk so the `pair_ok.harness.version` field reflects what's actually
 * shipped. The lookup is best-effort — a parse failure (or running this
 * file out-of-tree) falls back to "0.0.0" which is still semver-valid
 * and the app tolerates it. Cached at module load.
 */
function _readExtensionVersion(): string {
  try {
    const here = fileURLToPath(import.meta.url);
    // dist/index.js → ../package.json. src/index.ts under tsx → also one level up.
    const pkgPath = join(here, "..", "..", "package.json");
    const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as { version?: string };
    return typeof pkg.version === "string" ? pkg.version : "0.0.0";
  } catch {
    return "0.0.0";
  }
}
const _HARNESS = {
  name: "Pi coding agent",
  version: _readExtensionVersion(),
} as const;
const _HOSTNAME = hostname();

async function _handlePairRequest(
  relay: RelayClient,
  appPeerId: string,
  inner: Extract<ClientMessage, { type: "pair_request" }>,
  hasListenerAuthority: () => boolean,
  pairSignedV2?: boolean,
): Promise<void> {
  const sendInner = (msg: ServerMessage) => {
    const ct = Buffer.from(JSON.stringify(msg)).toString("base64");
    relay.send(JSON.stringify(_signedOuterBody(appPeerId, ct)));
  };

  const sendError = (code: PairErrorCode, message: string) => {
    sendInner({ type: "pair_error", in_reply_to: inner.id, code, message });
  };

  const status = qrSession.consumeToken(inner.token);
  if (status !== "ok") {
    const code: PairErrorCode =
      status === "expired"  ? "token_expired"
      : status === "consumed" ? "token_consumed"
      : "token_unknown";
    const msg =
      code === "token_expired"  ? "Ephemeral token expired. Generate a new QR with /remote-pi pair."
      : code === "token_consumed" ? "Token already consumed by another pair_request."
      : "Token was not issued by this Pi.";
    sendError(code, msg);
    return;
  }

  // A delayed signed revoke must lose authority before the same-process
  // re-pair enters storage; the replacement owns a fresh token snapshot.
  const producer = ext.selfRevoke;
  const producerEpoch = ext.selfRevokeEpoch;
  producer?.invalidateStorageAuthority();
  const pairedAt = new Date().toISOString();
  try {
    await addPeer({
      name: inner.device_name,
      remote_epk: appPeerId,
      paired_at: pairedAt,
      // Security fix 2026-08 — the pair frame arrived with a VALID v2
      // signature (dest-bound, fresh — verified by the auto-listener) → this
      // peer speaks the new scheme; enforce signatures from now on.
      ...(pairSignedV2 ? { signing: true } : {}),
    });
    if (!hasListenerAuthority()) return;
    _refreshPairingsCache();
    if (producer && ext.selfRevoke === producer && ext.selfRevokeEpoch === producerEpoch) {
      void producer.requestFreshCheck().catch(() => {
        // The regular cadence retries; pairing itself already succeeded.
      });
    }
  } catch (err) {
    if (!hasListenerAuthority()) return;
    sendError("internal_error", `Failed to persist peer: ${String(err)}`);
    return;
  }

  const cwd = ext.lastCtx && "cwd" in ext.lastCtx
    ? (ext.lastCtx as ExtensionCommandContext).cwd
    : process.cwd();
  // Prefer the user-configured agent_name (with broker suffix when on the
  // mesh) over the legacy parent/folder path — matches what the user sees
  // in the terminal title and in /remote-pi status.
  const sessionName = _displayName(cwd);

  _attachOwner(relay, appPeerId, inner.device_name);

  sendInner({
    type: "pair_ok",
    in_reply_to: inner.id,
    session_name: sessionName,
    session_started_at: ext.sessionStartedAt ?? Date.now(),
    // App uses this to address subsequent inner messages to the right room
    // when this Pi runs alongside others with the same epk. Defensive fallback
    // to roomIdFor(cwd, name) covers the edge case where pair_request lands
    // before _cmdStart could set ext.myRoomId (shouldn't happen in practice) —
    // and stays plan/41-consistent (same (cwd, name) derivation as the announce).
    room_id: ext.myRoomId ?? roomIdFor(cwd, sessionName),
    // Plan/27 Wave A — surface the host coding-agent identity + machine
    // hostname so the app can render a meaningful device row (and tell
    // two PCs apart even when nicknames collide).
    harness: _HARNESS,
    hostname: _HOSTNAME,
  });

  // Notify local RPC clients (e.g. Cockpit) that pairing completed, so they can
  // close the QR screen and show the new device. Pure data event (display:false)
  // — still emitted to the RPC stdout via the session stream.
  ext.pi?.sendMessage({
    customType: "remote-pi:paired",
    content: `Paired with ${inner.device_name}`,
    details: { name: inner.device_name, peerId: appPeerId, pairedAt },
    display: false,
  });
}

// ── Extension factory (default export) ───────────────────────────────────────

// Stores most recent command context so the auto-listener can use ui.notify.
// NOTE: this is a CAPTURED command ctx — the SDK marks it stale after a
// session replacement (newSession/fork/switch/reload). We re-capture it via
// `withSession` when WE drive a newSession (see the session_new dispatch).
// Freshest base ExtensionContext, re-captured on EVERY `session_start`
// (startup/new/fork/reload/resume). The session_start ctx is always bound to
// the CURRENT session, so compact + cancel (base-ctx methods) routed through
// here never hit a stale ctx — regardless of who triggered the replacement
// (an app Quick Action OR a `/new` typed in the Pi TUI). It carries only
// base-ctx methods (no newSession — that's command-ctx only), so command ops
// keep using `ext.lastCtx`.
const _noopCtx = { ui: { notify: () => undefined }, abort: () => undefined };

// A single Pi process can load this extension TWICE in the SAME session:
// pi-supervisord launches each daemon child as `pi -e <dist>/index.js`, but if
// remote-pi is ALSO installed as a pi-package (auto-discovered from
// ~/.pi/agent/extensions or <cwd>/.pi/extensions), Pi loads it a second time
// for that same session. Both loads receive the same session-scoped `pi` and
// would re-run registerTool/registerCommand for identical names — a hard
// duplicate-registration conflict that crashes the daemon child on boot (see
// daemon/rpc_child.ts). Idempotent, first-load-wins: whichever load runs first
// does all the wiring; the duplicate is an inert no-op. A genuine session
// REPLACEMENT gets a FRESH `pi`, so re-registration for the new session still
// happens.
//
// We track "already wired" in a process-global WeakSet keyed by `pi` rather
// than by mutating the host SDK object. The two loads are DISTINCT module
// instances (the SDK's jiti loader uses moduleCache:false, and the `-e` path vs
// the installed path resolve to different files), so a module-level Set can't
// dedupe them; the WeakSet lives on `globalThis` under a `Symbol.for` key so
// both module instances resolve the SAME set. Keying weakly by `pi` records the
// fact without adding a foreign property to the API object and lets each `pi`
// be GC'd when its session ends (no leak).
const _APPLIED_REGISTRY_KEY = Symbol.for("remote-pi.extension.appliedRegistry");
function _appliedRegistry(): WeakSet<object> {
  const g = globalThis as typeof globalThis & { [_APPLIED_REGISTRY_KEY]?: WeakSet<object> };
  return (g[_APPLIED_REGISTRY_KEY] ??= new WeakSet<object>());
}

const extension: ExtensionFactory = (pi: ExtensionAPI): void => {
  const applied = _appliedRegistry();
  if (applied.has(pi)) return;  // this session's pi was already wired
  applied.add(pi);

  ext.pi = pi;

  // Plan/100 — bridge @eko24ive/pi-ask clarification flows to the paired app.
  // Inert when pi-ask isn't installed (no events fire) or the SDK exposes no
  // events bus. ask_user without pi-ask doesn't exist, so this never breaks a
  // Pi that doesn't use the extension. Dispose any prior bridge first so a
  // factory re-run (new pi session) can't leak subscriptions or double-send.
  ext.extensionUiBridge?.dispose();
  ext.extensionUiBridge = createExtensionUiBridge(pi, _broadcastToActive);

  // Plano 19: ensure ~/.pi/piper/{sessions,skills}/ exist and deploy the
  // agent-network skill on first load. resources_discover lets Pi find it.
  try {
    ensureGlobalDirs();
    _deployAgentNetworkSkill();
  } catch { /* best-effort init */ }

  // Seed the global-pairings cache from peers.json so the footer can show
  // 🟢/🟡 correctly the moment the relay is up (no race with first refresh).
  _refreshPairingsCache();

  pi.on("resources_discover", () => ({ skillPaths: [skillsDir()] }));

  // Plano 20: agent_send + agent_request tools so the LLM can drive the
  // session network natively. Getter captures `ext.meshNode` live so the
  // tool always sees the current state.
  registerAgentTools(pi, () => ext.meshNode?.peer() ?? null);
  // Inject the two cross-cutting concerns the image pipeline needs from the
  // host (broadcasting to owners + "any peer active?") so the pipeline module
  // has no back-dependency on this one (avoids an import cycle).
  const imageDeps: ImagePipelineDeps = { broadcast: _broadcastToActive, anyPeerActive: _anyPeerActive };
  registerShowImageTool(pi, imageDeps);
  registerShowFileTool(pi, imageDeps);
  registerReceivedImageRenderer(pi);

  // Received-image preview entries are for local TUI display only. Pi's custom
  // messages normally become user-role LLM context, so strip this type before
  // every provider request; the actual Android image still reaches the model via
  // the paired sendUserMessage call.
  pi.on("context", (event) => ({
    messages: filterReceivedImageMessagesFromContext(event.messages),
  }));

  // Tool calls execute without prompting the remote user. The Pi SDK has no
  // native `requiresApproval` per tool, and a hardcoded gate (Bash/Edit/Write)
  // misfired on every custom tool from third-party packages. Approval will
  // come back when the Pi ecosystem ships a permissions convention. tool_result
  // is still forwarded so the app shows tool activity transparently.

  // Mirror input typed in the Pi terminal (or sent via RPC) to every
  // connected owner. 'extension' source is our own sendUserMessage call
  // from routeClientMessage, which already set ext.currentTurnId — skip to
  // avoid a double turnId.
  pi.on("input", (event) => {
    // Transparent control channel: a `CTRL_PREFIX`-tagged input from an RPC
    // client (Cockpit button) toggles the relay. Run it and SWALLOW the input
    // (`action:"handled"`) so it never reaches the LLM or the transcript.
    // Checked first, before the peer-broadcast path, and regardless of source.
    if (event.text.startsWith(CTRL_PREFIX)) {
      void _handleControl(event.text.slice(CTRL_PREFIX.length).trim());
      return { action: "handled" } as const;
    }
    if (!_anyPeerActive()) return;
    if (event.source === "extension") return;
    const turnId = `local_${randomUUID()}`;
    ext.currentTurnId = turnId;
    _broadcastToActive({ type: "user_input", id: turnId, text: event.text });
    return undefined;
  });

  // Track active model so the app can show it in the SessionTile (plano 18).
  // SDK fires model_select on settings load + every user switch. We cache the
  // friendly name and broadcast a room_meta_update so the relay can fan it
  // out to subscribed apps without needing a new pair.
  pi.on("model_select", (event) => {
    const m = event?.model as { name?: string; id?: string } | undefined;
    const modelName = m?.name ?? m?.id;
    if (!modelName) return;
    // Cache + fan out. Keeps the cached room_meta fresh so a future reconnect
    // carries the current model in its hello, and pushes a room_meta_update to
    // apps already subscribed.
    _setCurrentModel(modelName);
  });

  // Plan/28 Wave D.1: mirror model's room_meta_update path for thinking
  // level so the app hydrates the segmented control on first open instead
  // of starting null. SDK fires `thinking_level_select` on settings load
  // AND on every user toggle (matching `model_select`'s behavior), so
  // late-pairing apps see the current level via `room_meta_updated`.
  pi.on("thinking_level_select", (event) => {
    const level = event?.level as ThinkingLevel | undefined;
    if (!level) return;
    ext.currentThinking = level;
    if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, thinking: level };
    if (!ext.relay || !ext.myRoomId) return;
    ext.relay.sendControl({
      type: "room_meta_update",
      room_id: ext.myRoomId,
      meta: { thinking: level },
    });
  });

  pi.on("agent_start", () => {
    ext.agentRunActive = true;
    ext.agentRunGeneration += 1;
  });

  pi.on("message_start", (event) => {
    const message = event?.message as BufferMsg | undefined;
    if (!_anyPeerActive() || message?.role !== "user") return;
    _broadcastConsumedSteerForUserContent(message.content);
  });

  pi.on("message_update", (event) => {
    if (!_anyPeerActive() || !ext.currentTurnId) return;
    const ae = event.assistantMessageEvent;
    if (ae.type === "text_delta") {
      _bufferAgentChunk(ae.delta, ext.currentTurnId);
    }
  });

  // Notify every connected owner that a tool is about to run (visibility
  // only, NOT approval). tool_execution_start fires before the tool
  // executes; tool_execution_end closes the loop with the result. Together
  // they render a "Tool running… done" timeline in each paired app.
  pi.on("tool_execution_start", (event) => {
    if (!_anyPeerActive()) return;
    // Flush any coalesced text first so the phone's timeline keeps
    // chronological order (it finalizes the streaming segment on arrival
    // of the tool_request).
    _flushAgentChunks();
    _broadcastToActive({
      type: "tool_request",
      tool_call_id: event.toolCallId,
      tool: event.toolName,
      args: enrichToolArgs(event.toolName, event.args),
    });
  });

  pi.on("tool_execution_end", (event) => {
    if (!_anyPeerActive()) return;
    // Stringify like the history mapper (same helper) so the live text == what
    // a session_sync replays for this tool. Raw `String(event.result)` turned
    // a content-array/object into "[object Object]" and the success branch sent
    // the object unstringified — both diverging from re-sync.
    const text = stringifyToolResult(event.result);
    const msg: ServerMessage = event.isError
      ? { type: "tool_result", tool_call_id: event.toolCallId, error: text }
      : { type: "tool_result", tool_call_id: event.toolCallId, result: text };
    _broadcastToActive(msg);
  });

  // Cumulative session buffer fed via `message_end`, which fires once per
  // persisted message (user, assistant, toolResult) — same hook the SDK uses
  // to persist to sessionManager (see agent-session.js:298-309). Pushing here
  // accumulates the whole session over time, so session_sync can replay every
  // turn — including turns initiated from the Pi terminal (source:"interactive")
  // or RPC. Previous impl overwrote on `agent_end` and lost everything but the
  // last turn (see diagnostics 14, 15).
  pi.on("message_end", (event) => {
    const m = event?.message as { role?: string; content?: unknown; stopReason?: string; errorMessage?: string } | undefined;
    if (!m) return;
    if (m.role === "user" && _anyPeerActive()) {
      _broadcastConsumedSteerForUserContent(m.content);
    }
    if (m.role === "user" || m.role === "assistant" || m.role === "toolResult") {
      ext.messageBuffer.push(m as unknown as BufferMsg);
    }
    // Forward a failed turn to connected owners. Without this the app just
    // hangs with no response when the provider errors (e.g. the TUI's
    // "Provider finish_reason: error"): the SDK surfaces the failure as an
    // assistant message with stopReason "error" + an `errorMessage` (pi-ai).
    // `error` is an existing ServerMessage the app already renders — no
    // protocol/app change. `in_reply_to` ties it to the turn the app awaits.
    if (m.role === "assistant" && m.stopReason === "error" && _anyPeerActive()) {
      // Drain coalesced text before the error so no turn tail is lost.
      _flushAgentChunks();
      const message = typeof m.errorMessage === "string" && m.errorMessage
        ? m.errorMessage
        : "Provider error";
      const errMsg: ServerMessage = ext.currentTurnId
        ? { type: "error", in_reply_to: ext.currentTurnId, code: "provider_error", message }
        : { type: "error", code: "provider_error", message };
      _broadcastToActive(errMsg);
    }
    // Fan out live context-window usage so the app shows it next to the working
    // indicator. Refreshed per message — frequent enough for multi-step turns.
    _refreshContextUsage();
  });

  pi.on("agent_end", () => {
    // Buffer is fed by `message_end`; here we only finalize the outbound
    // turn signal to every connected owner. No buffer mutation.
    // Flush coalesced text FIRST — the phone finalizes the streaming
    // segment on agent_done, so the tail must land before the done frame.
    _flushAgentChunks();
    if (_anyPeerActive() && ext.currentTurnId) {
      _broadcastToActive({ type: "agent_done", in_reply_to: ext.currentTurnId });
      ext.currentTurnId = null;
    }
    flushPendingReceivedImagePreviews();
    ext.lastConsumedSteerText = null;
    _maybeDrainQueuedItem();
    _maybeDrainFollowUp();

    // agent_end listeners finish before pi-agent-core clears its active run.
    // Defer mesh delivery to the next event-loop turn so triggerTurn cannot
    // collide with the prompt that emitted this event. A queued continuation
    // may start first; its generation keeps the older timer from clearing the
    // new run's busy flag.
    const endedGeneration = ext.agentRunGeneration;
    setTimeout(() => {
      if (ext.agentRunGeneration !== endedGeneration) return;
      ext.agentRunActive = false;
      _scheduleMeshMessageDrain();
    }, 0);
  });

  // plan/34: the broker no longer gates delivery on busy state, so we no
  // longer notify it of turn lifecycle. Working state is still published as
  // room_meta over the relay (plan/32) below — that's independent of the
  // broker and drives the app's working indicator.
  pi.on("turn_start", (_event, ctx) => {
    // Late model hydration: if the model was still unknown at connect (resolved
    // lazily by the SDK), grab it on the first turn and fan it out — so a daemon
    // whose model only materialises at turn 1 still reports it to the app.
    if (!ext.currentModel) {
      try {
        const m = (ctx as Partial<ExtensionContext> & { getModel?: () => { name?: string; id?: string } | undefined }).getModel?.();
        const name = m?.name ?? m?.id;
        if (name) _setCurrentModel(name);
      } catch { /* defensive — never block a turn on a model lookup */ }
    }
    // Plan/32 Part B: publish working=true as room_meta (raw, no debounce —
    // the debounce lives in the app). Same shape as the model/thinking updates.
    if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, working: true };
    if (ext.relay && ext.myRoomId) {
      ext.relay.sendControl({ type: "room_meta_update", room_id: ext.myRoomId, meta: { working: true } });
    }
    _refreshContextUsage();
  });
  pi.on("turn_end", () => {
    // Plan/32 Part B: publish working=false as room_meta (raw, no debounce).
    if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, working: false };
    if (ext.relay && ext.myRoomId) {
      ext.relay.sendControl({ type: "room_meta_update", room_id: ext.myRoomId, meta: { working: false } });
    }
    _refreshContextUsage();
    _maybeDrainQueuedItem();
    _maybeDrainFollowUp();
    // Plan/109 — restore the live model after a one-shot override turn.
    void _revertModelOverride();
  });

  // Plan/32: compaction feedback. compact() doesn't run a turn, so bracket it
  // with working=true/false here. Returning void = no veto → default
  // compaction proceeds.
  pi.on("session_before_compact", (event) => {
    if (event.preparation) {
      event.preparation.messagesToSummarize = filterReceivedImageMessagesFromContext(
        event.preparation.messagesToSummarize,
      );
      event.preparation.turnPrefixMessages = filterReceivedImageMessagesFromContext(
        event.preparation.turnPrefixMessages,
      );
    }
    _publishWorking(true);
  });
  pi.on("session_compact", (event) => {
    const entry = event?.compactionEntry as { summary?: unknown; tokensBefore?: unknown } | undefined;
    const summary = typeof entry?.summary === "string" ? entry.summary : "";
    const tokensBefore = typeof entry?.tokensBefore === "number" ? entry.tokensBefore : 0;
    const ts = Date.now();
    // (2) Persist in history: the CompactionEntry never reaches ext.messageBuffer
    // via message_end (only user/assistant/toolResult), so push a synthetic
    // marker the mapper turns into a `compaction` event — survives session_sync.
    ext.messageBuffer.push({ role: "compaction", content: summary, timestamp: ts, tokensBefore });
    // (1) Live result to every connected owner.
    _broadcastToActive({ type: "compaction", summary, tokens_before: tokensBefore, ts });
    // (3) Working ends.
    _publishWorking(false);
    _maybeDrainQueuedItem();
    _maybeDrainFollowUp();
  });

  // Re-capture the freshest base ctx on every session replacement so compact
  // never operates on a stale captured ctx — this is the fix for the
  // "stale after session replacement" crash when the app taps Compact after a
  // New session. Fires on startup/new/fork/reload/resume; the ctx is always
  // bound to the current session.
  pi.on("session_start", (_event, ctx) => {
    ext.lastEventCtx = ctx;
    // session_shutdown disposes per-session pi-ask subscriptions. A host that
    // reuses this module instance does NOT re-run the factory, so rebind the
    // bridge here; fresh-module hosts already created theirs in the factory.
    if (!ext.extensionUiBridge) {
      ext.extensionUiBridge = createExtensionUiBridge(pi, _broadcastToActive);
    }
    // Rearm a reused-but-disposed instance. The session_shutdown teardown (below)
    // sets ext.disposed=true assuming the host re-evaluates THIS module fresh for the
    // replacement session, yielding a new instance with ext.disposed=false. Some hosts
    // instead REUSE the same module instance across ctx.newSession(). Rearm that
    // instance, but retain the shutdown generations as replacement authority:
    // `_cmdRoot` waits for any canceled outgoing root to drain, then starts exactly
    // one fresh lifecycle only if no later stop/shutdown superseded this session.
    // No-op when a fresh instance IS created and at first boot.
    if (ext.disposed) {
      ext.disposed = false;
      const restartAuthority: RootRestartAuthority = {
        rootLifecycleGeneration: ext.rootLifecycleGeneration,
      };
      void _cmdRoot(ctx, restartAuthority);
    }
    // Auto-start remote-pi on a fresh boot when the cwd's local config has
    // auto_start_relay enabled (default true). Covers BOTH interactive
    // sessions (previously required typing /remote-pi each session) AND
    // headless daemons. We init here — on session_start — NOT via a
    // factory-return setTimeout(0): the SDK only calls bindCore() (which
    // replaces the throwing action-method stubs like pi.sendMessage) right
    // before emitting session_start, so a setTimeout(0) from the factory
    // raced it and crashed with "Extension runtime not initialized" inside
    // _emitRelayState -> sendMessage. session_start fires strictly AFTER
    // bindCore (agent-session bindExtensions), so pi.sendMessage is a real
    // function here. Guarded by ext.autoInited so session replacements re-init
    // only via the ext.disposed path above. Daemon mode has no interactive UI →
    // use the headless ctx; interactive sessions use the real session_start
    // ctx (has ui.notify + dialogs for the first-run wizard).
    if (!ext.autoInited) {
      // Daemon: always init (supervisor sets REMOTE_PI_DIRECT_CONFIG so a config
      // is present at process.cwd()). Interactive: only init when the
      // session_start ctx announces its cwd AND a local config already exists
      // there — never auto-pop the first-run wizard on session_start (a new dir
      // with no config stays idle until the user runs /remote-pi once). The
      // cwd guard also keeps tests with a minimal ctx (no cwd) from triggering
      // the wizard path.
      const isDaemon = process.env["REMOTE_PI_DAEMON"] === "1";
      // One-shot / non-interactive Pi (`pi -p` / `pi --print`) is documented as
      // "process the prompt and exit". Auto-starting the relay there opens a WS
      // that is never `.unref()`'d, so the idle Node event loop never drains and
      // the process hangs forever after printing its answer (issue #44). Daemon
      // mode (REMOTE_PI_DAEMON=1) and normal interactive sessions never pass
      // `-p`/`--print`, so they still auto-start the relay exactly as before.
      const isPrintMode =
        process.argv.includes("-p") || process.argv.includes("--print");
      // Prefer the session_start ctx's cwd; fall back to process.cwd() when the
      // ctx omits it. Some session shapes arrive without `cwd`, which left
      // freshly-spawned worktree pis idle ("Relay: off") — the gate below saw
      // cwd=undefined and skipped auto-start even though the process runs in
      // the configured worktree dir (the session *dir* is still derived from
      // process.cwd(), so the two disagreed). Skipped under vitest so tests
      // with a minimal ctx keep the historical no-autostart behaviour.
      const cwd = isDaemon
        ? process.cwd()
        : "cwd" in ctx
          ? ctx.cwd
          : (process.env.VITEST ? undefined : process.cwd());
      if (
        !isPrintMode &&
        cwd &&
        localConfigExists(cwd) &&
        effectiveAutoStartRelay(loadLocalConfig(cwd))
      ) {
        ext.autoInited = true;
        const initCtx = isDaemon
          ? ({ ui: _headlessUi(), cwd: process.cwd() } as Pick<ExtensionContext, "ui" | "cwd">)
          : ctx;
        void _cmdRoot(initCtx);
      }
    }
  });

  // Tear down THIS instance's live handles when the SDK replaces the session
  // (switch_session / new / fork / reload / quit). This is the fix for the
  // "double mesh connection" the Cockpit hits when it restores a saved
  // conversation via switch_session on boot.
  //
  // Why it happens: the Pi SDK loads extensions through jiti with
  // `moduleCache: false`, so every session replacement re-evaluates THIS module
  // FRESH — a brand-new instance whose `ext.meshNode`, `ext.relay`, and `ext.cwdLock`
  // start back at null. The OUTGOING instance's broker socket, relay WS, and
  // cwd-lock UDS keep running regardless (module state is gone, but the OS
  // handles aren't). In daemon mode (REMOTE_PI_DAEMON=1, set by the Cockpit) the
  // fresh instance re-runs `_cmdRoot` on load, so without releasing the old
  // handles first we end up with TWO mesh peers under the same name on the
  // broker + two rooms on the relay. The per-cwd lock is meant to stop the
  // second connect, but its 500 ms connect-probe can miss the still-bound old
  // socket while the event loop is saturated at boot, fall through to the
  // stale-socket unlink path, and let the fresh instance bind a second lock.
  //
  // `session_shutdown` fires on the OUTGOING extension runner and is AWAITED by
  // the SDK (`teardownCurrent`) BEFORE the replacement runtime — and thus the
  // fresh extension instance — is created. Closing the mesh node, relay, and
  // lock here guarantees the next instance starts from a clean slate and stands
  // up exactly ONE connection bound to the restored session. Idempotent +
  // best-effort: every step is guarded so a partially-initialised instance
  // (e.g. shutdown lands mid-`_cmdRoot`) tears down without throwing.
  pi.on("session_shutdown", async () => {
    // Revoke async authority synchronously, before any teardown await. `ext.disposed`
    // blocks the outgoing continuation immediately; the root and candidate
    // generations keep queued work stale even if a same-module session_start
    // clears `ext.disposed` before its promises settle.
    ext.disposed = true;
    ext.rootLifecycleGeneration += 1;
    ext.relayLifecycleGeneration += 1;
    ext.meshJoinGeneration += 1;
    // The bridge owns live pi.events subscriptions + flow TTLs. Dispose before
    // the outgoing session is replaced so stale listeners cannot leak or
    // double-broadcast. session_start rebinds it on module-reuse hosts; fresh
    // module instances create their bridge in the factory.
    ext.extensionUiBridge?.dispose();
    ext.extensionUiBridge = null;
    // Drop captured ctxs immediately. On module-reuse hosts the same instance
    // survives session replacement; leaving `ext.lastCtx` pointing at the now-
    // stale command ctx is what crashed pi in _refreshFooter on peer reconnect
    // (issue #55). session_start re-binds `ext.lastEventCtx` for the new session.
    ext.lastCtx = null;
    ext.lastEventCtx = null;
    // No bye reason: the process keeps running and the fresh instance re-joins
    // the SAME relay room, so an explicit offline→online flap would be wrong.
    // Revoke producer/Relay/bridge authority while the global node is still
    // visible, before close() can begin its asynchronous UDS leave.
    if (ext.state !== "idle") {
      _goIdle();
    } else {
      ext.meshNode?.detachBridge();
    }

    const meshNode = ext.meshNode;
    ext.meshNode = null;
    ext.sessionName = null;
    ext.sessionPeerCount = 0;
    let meshClose: Promise<void> | null = null;
    try { meshClose = meshNode?.close() ?? null; } catch { /* best-effort */ }

    if (ext.cwdLock) {
      try { ext.cwdLock.release(); } catch { /* best-effort */ }
      ext.cwdLock = null;
      ext.lockedName = null;
    }
    try { await meshClose; } catch { /* best-effort */ }
  });

  // ── Commands ──────────────────────────────────────────────────────────────
  //
  // Final surface: 8 commands. Pre-2026-05-23 we had 20 commands covering
  // multi-session UDS + granular relay control; in practice every install
  // converged on one session and the relay was always either fully on or
  // fully off. The simplified surface keeps the day-to-day path one-key
  // (`/remote-pi`) and exposes only the actions that have distinct user
  // intent: setup, status, stop, pair, devices, revoke, set-relay.
  pi.registerCommand("remote-pi", {
    description: "Connect (join local mesh + start relay), or run setup on first use",
    getArgumentCompletions: async (prefix) => {
      if (prefix.startsWith("revoke ") || prefix === "revoke") {
        const shortPrefix = prefix === "revoke" ? "" : prefix.slice("revoke ".length);
        return _shortidCompletions(shortPrefix, "revoke ");
      }
      return [
        "setup", "status", "stop",
        "pair", "devices", "revoke",
        "rename",
        "set-relay", "set-advertise",
        "peers",  // plan/25 Wave D — local + cross-PC inventory
        "create", "remove", "daemons",  // daemon registry (plan/26 W1)
        // Fleet ops use the `daemon` prefix so `/remote-pi stop` keeps
        // meaning "stop this local Pi" — the local UX shipped in plan/25.
        "daemon start", "daemon stop", "daemon restart",
        "daemon send", "daemon status",
        "cron", "cron add", "cron list", "cron remove", "cron enable", "cron disable", "cron run", "cron log",
        "install", "uninstall",  // service install (plan/26 W3)
      ]
        .filter((o) => o.startsWith(prefix))
        .map((o) => ({ value: o, label: o }));
    },
    handler: async (args, ctx) => {
      ext.lastCtx = ctx;
      const sub = args.trim();
      if      (sub === "")                       { await _cmdRoot(ctx); }
      else if (sub === "setup")                  { await _cmdSetup(ctx); }
      else if (sub === "status")                 { _cmdStatus(ctx); }
      else if (sub === "stop")                   { await _cmdStop(ctx); }
      else if (sub === "pair" || sub.startsWith("pair ")) { await _cmdPair(ctx, sub.slice("pair".length).trim()); }
      else if (sub === "devices")                { await _cmdList(ctx); }
      else if (sub.startsWith("revoke"))         { await _cmdRevoke(sub.slice("revoke".length).trim(), ctx); }
      // set-advertise first: `startsWith("set-")` would not disambiguate, but
      // more importantly "set-relay" is not a prefix of "set-advertise", so
      // order only matters if a future subcommand shares a prefix. Keep them
      // adjacent so that stays visible.
      else if (sub.startsWith("set-advertise"))  { _cmdSetAdvertise(sub.slice("set-advertise".length).trim(), ctx); }
      else if (sub.startsWith("set-relay"))      { _cmdSetRelay(sub.slice("set-relay".length).trim(), ctx); }
      else if (sub === "rename" || sub.startsWith("rename ")) { await _renameAgent(sub.slice("rename".length).trim()); }
      else if (sub === "peers")                  { await _cmdPeers(ctx); }
      else if (sub.startsWith("create"))         { await cmdCreate(sub.slice("create".length).trim(), ctx); }
      else if (sub.startsWith("remove"))         { await cmdRemove(sub.slice("remove".length).trim(), ctx); }
      else if (sub === "daemons")                { await cmdDaemonsList(ctx); }
      else if (sub === "daemon start" || sub.startsWith("daemon start "))     { await cmdDaemonStart(ctx, sub.slice("daemon start".length).trim() || undefined); }
      else if (sub === "daemon stop" || sub.startsWith("daemon stop "))       { await cmdDaemonStop(ctx, sub.slice("daemon stop".length).trim() || undefined); }
      else if (sub === "daemon restart" || sub.startsWith("daemon restart ")) { await cmdDaemonRestart(ctx, sub.slice("daemon restart".length).trim() || undefined); }
      else if (sub === "daemon status")          { await cmdDaemonStatus(ctx); }
      else if (sub.startsWith("daemon send"))    { await cmdDaemonSend(sub.slice("daemon send".length).trim(), ctx); }
      else if (sub === "cron" || sub.startsWith("cron ")) { await cmdCron(sub.slice("cron".length).trim(), ctx); }
      else if (sub === "install")                { cmdInstall(ctx, { linkCli: true }); }
      else if (sub === "uninstall")              { cmdUninstall(ctx, { linkCli: true }); }
      else                                       { await _cmdRoot(ctx); }
    },
  });

  // Nested registrations (one entry per public action). The flat handler
  // above already routes `/remote-pi <sub>` — these exist for the SDK's
  // command palette and slash-autocomplete in some UI modes.
  pi.registerCommand("remote-pi setup",    { description: "Run the setup wizard and update local config", handler: async (_, ctx) => { ext.lastCtx = ctx; await _cmdSetup(ctx); } });
  pi.registerCommand("remote-pi status",   { description: "Show local mesh + relay status", handler: async (_, ctx) => { ext.lastCtx = ctx; _cmdStatus(ctx); } });
  pi.registerCommand("remote-pi stop",     { description: "Stop everything (leave local mesh + disconnect relay)", handler: async (_, ctx) => { ext.lastCtx = ctx; await _cmdStop(ctx); } });
  pi.registerCommand("remote-pi pair",     { description: "Show a QR code to pair a new mobile device (optional: --ttl <seconds>)", handler: async (args, ctx) => { ext.lastCtx = ctx; await _cmdPair(ctx, args.trim()); } });
  pi.registerCommand("remote-pi devices",  { description: "List paired mobile devices", handler: async (_, ctx) => { ext.lastCtx = ctx; await _cmdList(ctx); } });
  pi.registerCommand("remote-pi rename",  { description: "Rename this agent in the current session (updates mesh + relay room)", handler: async (args, ctx) => { ext.lastCtx = ctx; await _renameAgent(args.trim()); } });
  pi.registerCommand("remote-pi revoke", {
    description: "Revoke a paired device by its shortid",
    getArgumentCompletions: async (prefix) => _shortidCompletions(prefix),
    handler: async (args, ctx) => { ext.lastCtx = ctx; await _cmdRevoke(args.trim(), ctx); },
  });
  pi.registerCommand("remote-pi set-relay", { description: "Persist a new relay URL to user config", handler: async (args, ctx) => { ext.lastCtx = ctx; _cmdSetRelay(args.trim(), ctx); } });
  pi.registerCommand("remote-pi set-advertise", { description: "Set the address the pairing QR advertises (e.g. a Tailscale IP); empty clears it", handler: async (args, ctx) => { ext.lastCtx = ctx; _cmdSetAdvertise(args.trim(), ctx); } });

  // Plan/25 Wave D
  pi.registerCommand("remote-pi peers", {
    description: "List local + cross-PC mesh peers, grouped by PC label",
    handler: async (_, ctx) => { ext.lastCtx = ctx; await _cmdPeers(ctx); },
  });

  // Daemon registry (plan/26 Wave 1) — create + remove. start/stop/send/
  // status/install/uninstall come in later waves with the supervisor.
  pi.registerCommand("remote-pi create", {
    description: "Register a folder as a daemon and start it (when the supervisor is running)",
    handler: async (args, ctx) => { ext.lastCtx = ctx; await cmdCreate(args.trim(), ctx); },
  });
  pi.registerCommand("remote-pi remove", {
    description: "Stop + unregister a daemon by id (local config is preserved)",
    handler: async (args, ctx) => { ext.lastCtx = ctx; await cmdRemove(args.trim(), ctx); },
  });

  // Fleet ops via the supervisor (plan/26 W2). `/remote-pi stop` stays as
  // local stop — fleet stop is `/remote-pi daemon stop`.
  pi.registerCommand("remote-pi daemons",        { description: "List registered daemons + state", handler: async (_, ctx) => { ext.lastCtx = ctx; await cmdDaemonsList(ctx); } });
  pi.registerCommand("remote-pi daemon start",   { description: "Start daemons: all, or one by id (`daemon start <id>`)", handler: async (args, ctx) => { ext.lastCtx = ctx; await cmdDaemonStart(ctx, args.trim() || undefined); } });
  pi.registerCommand("remote-pi daemon stop",    { description: "Stop daemons: all, or one by id (`daemon stop <id>`)", handler: async (args, ctx) => { ext.lastCtx = ctx; await cmdDaemonStop(ctx, args.trim() || undefined); } });
  pi.registerCommand("remote-pi daemon restart", { description: "Restart daemons: all, or one by id (`daemon restart <id>`)", handler: async (args, ctx) => { ext.lastCtx = ctx; await cmdDaemonRestart(ctx, args.trim() || undefined); } });
  pi.registerCommand("remote-pi daemon status",  { description: "Show fleet runtime status (pid, uptime, restarts)", handler: async (_, ctx) => { ext.lastCtx = ctx; await cmdDaemonStatus(ctx); } });
  pi.registerCommand("remote-pi daemon send",    { description: "Send a prompt to a daemon: `daemon send <id> \"<text>\"`", handler: async (args, ctx) => { ext.lastCtx = ctx; await cmdDaemonSend(args.trim(), ctx); } });
  pi.registerCommand("remote-pi cron",           { description: "Schedule recurring prompts to daemons: `cron <add|list|remove|enable|disable|run|log>`", handler: async (args, ctx) => { ext.lastCtx = ctx; await cmdCron(args.trim(), ctx); } });

  // Service install / uninstall (plan/26 W3)
  pi.registerCommand("remote-pi install",   { description: "Install pi-supervisord as a system service + link the remote-pi CLI (systemd/launchd/Task Scheduler; Windows prompts for admin)", handler: async (_, ctx) => { ext.lastCtx = ctx; cmdInstall(ctx, { linkCli: true }); } });
  pi.registerCommand("remote-pi uninstall", { description: "Remove the pi-supervisord system service + the CLI shims (daemons registry preserved; Windows prompts for admin)", handler: async (_, ctx) => { ext.lastCtx = ctx; cmdUninstall(ctx, { linkCli: true }); } });

  // Auto-init now runs from the session_start handler (above), AFTER the
  // SDK calls bindCore(). The original setTimeout(0) here fired before bindCore
  // replaced the throwing action-method stubs, so the first pi.sendMessage in
  // _emitRelayState crashed the headless pi process with "Extension runtime not
  // initialized" in a 5s supervisor crash-loop. The session_start handler now
  // auto-starts for ANY session with auto_start_relay (default true), so new
  // interactive pi sessions are on remote automatically — no /remote-pi needed.
};

export default extension;

// ── Command implementations ───────────────────────────────────────────────────

/**
 * `/remote-pi status` — full state snapshot. Two lines: local mesh + relay.
 *
 * Always callable; safe when nothing is up (renders the off variants).
 * Reuses the same icons as the footer so terminal + status output stay
 * visually consistent.
 */
function _cmdStatus(ctx: Pick<ExtensionContext, "ui">): void {
  const relayUrl = ext.relayUrl ?? resolveRelayUrl().url;

  // Mesh line
  let meshLine: string;
  if (ext.meshNode) {
    const name = ext.meshNode.name();
    meshLine = `🟢 Local mesh: connected as "${name}" (${ext.sessionPeerCount} peer${ext.sessionPeerCount === 1 ? "" : "s"})`;
  } else {
    meshLine = "⚪ Local mesh: not connected";
  }

  // Relay line — paired state is derived from ext.activePeers.size now.
  let relayLine: string;
  if (ext.state === "idle") {
    relayLine = `⚪ Relay: off (${relayUrl}) — run /remote-pi to start`;
  } else if (ext.activePeers.size > 0) {
    const count = ext.activePeers.size;
    const shortids = [...ext.activePeers.keys()].map((peerId) => peerId.slice(0, 8)).join(", ");
    relayLine = `🟢 Relay: ${count} owner${count === 1 ? "" : "s"} online (${shortids}) (${relayUrl})`;
  } else {
    relayLine = ext.hasGlobalPairings
      ? `🟢 Relay: on, waiting for an app to connect (${relayUrl})`
      : `🟡 Relay: on, waiting for first pairing (${relayUrl})`;
  }

  // Advertise line — only when it differs from the relay URL, i.e. when the
  // phone dials a different address than this process does. That is the whole
  // point of the split, and the one case where "which URL is in effect?" has
  // two answers, so it is also the one case worth spelling out.
  const advertised = resolveAdvertisedRelayUrl((url) => toPhoneReachableUrl(url));
  const advertiseLine =
    advertised && advertised !== relayUrl
      ? `\n  📱 Pairing QR advertises: ${advertised}`
      : "";

  ctx.ui.notify(`[remote-pi]\n  ${meshLine}\n  ${relayLine}${advertiseLine}`, "info");
}

/**
 * Plan/25 Wave D: `/remote-pi peers`.
 *
 * Queries the local broker for the aggregated peer inventory (`list_peers`
 * returns locals + cross-PC entries prefixed with `<pc_label>:`). Formats
 * the result grouped by source so users can see at a glance who's on
 * their machine vs. on a paired sibling Pi.
 */
async function _cmdPeers(ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  if (!ext.meshNode) {
    ctx.ui.notify("[remote-pi] Not on the local mesh. Run /remote-pi to join.", "warning");
    return;
  }
  let peers: string[];
  try {
    const reply = await ext.meshNode.request("broker", { type: "list_peers" }, 2000);
    peers = (reply.body as { peers?: string[] } | null)?.peers ?? [];
  } catch (err) {
    ctx.ui.notify(`[remote-pi] peers list failed: ${String(err)}`, "error");
    return;
  }
  // Exclude self from the printed list — `list_peers` returns every peer
  // registered with the broker including the caller, which is noise here.
  const selfName = ext.meshNode.name();
  ctx.ui.notify(`[remote-pi] peers:\n${formatPeerInventory(peers, selfName)}`, "info");
}

/**
 * Root handler for `/remote-pi`. On first run (no local config) drops into
 * the wizard; on subsequent runs auto-joins the local mesh + starts the
 * relay (if opted in during setup), then prints the status.
 *
 * `/remote-pi` is intentionally the only command users need day-to-day:
 * idempotent connect + status display.
 */
async function _cmdRoot(
  ctx: Pick<ExtensionContext, "ui" | "cwd">,
  restartAuthority?: RootRestartAuthority,
): Promise<void> {
  const rootLifecycleGeneration = restartAuthority?.rootLifecycleGeneration
    ?? ext.rootLifecycleGeneration;

  if (ext.cmdRootInFlight) {
    try {
      await ext.cmdRootInFlight;
    } catch (err) {
      // Stale authority stops here. A current normal duplicate preserves the
      // outgoing error, while a current replacement suppresses that old-session
      // failure and falls through to start one fresh root below.
      if (!_isCurrentRootLifecycle(rootLifecycleGeneration)) return;
      if (!restartAuthority) throw err;
    }
    if (!_isCurrentRootLifecycle(rootLifecycleGeneration)) return;
    if (!restartAuthority) {
      _cmdStatus(ctx);
      return;
    }
  }

  if (!_isCurrentRootLifecycle(rootLifecycleGeneration)) return;

  const run = _cmdRootInner(ctx, rootLifecycleGeneration);
  ext.cmdRootInFlight = run;
  try {
    await run;
  } finally {
    if (ext.cmdRootInFlight === run) ext.cmdRootInFlight = null;
  }
}

async function _cmdRootInner(
  ctx: Pick<ExtensionContext, "ui" | "cwd">,
  rootLifecycleGeneration: number,
): Promise<void> {
  // A root retains its startup epoch through every pre-candidate await. This is
  // stronger than `ext.disposed`, which a same-module session_start intentionally
  // clears while an outgoing continuation may still be pending.
  if (!_isCurrentRootLifecycle(rootLifecycleGeneration)) return;

  const cwd = "cwd" in ctx ? (ctx as ExtensionCommandContext).cwd : process.cwd();
  // Lock identity is (cwd, name). Several agents may run in the SAME folder; the
  // requested name just has to be made unique. Derive the name the same way
  // `_cmdJoin` does so the lock and the mesh registration agree on identity.
  const requestedName = loadLocalConfig(cwd).agent_name || defaultAgentName(cwd);

  // Per-(cwd,name) lock. Interactive agents may coexist by auto-suffixing
  // (`name#2`, `name#3`, …), but supervised daemons must be singletons for their
  // registered cwd/name. If a daemon silently came up as `#2`, the supervisor
  // would report "running" while the mesh had duplicate peers for one repo.
  if (ext.cwdLock === null) {
    const isDaemon = process.env["REMOTE_PI_DAEMON"] === "1";
    const maxAttempts = isDaemon ? 1 : 1000;
    for (let n = 1; n <= maxAttempts; n++) {
      const candidate = n === 1 ? requestedName : `${requestedName}#${n}`;
      const result = await acquireCwdLock(cwd, candidate);
      if (!_isCurrentRootLifecycle(rootLifecycleGeneration)) {
        if (result.ok) {
          try { result.release(); } catch { /* best-effort stale lock cleanup */ }
        }
        return;
      }
      if (result.ok) { ext.cwdLock = result; ext.lockedName = candidate; break; }
    }
    if (ext.cwdLock === null) {
      if (!_isCurrentRootLifecycle(rootLifecycleGeneration)) return;
      ctx.ui.notify(
        process.env["REMOTE_PI_DAEMON"] === "1"
          ? `[remote-pi] Daemon not started: another live agent already owns "${requestedName}" in this folder. Stop the old Pi process, then restart the daemon.`
          : `[remote-pi] Could not start: too many agents named "${requestedName}" already running in this folder.`,
        "warning",
      );
      return;
    }
  }

  // First-time wizard: no local config in this cwd → run interactive setup.
  if (!localConfigExists(cwd)) {
    const ui = ctx.ui as unknown as WizardUI;
    if (typeof ui.select !== "function") {
      _cmdStatus(ctx);
      return;
    }
    const baseDefault = defaultAgentName(cwd);
    const newConfig = await runSetupWizard(ui, {
      agent_name: baseDefault,
      use_relay: true,
    });
    if (!_isCurrentRootLifecycle(rootLifecycleGeneration)) return;
    if (!newConfig) {
      ctx.ui.notify("[remote-pi] Setup cancelled.", "info");
      return;
    }
    saveLocalConfig(cwd, newConfig);
    ctx.ui.notify(
      `[remote-pi] Config saved to ${cwd}/.pi/remote-pi/config.json`,
      "info",
    );
    if (!_isCurrentRootLifecycle(rootLifecycleGeneration)) return;
    await _cmdJoin(ctx);
    if (!_isCurrentRootLifecycle(rootLifecycleGeneration) || !ext.meshNode) return;
    if (effectiveAutoStartRelay(newConfig)) await _cmdStart(ctx);
    if (!_isCurrentRootLifecycle(rootLifecycleGeneration) || !ext.meshNode) return;
    _cmdStatus(ctx);
    return;
  }

  // Returning user with config: ALWAYS join the local UDS mesh on connect; the
  // relay is the only thing gated by auto_start_relay. So auto_start_relay:false
  // now means "local mesh, no relay" (matching the first-time/wizard path and
  // the field's documented intent) — previously a false flag skipped the mesh
  // join entirely, leaving the agent (incl. daemons) fully idle.
  const config = loadLocalConfig(cwd);
  if (!_isCurrentRootLifecycle(rootLifecycleGeneration)) return;
  if (!ext.meshNode) await _cmdJoin(ctx);
  // `_cmdJoin` returns void on a canceled/failed join, so recheck both the
  // root lifecycle and publication before bringing the Relay up.
  if (!_isCurrentRootLifecycle(rootLifecycleGeneration) || !ext.meshNode) return;
  if (effectiveAutoStartRelay(config) && ext.state === "idle") await _cmdStart(ctx);
  if (!_isCurrentRootLifecycle(rootLifecycleGeneration) || !ext.meshNode) return;
  _cmdStatus(ctx);
}

/**
 * `/remote-pi setup` — re-run the wizard. Defaults pre-fill from the
 * existing config so it doubles as an "edit" flow.
 */
async function _cmdSetup(ctx: Pick<ExtensionContext, "ui" | "cwd">): Promise<void> {
  const cwd = "cwd" in ctx ? (ctx as ExtensionCommandContext).cwd : process.cwd();
  const ui = ctx.ui as unknown as WizardUI;
  if (typeof ui.select !== "function") {
    ctx.ui.notify("[remote-pi] Setup requires an interactive UI.", "warning");
    return;
  }
  const current = loadLocalConfig(cwd);
  const baseDefault = defaultAgentName(cwd);
  const newConfig = await runSetupWizard(ui, {
    agent_name: current.agent_name ?? baseDefault,
    use_relay: effectiveAutoStartRelay(current),
  });
  if (!newConfig) {
    ctx.ui.notify("[remote-pi] Setup cancelled.", "info");
    return;
  }
  saveLocalConfig(cwd, newConfig);
  ctx.ui.notify(
    "[remote-pi] Config updated. Run /remote-pi to apply now.",
    "info",
  );
}

async function _cmdStart(ctx: Pick<ExtensionContext, "ui" | "cwd">): Promise<void> {
  if (ext.state !== "idle") {
    ctx.ui.notify("[remote-pi] Already started.", "warning");
    return;
  }
  const lifecycleGeneration = ++ext.relayLifecycleGeneration;
  const isCurrentCandidate = (): boolean => (
    !ext.disposed &&
    lifecycleGeneration === ext.relayLifecycleGeneration &&
    ext.state === "idle" &&
    ext.relay === null
  );

  let edKp: Awaited<ReturnType<typeof getOrCreateEd25519Keypair>>;
  try {
    edKp = await getOrCreateEd25519Keypair();
  } catch (err) {
    // Identity lookup is part of the candidate lifecycle. A later stop/off or
    // session replacement must silence its stale rejection before any UI or
    // error propagation touches the superseded context.
    if (!isCurrentCandidate()) return;
    if (err instanceof KeyringUnavailableError) {
      // The platform keyring (macOS Keychain / Windows Credential Manager) is
      // locked/denied and there's no file identity to fall back to. We refuse
      // to mint a new key (that's what silently broke pairing after idle), so
      // abort cleanly with an actionable message instead of crashing or
      // re-pairing. Unlocking the keychain and re-running fixes it.
      ctx.ui.notify(
        "[remote-pi] Could not read this machine's identity: the system " +
        "keychain is locked or access was denied. Unlock it (open the app / " +
        "log in) and run /remote-pi again. Your pairing is NOT lost. " +
        "(Set REMOTE_PI_ALLOW_FILE_IDENTITY=1 only for headless hosts.)",
        "error",
      );
      return;
    }
    throw err;
  }
  // Re-check immediately after the first await, before cache/config/model/UI
  // mutation or Relay construction. `ext.disposed` alone is insufficient because
  // same-module session_start intentionally clears it for the replacement.
  if (!isCurrentCandidate()) return;
  ext.cachedEd25519 = edKp;

  const { url: relayUrl, source } = resolveRelayUrl();
  const myShort = Buffer.from(edKp.publicKey).toString("base64").slice(0, 8);

  const cwd = "cwd" in ctx ? (ctx as ExtensionCommandContext).cwd : process.cwd();
  // Same name we send in pair_ok — keeps room_meta.name and the per-pair
  // session_name aligned so the app shows consistent labels.
  const sessionName = _displayName(cwd);
  // plan/41: derive the App↔Pi room from (cwd, name) so several agents in the
  // SAME folder get distinct rooms (the app renders one tile per agent). The
  // default/unnamed case preserves the legacy cwd-only id (no re-keying). Uses
  // the SAME name as room_meta.name / pair_ok below — the invariant that the
  // app pairs on the room the Pi actually announces.
  //
  // Plan/120 — a config `room_id` override wins over the cwd-derived id. The
  // supervisor's device daemon sets this to DEVICE_ROOM so it connects in a
  // fixed room independent of its (temp/home) cwd, letting the phone route
  // offline terminal-open requests to it.
  const localCfg = loadLocalConfig(cwd);
  const roomId = localCfg.room_id ?? roomIdFor(cwd, sessionName);

  // Seed the current model from the SDK's resolved selection so room_meta
  // carries it on connect. `model_select` only fires on an explicit set/cycle
  // (NOT on settings load), so a headless daemon that just runs its default
  // model never emits it — without this its room_meta would omit the model and
  // the app shows "unknown". `getModel()` returns the session's resolved model
  // in every mode (interactive + RPC daemon); turn_start hydrates it later if
  // the SDK resolves the model lazily.
  if (!ext.currentModel) {
    try {
      const c = ctx as Partial<ExtensionContext> & {
        model?: { name?: string; id?: string };
        getModel?: () => { name?: string; id?: string } | undefined;
      };
      // Prefer the live getModel() / ctx.model — populated for an interactive
      // Pi. For a HEADLESS DAEMON both are undefined at connect: the SDK only
      // resolves `this.model` lazily at the first turn, and `model_select`
      // never fires for a default-model session. So fall back to the CONFIGURED
      // default (defaultProvider/defaultModel in <cwd>/.pi/settings.json) — the
      // model the daemon will actually use. Without this an idle daemon (never
      // prompted → no turn) would never report its model and the app shows
      // "unknown". turn_start still hydrates a later override.
      const live = c.getModel?.() ?? c.model;
      if (live) {
        ext.currentModel = live.name ?? live.id ?? undefined;
      } else {
        const sm = SettingsManager.create(cwd);
        const provider = sm.getDefaultProvider();
        const modelId = sm.getDefaultModel();
        if (modelId) {
          ext.currentModel = modelId;
          const seeded = modelId;
          // pi 0.83 made the registry build async (`ModelRuntime.create()`).
          // Upgrade the seed to the model's friendly name best-effort, WITHOUT
          // blocking session start — the raw id is already set above as a safe
          // immediate default. Only an idle daemon (never prompted → no
          // model_select / turn_start) benefits; those hydrate this later too.
          if (provider) {
            void ensureModelRegistry()
              .then((reg) => reg.find(provider, modelId))
              .then((found) => {
                // Only upgrade while the seed is still current — a user model
                // switch (or model_select/turn_start) since startup must win.
                if (found?.name && ext.currentModel === seeded) ext.currentModel = found.name;
              })
              .catch(() => { /* best-effort — never block start */ });
          }
        }
      }
    } catch { /* defensive — never block start on a model lookup */ }
  }

  // Plan/28 Wave D.1: seed thinking from the SDK's current level so the
  // first room_meta hello already carries it. `pi.getThinkingLevel()` is
  // safe at this point — extension factory has been bound by the SDK
  // before any command handler fires. Future toggles go through the
  // `thinking_level_select` event handler above.
  try {
    ext.currentThinking = ext.pi?.getThinkingLevel() as ThinkingLevel | undefined;
  } catch { /* defensive — never block /remote-pi start on this */ }

  const roomMeta: { name: string; cwd: string; model?: string; thinking?: ThinkingLevel; git?: WireGitStatus | null; context_usage?: WireContextUsage | null } = { name: sessionName, cwd };
  const modelName = _currentModelName();
  if (modelName) roomMeta.model = modelName;
  if (ext.currentThinking) roomMeta.thinking = ext.currentThinking;
  // Plan/107b — seed the git snapshot into the hello so room_announced
  // already carries it (apps render the Home-list git line immediately).
  roomMeta.git = await getGitStatus(cwd);
  ext.lastGitStatus = roomMeta.git ?? null;
  // Seed context-window usage so the chat header shows it on connect.
  const helloUsage = ext.lastEventCtx?.getContextUsage?.();
  if (helloUsage) roomMeta.context_usage = helloUsage;
  // Persist so _attemptReconnect can replay the same hello payload — without
  // this, reconnect issues a bare hello and the relay creates a "default room"
  // entry that surfaces in the app as a phantom legacy session.
  ext.myRoomMeta = roomMeta;

  ctx.ui.notify(`[remote-pi] Connecting to relay ${relayUrl} (source: ${source}, room: ${roomId})…`, "info");

  // Transport opens WebSocket; convert the canonical http(s):// stored
  // form to ws(s):// at this boundary. The relayUrl variable keeps the
  // http(s):// form for logging + mesh client construction below.
  const relay = new RelayClient(toWebSocketUrl(relayUrl), edKp);
  try {
    await relay.connect({ roomId, roomMeta });
  } catch (err) {
    // A rejected local candidate is never published and must always be closed,
    // regardless of whether this lifecycle is still authoritative.
    try { relay.close(); } catch { /* best-effort rejected candidate cleanup */ }
    // A stop, shutdown/replacement, relay-off, or newer start may supersede a
    // candidate before its rejection arrives. Keep the outgoing context silent;
    // only the authoritative attempt may report an error.
    if (!isCurrentCandidate()) return;
    if (err instanceof RoomAlreadyOpenError) {
      ctx.ui.notify(
        "[remote-pi] Already running in this cwd. Stop the other terminal first.",
        "error",
      );
      return;
    }
    ctx.ui.notify(`[remote-pi] relay connect failed: ${String(err)}`, "error");
    return;
  }

  // The candidate is local until this publication point. Session shutdown,
  // stop/relay-off, or a newer start may have invalidated it while connect()
  // was pending; never let that stale continuation resurrect the Relay.
  if (!isCurrentCandidate()) {
    try { relay.close(); } catch { /* best-effort stale candidate cleanup */ }
    return;
  }

  ext.relay = relay;
  ext.relayUrl = relayUrl;
  ext.peerShort = myShort;
  ext.myRoomId = roomId;
  ext.state = "started";
  // Set ext.sessionStartedAt ONLY on first /remote-pi start since process boot.
  // Subsequent start cycles (after stop) preserve the original epoch so the
  // app keeps treating it as the same session (and merges new events from
  // the terminal turns that happened during the idle window). Pi process
  // restart is the only thing that produces a fresh session_started_at.
  if (ext.sessionStartedAt === null) ext.sessionStartedAt = Date.now();
  // ext.messageBuffer intentionally preserved across stop/start — it accumulates
  // message_end events for the lifetime of the Pi process, including turns
  // initiated from the terminal while the relay was disconnected.

  relay.on("close", () => _onRelayClose(relay));

  ext.stopAutoListener = _installAutoListener(relay);
  startGitRefresh(); // Plan/107b — begin room_meta.git polling
  _refreshFooter(ctx);

  // SelfRevoke is the Pi path's single initial topology producer. Its first
  // coalesced sweep always publishes verified membership or a safe fallback
  // before the bridge may attach.
  let createdProducer = false;
  if (ext.selfRevoke === null) {
    createdProducer = true;
    const producerEpoch = ++ext.selfRevokeEpoch;
    ext.selfRevokeTopologyReadyEpoch = -1;
    ext.selfRevokeTopology = null;
    let producer!: SelfRevoke;
    producer = new SelfRevoke({
      client: new MeshClient(relayUrl),
      storage: { snapshotOwnerPubkeys, conditionalRemovePeer },
      myPubkey: edKp.publicKey,
      onRevoke: (rawOwnerPubkey, canonicalOwnerPubkey) => {
        if (
          ext.selfRevoke !== producer ||
          producerEpoch !== ext.selfRevokeEpoch
        ) {
          return;
        }
        _revokeActiveOwnerRuntime(canonicalOwnerPubkey);
        void rawOwnerPubkey; // exact storage removal already happened upstream
      },
      onAuthoritativeOwners: (canonicalOwnerPubkeys) => {
        if (
          ext.selfRevoke !== producer ||
          producerEpoch !== ext.selfRevokeEpoch
        ) {
          return;
        }
        const presentOwners = new Set(canonicalOwnerPubkeys);
        let effectFailed = false;
        for (const canonicalOwnerPubkey of [...ext.activePeers.keys()]) {
          if (
            ext.selfRevoke !== producer ||
            producerEpoch !== ext.selfRevokeEpoch
          ) {
            return;
          }
          if (presentOwners.has(canonicalOwnerPubkey)) continue;
          try {
            _revokeActiveOwnerRuntime(canonicalOwnerPubkey);
          } catch {
            effectFailed = true;
          }
        }
        if (effectFailed) throw new Error("Owner runtime reconciliation failed");
      },
      onTopologyChanged: (snapshot) => {
        if (
          ext.selfRevoke !== producer ||
          producerEpoch !== ext.selfRevokeEpoch
        ) {
          return;
        }
        ext.selfRevokeTopology = snapshot;
        ext.meshNode?.setTopology(snapshot);
        ext.selfRevokeTopologyReadyEpoch = producerEpoch;
        _attachBridgeIfReady();
      },
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });
    ext.selfRevoke = producer;
    producer.start();
    await producer.checkOnce();
    if (
      ext.disposed ||
      ext.selfRevoke !== producer ||
      producerEpoch !== ext.selfRevokeEpoch ||
      ext.relay !== relay
    ) {
      return;
    }
  }

  // Relay reconnect reuses the current producer's retained snapshot. Initial
  // startup is callback-driven above, so it must not issue a second attach.
  if (!createdProducer) _attachBridgeIfReady();

  _emitRelayState();  // → connected
  ctx.ui.notify(`[remote-pi] state: started (peer=${myShort}) — Connected to relay ${relayUrl}`, "info");
}

/**
 * `/remote-pi pair` — always generates a fresh QR when the relay is up.
 *
 * Pre-W2D this rejected with "Already paired with X" once one owner was
 * connected, forcing /remote-pi stop to pair a second device — the
 * catch-22 the multi-channel refactor was designed to break. Now the new
 * device is **added** to `ext.activePeers` after scanning, while existing
 * owners keep their session.
 */
async function _cmdPair(ctx: Pick<ExtensionContext, "ui" | "cwd">, args = ""): Promise<void> {
  const cwd = "cwd" in ctx ? (ctx as ExtensionCommandContext).cwd : "";

  // Auto-bootstrap when services are down. Before this, `/remote-pi pair`
  // on a fresh terminal forced the user to call `/remote-pi` first — every
  // session began with the same surprise warning + second command. Now we
  // do the join + relay-start inline so the common "I just opened a
  // terminal and want to pair my phone" flow is a single command.
  //
  // We don't run the first-time wizard here: pair is a focused operation
  // and the wizard prompts are wrong UX in that flow. If there's no local
  // config, the user truly needs to run `/remote-pi` first to configure.
  if (ext.state === "idle") {
    if (!localConfigExists(cwd)) {
      ctx.ui.notify(
        "[remote-pi] First-time setup needed. Run /remote-pi to configure, then /remote-pi pair.",
        "warning",
      );
      return;
    }
    ctx.ui.notify("[remote-pi] Starting mesh + relay before pairing…", "info");
    if (!ext.meshNode) await _cmdJoin(ctx);
    if (ext.state === "idle") await _cmdStart(ctx);
  }

  // Relay must be up — the QR carries a token the app exchanges through
  // the relay. Without a live WS there's nothing for the scan to land on.
  if (ext.state === "idle" || !ext.relay) {
    ctx.ui.notify(
      "[remote-pi] Pair requires the relay to be connected. " +
      "Run /remote-pi to start it (or fix your relay URL via /remote-pi set-relay).",
      "warning",
    );
    return;
  }

  const edKp = ext.cachedEd25519!;
  // Embed the user-configured name in the QR so the app shows it on the
  // pairing screen before pair_ok lands (better UX than "remote" or a
  // raw path snippet).
  const sessionName = _displayName(cwd);

  // Optional `--ttl <seconds>` — RPC clients (e.g. Cockpit) pass a caller-
  // defined expiry. Defaults to TOKEN_TTL_MS, clamped to the safe window.
  const ttlMatch = /--ttl\s+(\d+)/.exec(args);
  const ttlMs = ttlMatch ? clampPairTtlMs(Number(ttlMatch[1]) * 1000) : TOKEN_TTL_MS;
  const { token, expiresAt } = qrSession.issueToken(ttlMs);
  const roomId = ext.myRoomId ?? roomIdFor(cwd, sessionName);
  // plan/102 — advertise the relay in the QR so the phone can adopt it. By
  // default that is the relay URL with loopback rewritten to this machine's
  // LAN address, since the phone cannot dial loopback. `REMOTE_PI_ADVERTISE` /
  // `set-advertise` override it, which is how an overlay address (Tailscale)
  // gets into the QR without moving this process off loopback. A null means
  // there is no honest address to advertise: emit the QR without `r` and let
  // the app fall back to its own relay setting.
  const advertisedRelay =
    resolveAdvertisedRelayUrl((url) => toPhoneReachableUrl(url)) ?? undefined;
  const qrUri = buildQRUri(token, edKp.publicKey, sessionName, roomId, advertisedRelay);
  // Render both the QR ASCII and the copy-paste URI inside the Pi TUI's
  // chat panel via `pi.sendMessage` — the same channel the SDK uses for
  // agent responses + tool results. `process.stderr.write` (the old QR
  // path via `displayQR`) broke the TUI layout because it bypassed the
  // chat widget and bled into the prompt area. qrcode-terminal v0.12
  // small mode is pure Unicode (█ ▀ ▄ space, no ANSI escapes — see
  // `lib/main.js:48-53`), so embedding the ASCII inside a sendMessage
  // content string renders correctly without raw escape bytes.
  if (ext.pi) {
    const qrAscii = renderQRAscii(qrUri);
    ext.pi.sendMessage({
      customType: "remote-pi:pair-code",
      content:
        `📱 Scan to pair:\n\n${qrAscii}\n` +
        `📋 Or copy this pairing code (camera-less devices):\n\n${qrUri}`,
      // Structured payload for RPC clients (e.g. Cockpit): render their own QR
      // from `uri` + show the expiry, without scraping the display string.
      details: { uri: qrUri, token, expiresAt, roomId, name: sessionName },
      display: true,
    });
  }

  ctx.ui.notify(
    `[remote-pi] QR ready — valid until ${new Date(expiresAt).toLocaleTimeString()}. ` +
    `Scan with the app, or copy the pairing code printed above.`,
    "info",
  );
  // Returns immediately; the auto-listener transitions to 'paired' on pair_request.
}

/**
 * `/remote-pi stop` — full teardown. Leaves the local UDS mesh AND closes
 * the relay. Safe when one or both are already off. To resume, run
 * `/remote-pi` again.
 */
async function _cmdStop(ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  // Invalidate queued root work and local async candidates even when none has
  // published yet.
  ext.rootLifecycleGeneration += 1;
  ext.meshJoinGeneration += 1;
  const meshUp = ext.meshNode !== null;
  const relayUp = ext.state !== "idle";
  if (!meshUp && !relayUp) {
    ext.relayLifecycleGeneration += 1;
    ctx.ui.notify("[remote-pi] Already stopped — nothing to do.", "info");
    return;
  }

  // Preserve bye ordering, but revoke Relay/SelfRevoke/bridge authority while
  // the global node is still visible and before close() begins UDS leave.
  if (relayUp) {
    _goIdle("peer_stop");
  } else {
    ext.relayLifecycleGeneration += 1;
    ext.meshNode?.detachBridge();
  }

  const meshNode = ext.meshNode;
  ext.meshNode = null;
  ext.sessionName = null;
  ext.sessionPeerCount = 0;
  let meshClose: Promise<void> | null = null;
  try { meshClose = meshNode?.close() ?? null; } catch { /* best-effort */ }
  try { await meshClose; } catch { /* best-effort */ }

  ctx.ui.notify("[remote-pi] Stopped (mesh + relay disconnected).", "info");
  _refreshFooter(ctx);
}

async function _cmdList(ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  const peers = await listPeers();
  if (peers.length === 0) { ctx.ui.notify("[remote-pi] No paired devices.", "info"); return; }
  // Multi-channel (W2D): each peer is either `online` (channel attached
  // right now) or `offline` (in peers.json but not connected). Replaces
  // the singleton " (active)" marker that only ever marked one peer.
  const lines = peers.flatMap((record) => {
    const inspected = _inspectPeerRecord(record);
    if (!inspected) return [];
    const tag = inspected.runtimeKey !== null && ext.activePeers.has(inspected.runtimeKey)
      ? " 🟢 online"
      : " ⚪ offline";
    return `• ${inspected.rawHandle.slice(0, 8)} — ${inspected.record.name}${tag}`;
  }).join("\n");
  ctx.ui.notify(`[remote-pi] Paired devices:\n${lines}`, "info");
}

async function _cmdRevoke(arg: string, ctx: Pick<ExtensionContext, "ui" | "cwd">): Promise<void> {
  const shortid = arg.trim();
  if (!shortid) {
    ctx.ui.notify(
      "[remote-pi] Usage: /remote-pi revoke <shortid>. Run /remote-pi list to see shortids.",
      "warning",
    );
    return;
  }

  // Revoke needs the relay so the revoked device gets a `bye` and its live
  // channel is torn down — not just a silent peers.json edit. Auto-bootstrap
  // the mesh + relay when down, mirroring `_cmdPair`.
  const cwd = "cwd" in ctx ? (ctx as ExtensionCommandContext).cwd : "";
  if (ext.state === "idle") {
    if (!localConfigExists(cwd)) {
      ctx.ui.notify(
        "[remote-pi] First-time setup needed. Run /remote-pi to configure, then /remote-pi revoke.",
        "warning",
      );
      return;
    }
    ctx.ui.notify("[remote-pi] Starting mesh + relay before revoking…", "info");
    if (!ext.meshNode) await _cmdJoin(ctx);
    if (ext.state === "idle") await _cmdStart(ctx);
  }
  if (ext.state === "idle" || !ext.relay) {
    ctx.ui.notify(
      "[remote-pi] Revoke requires the relay to be connected. " +
      "Run /remote-pi to start it (or fix your relay URL via /remote-pi set-relay).",
      "warning",
    );
    return;
  }

  const matches = (await listPeers())
    .map(_inspectPeerRecord)
    .filter((peer): peer is InspectedPeerRecord => peer !== null)
    .filter((peer) => peer.rawHandle.startsWith(shortid));

  if (matches.length === 0) {
    ctx.ui.notify(
      "[remote-pi] No peer matching that shortid. Run /remote-pi devices to see shortids.",
      "warning",
    );
    return;
  }

  if (matches.length > 1) {
    const collisions = matches.map((peer) => peer.rawHandle.slice(0, 8)).join(", ");
    ctx.ui.notify(
      `[remote-pi] Ambiguous shortid — ${matches.length} matches: ${collisions}. Use mais chars.`,
      "warning",
    );
    return;
  }

  const peer = matches[0]!;
  await removePeer(peer.rawHandle);
  _refreshPairingsCache();

  // Storage removal uses the exact saved representation; the active channel
  // is indexed by its canonical identity.
  if (peer.runtimeKey !== null && ext.activePeers.has(peer.runtimeKey)) {
    const channel = ext.activePeers.get(peer.runtimeKey);
    try { channel?.send({ type: "bye", reason: "session_replaced" }); } catch { /* best-effort */ }
    _detachPeerChannel(peer.runtimeKey);
    _refreshFooter();
  }

  ctx.ui.notify(
    `[remote-pi] Revoked: ${peer.record.name} (${peer.rawHandle.slice(0, 8)}…)`,
    "info",
  );
}

async function _shortidCompletions(
  prefix: string,
  valuePrefix = "",
): Promise<Array<{ value: string; label: string }>> {
  const peers = (await listPeers())
    .map(_inspectPeerRecord)
    .filter((peer): peer is InspectedPeerRecord => peer !== null);
  return peers
    .map((peer) => ({
      shortid: peer.rawHandle.slice(0, 8),
      name: peer.record.name,
    }))
    .filter((entry) => entry.shortid.startsWith(prefix))
    .map((entry) => ({
      value: `${valuePrefix}${entry.shortid}`,
      label: `${entry.shortid} (${entry.name})`,
    }));
}

function _cmdSetRelay(arg: string, ctx: Pick<ExtensionContext, "ui">): void {
  const raw = arg.trim();
  if (!raw) {
    ctx.ui.notify(
      "[remote-pi] Usage: /remote-pi set-relay <http:// or https:// url>",
      "warning",
    );
    return;
  }
  if (isWebSocketScheme(raw)) {
    ctx.ui.notify(
      `[remote-pi] Use http:// or https://. The extension converts to WebSocket automatically.`,
      "error",
    );
    return;
  }
  if (!isValidRelayUrl(raw)) {
    ctx.ui.notify(
      `[remote-pi] Invalid URL: ${raw}. Must start with http:// or https://`,
      "error",
    );
    return;
  }
  saveConfig({ relay: raw });
  ctx.ui.notify(
    `[remote-pi] Relay set to ${raw}. Run /remote-pi start (or restart) to apply.`,
    "info",
  );
}

/**
 * `/remote-pi set-advertise <url>` — the address the pairing QR carries.
 *
 * Separate from `set-relay` on purpose: this one changes what the *phone*
 * dials, leaving this process on whatever route it already uses. That is what
 * makes an overlay address (Tailscale, WireGuard) reachable from outside the
 * WLAN without taking the local loopback connection hostage to the VPN daemon.
 *
 * An empty argument clears it, restoring the plan/102 default of advertising
 * this machine's LAN address.
 */
function _cmdSetAdvertise(arg: string, ctx: Pick<ExtensionContext, "ui">): void {
  const raw = arg.trim();
  if (!raw) {
    saveConfig({ advertise: undefined });
    ctx.ui.notify(
      "[remote-pi] Advertised address cleared — the pairing QR falls back to " +
      "this machine's LAN address. To set one: /remote-pi set-advertise <url>",
      "info",
    );
    return;
  }
  if (isWebSocketScheme(raw)) {
    ctx.ui.notify(
      `[remote-pi] Use http:// or https://. The extension converts to WebSocket automatically.`,
      "error",
    );
    return;
  }
  if (!isValidRelayUrl(raw)) {
    ctx.ui.notify(
      `[remote-pi] Invalid URL: ${raw}. Must start with http:// or https://`,
      "error",
    );
    return;
  }
  saveConfig({ advertise: raw });
  ctx.ui.notify(
    `[remote-pi] Pairing QR will advertise ${raw}. Takes effect on the next ` +
    `/remote-pi pair — already-paired devices keep their current address.`,
    "info",
  );
}

// ── Daemon registry commands (plan/26 Wave 1) ─────────────────────────────────

/**
 * `/remote-pi create [<cwd>] [--name <name>]`
 *
 * Promotes a folder to a daemon entry in `~/.pi/piper/daemons.json`. The
 * cwd is **always normalized to an absolute realpath** before storage —
 * `~/Movies`, `./Movies`, `../foo/Movies` all collapse to a single
 * canonical entry. Relative paths resolve against the Pi process's
 * current working directory, not the slash-command's `ctx.cwd`.
 *
 * Side effects on the cwd's local config (`<cwd>/.pi/remote-pi/config.json`):
 *   - If the config doesn't exist: created with `auto_start_relay=true`
 *     (mandatory for daemons) and `agent_name` from `--name` if provided.
 *   - If the config already exists: left untouched. Re-running `create`
 *     on an existing daemon is idempotent at this layer; the registry
 *     itself rejects duplicate cwds.
 */

function _resolveExtensionDir(): string {
  // dist/index.js → dist; skills sit at <extensionRoot>/skills/. When we run
  // from src/ via tsx (dev), index.ts is in src/ and skills/ is sibling. We
  // detect by checking both locations.
  const here = fileURLToPath(import.meta.url);
  // dist/index.js or src/index.ts → parent = <dist or src>; sibling = ../skills
  const parent = here.replace(/\/[^/]+$/, "");
  const candidateA = join(parent, "..", "skills"); // dist → ../skills
  const candidateB = join(parent, "skills");        // src → skills
  if (existsSync(candidateA)) return parent.replace(/\/dist$/, "");
  if (existsSync(candidateB)) return parent;
  return parent;
}

function _deployAgentNetworkSkill(): void {
  // Pi SDK spec (core/skills.js): every skill must live at
  //   <skillsRoot>/<skill-name>/SKILL.md
  // The skill `name:` frontmatter must equal the parent directory name. We
  // ship the source pre-arranged that way so deploy is a straight copy into
  // ~/.pi/piper/skills/agent-network/SKILL.md.
  const root = _resolveExtensionDir();
  const src1 = join(root, "skills", "agent-network", "SKILL.md");
  const src2 = join(root, "..", "skills", "agent-network", "SKILL.md");
  const src = existsSync(src1) ? src1 : (existsSync(src2) ? src2 : null);
  if (!src) return;
  const dstDir = join(skillsDir(), "agent-network");
  const dst = join(dstDir, "SKILL.md");
  try {
    mkdirSync(dstDir, { recursive: true });
    copyFileSync(src, dst);
    // Cleanup legacy deploy at ~/.pi/piper/skills/agent-network.md (flat
    // layout, fails the Pi SDK's name-vs-parent-dir validation).
    const legacy = join(skillsDir(), "agent-network.md");
    if (existsSync(legacy)) {
      try { unlinkSync(legacy); } catch { /* ignored */ }
    }
  } catch { /* best-effort */ }
}

/**
 * Inject text into the agent as a user message, waking a turn. The Pi SDK's
 * `ExtensionAPI.sendUserMessage` is fire-and-forget (returns `void`) and
 * "always triggers a turn" — the SDK runtime owns any *async* turn failure
 * (no model/API key, expired auth, provider error), which surfaces in the
 * agent's own output, not back to us. Two gaps this helper closes, both of
 * which previously failed silently:
 *
 *   1. `ext.pi` not bound yet (activation race / mesh joined before the session
 *      attached): the old code did `if (!ext.pi) return`, dropping the message
 *      with no trace. We log it (the daemon forwards child stderr to its log
 *      with a cwd prefix, so it's visible in `journalctl`).
 *   2. A *synchronous* throw from `sendUserMessage` (e.g. malformed content):
 *      the old fire-and-forget call let it propagate out of the `onMessage`
 *      callback, which could wedge the read loop and blackout every later
 *      message. We catch + surface it instead.
 *
 * NOTE: this does NOT make a wake that fails *inside* the SDK observable —
 * that requires a fix in the Pi runtime (no extension-level error event
 * exists for it). See `.orchestration/results/mesh-liveness-stale-peer.md`.
 */
type SendUserMessageOptions =
  NonNullable<Parameters<ExtensionAPI["sendUserMessage"]>[1]>;

type WakeAgentResult =
  | { ok: true }
  | { ok: false; detail: string };

function _wakeAgent(
  content: Parameters<ExtensionAPI["sendUserMessage"]>[0],
  label: string,
  steeringBehavior?: SendUserMessageOptions["deliverAs"],
): WakeAgentResult {
  if (!ext.pi) {
    const detail = "agent session not bound yet";
    console.error(`[remote-pi] ${label}: ${detail} — message dropped`);
    return { ok: false, detail };
  }
  try {
    const options = steeringBehavior
      ? ({ deliverAs: steeringBehavior })
      : undefined;
    ext.pi.sendUserMessage(content, options);
    return { ok: true };
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    console.error(`[remote-pi] ${label}: agent rejected incoming message: ${detail}`);
    _safeNotify(`[remote-pi] failed to process incoming message: ${detail}`, "error");
    return { ok: false, detail };
  }
}

/**
 * Plan/109 — revert a one-shot model override after the turn ends. Restores
 * the live model to the original (captured before the switch) and unfreezes
 * the display so later model changes broadcast normally. No-op when no
 * override is pending (the common case — called on every turn_end).
 */
async function _revertModelOverride(): Promise<void> {
  if (ext.pendingModelRevert === null) return;
  const orig = ext.pendingModelRevert;
  ext.pendingModelRevert = null;
  if (!ext.pi) return;
  try {
    await ext.pi.setModel(orig);
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    console.error(`[remote-pi] model override revert failed: ${detail}`);
  }
}

/**
 * Plan/109 — send a user_message with a ONE-SHOT model override. Switches the
 * live session model to `msg.model`, freezes the displayed model (no flicker),
 * injects the message (starting a new turn), and remembers the original to
 * revert on turn_end. The on-disk default is never changed. Errors are
 * replied to the sender (model not in registry / no auth / agent rejected).
 */
async function _sendWithModelOverride(
  sender: PlainPeerChannel,
  msg: ClientUserMessage,
): Promise<void> {
  const override = msg.model;
  if (!override || !ext.pi) return;
  const ctx = (ext.lastEventCtx ?? ext.lastCtx) as ActionCtx | null;
  let reg: ActionModelRegistry;
  try {
    // The caller invokes this fire-and-forget (`void _sendWithModelOverride`),
    // so an unawaited `ensureModelRegistry()` rejection would surface as an
    // unhandled rejection with no reply to the client. Catch it here instead.
    reg = ctx?.modelRegistry ?? (await ensureModelRegistry());
  } catch (err) {
    sender.send({
      type: "error",
      code: "internal_error",
      in_reply_to: msg.id,
      message: err instanceof Error ? err.message : String(err),
    });
    return;
  }
  // pi 0.83 made `refresh()` async; keep best-effort (a stale catalogue is
  // still usable) by swallowing its rejection rather than failing the send.
  try { await reg.refresh(); } catch { /* malformed models.json — best effort */ }
  const chosen = reg.find(override.provider, override.id);
  if (!chosen) {
    sender.send({
      type: "error",
      code: "internal_error",
      in_reply_to: msg.id,
      message: `override model "${override.provider}/${override.id}" not in registry`,
    });
    return;
  }
  const orig = ctx?.getModel?.();
  let ok: boolean;
  try {
    ok = await ext.pi.setModel(chosen as FullSdkModel);
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    sender.send({ type: "error", code: "internal_error", in_reply_to: msg.id, message: `setModel failed: ${detail}` });
    return;
  }
  if (!ok) {
    sender.send({ type: "error", code: "no_auth", in_reply_to: msg.id, message: `no auth configured for ${override.provider}/${override.id}` });
    return;
  }
  // Explicitly broadcast the temp model so the app header shows it for the
  // turn. Some pi versions don't emit `model_select` for a PROGRAMMATIC
  // setModel (the normal picker works because its setModel is a user action
  // that does fire the event), so call _setCurrentModel directly rather than
  // rely on the event. plan/109. (If model_select DOES fire, it's idempotent.)
  _setCurrentModel(chosen.name);
  // Remember the original to restore at turn_end (only the first override in
  // a turn sets the target — later overrides share the same revert).
  if (ext.pendingModelRevert === null && orig) ext.pendingModelRevert = orig as FullSdkModel;
  // Inject the message, starting a new turn (this path is only reached when
  // !shouldSteer — overrides during a running turn are ignored upstream).
  const previousTurnId = ext.currentTurnId;
  ext.currentTurnId = msg.id;
  const wake = _wakeAgent(
    msg.text,
    `app user_message id=${msg.id} (override ${override.provider}/${override.id})`,
    "steer",
  );
  if (!wake.ok) {
    ext.currentTurnId = previousTurnId;
    await _revertModelOverride();
    sender.send({ type: "error", code: "internal_error", in_reply_to: msg.id, message: `Agent rejected incoming message: ${wake.detail}` });
    return;
  }
  _echoUserMessage(msg, false);
}

/**
 * Deliver an inbound agent-network (mesh) message to the agent + the app.
 *
 * Display: the app renders it in the TOOL timeline (a matched
 * tool_request/tool_result "agent-network" pair) — NOT as the user's own
 * message, which is what `sendUserMessage` used to produce (the reported bug).
 *
 * Wake: we inject a CUSTOM message (role:"custom"), not a user message. The
 * SDK's `convertToLlm` maps custom → a user-role LLM message, so the agent
 * still sees + replies to it, but `message_end` does NOT buffer role:"custom",
 * so it never replays as `user_input` on session_sync. Mesh messages are held
 * until the current `agent_end` listeners finish, then appended as one batch
 * before a single turn starts. This avoids calling `prompt()` during the gap
 * where Pi has stopped streaming but the current agent run is still active.
 * `id` lets the LLM echo it via
 * `agent_send(..., re=<id>)`.
 */
function _meshMessageForAgent(env: MeshEnvelope) {
  const bodyText = typeof env.body === "string" ? env.body : JSON.stringify(env.body);
  const header = `[agent-network] message from "${env.from}" (id=${env.id}${env.re ? `, re=${env.re}` : ""}):`;
  const footer = env.re
    ? "(This is a reply to a previous message of yours.)"
    : `(If a reply is expected, call agent_send with to="${env.from}" and re="${env.id}".)`;
  return {
    customType: "remote-pi:mesh-message",
    content: `${header}\n${bodyText}\n\n${footer}`,
    display: true,
  };
}

function _scheduleMeshMessageDrain(): void {
  if (ext.meshDrainScheduled || ext.pendingMeshMessages.length === 0) return;
  ext.meshDrainScheduled = true;
  queueMicrotask(() => {
    ext.meshDrainScheduled = false;
    const pi = ext.pi;
    if (ext.agentRunActive || !pi || ext.pendingMeshMessages.length === 0) return;

    const batch = ext.pendingMeshMessages.splice(0);
    let delivered = 0;
    ext.agentRunActive = true;
    try {
      batch.forEach((env, index) => {
        const isLast = index === batch.length - 1;
        pi.sendMessage(
          _meshMessageForAgent(env),
          isLast
            ? { triggerTurn: true, deliverAs: "followUp" }
            : { triggerTurn: false },
        );
        delivered += 1;
      });
    } catch (err) {
      ext.agentRunActive = false;
      ext.pendingMeshMessages = [...batch.slice(delivered), ...ext.pendingMeshMessages];
      const detail = err instanceof Error ? err.message : String(err);
      console.error(`[remote-pi] queued mesh delivery failed: ${detail}`);
      _safeNotify(`[remote-pi] failed to process queued mesh messages: ${detail}`, "error");
    }
  });
}

function _deliverMeshMessageToAgent(env: MeshEnvelope): void {
  const bodyText = typeof env.body === "string" ? env.body : JSON.stringify(env.body);
  const toolCallId = `mesh_${env.id}`;
  _broadcastToActive({
    type: "tool_request",
    tool_call_id: toolCallId,
    tool: "agent-network",
    args: env.re
      ? { from: env.from, re: env.re, message: bodyText }
      : { from: env.from, message: bodyText },
  });
  _broadcastToActive({ type: "tool_result", tool_call_id: toolCallId, result: { from: env.from, message: bodyText } });

  if (!ext.pi) {
    console.error(`[remote-pi] agent-network message from "${env.from}": agent session not bound yet — message dropped`);
    return;
  }
  ext.pendingMeshMessages.push(env);
  _scheduleMeshMessageDrain();
}

/** Test-only entry point for verifying mesh-to-agent delivery semantics. */
export function _deliverMeshMessageToAgentForTest(env: MeshEnvelope): void {
  _deliverMeshMessageToAgent(env);
}

/**
 * Joins the fixed local UDS mesh ("local" session — see LOCAL_SESSION_NAME).
 * Called by `_cmdRoot` on first run and on subsequent runs when the relay
 * is up and the user hasn't explicitly stopped. The session name is no
 * longer user-configurable: every Pi on the same machine joins the same
 * broker.
 */
async function _cmdJoin(ctx: Pick<ExtensionContext, "ui" | "cwd">): Promise<void> {
  const cwd = "cwd" in ctx ? (ctx as ExtensionCommandContext).cwd : process.cwd();
  const local = loadLocalConfig(cwd);
  const sessionName = LOCAL_SESSION_NAME;
  // What the user configured for this agent…
  const requestedName = local.agent_name || defaultAgentName(cwd);
  // …and what we actually register: the name the cwd-lock reserved, which is
  // `requestedName` or a `#N` variant when same-named agents share this folder.
  // Falls back to requestedName when join runs without a prior `_cmdRoot` lock
  // (e.g. legacy/test paths).
  const agentName = ext.lockedName ?? requestedName;

  if (ext.meshNode) {
    ctx.ui.notify("[remote-pi] Already on the local mesh.", "warning");
    return;
  }
  const joinGeneration = ++ext.meshJoinGeneration;

  ensureGlobalDirs();
  mkdirSync(join(skillsDir(), "..", "sessions", sessionName), { recursive: true });

  const sock = sessionSockPath(sessionName);
  const audit = sessionAuditPath(sessionName);
  // Forward the cwd so the broker keys this peer by (cwd, name): a same-folder
  // same-name reincarnation (switch_session re-eval, app restart) takes over the
  // name instead of registering behind a mute `name#N` ghost. Canonicalize via
  // realpath so symlinked cwds map to one identity (matches roomIdForCwd).
  let canonCwd = cwd;
  try { canonCwd = realpathSync(cwd); } catch { /* cwd missing — use raw path */ }
  const peer = new MeshNode({
    sockPath: sock,
    name: agentName,
    cwd: canonCwd,
    auditPath: audit,
    takeoverExisting: process.env["REMOTE_PI_DAEMON"] === "1",
  });

  peer.onMessage((env) => {
    const body = env.body as { type?: string } | null;
    // Broker system events: re-query broker for authoritative count.
    // Incremental ±1 drifts when peer_left is missed (leader leaves cleanly,
    // failover, etc.) — querying list_peers makes the count self-healing.
    if (body && (body.type === "peer_joined" || body.type === "peer_left")) {
      _refreshSessionPeerCount(peer, ctx);
      // Plan/25 Wave B: push fresh peer list to all siblings so their
      // remotePeers cache stays current without polling.
      void peer.request("broker", { type: "list_peers" }, 2000)
        .then((reply) => {
          const body = reply.body as {
            peers?: string[];
            peers_detailed?: Array<{ pc?: string; address?: string }>;
          } | null;
          // onLocalPeersChanged wants LOCAL-only addresses (list_peers returns
          // the aggregated local + cross-PC roster). Prefer the structured
          // roster (plan/38): a local peer has no `pc`. This is drive-letter
          // safe — a Windows local address `C:\…@app` contains ':' but is NOT
          // remote, so the old naive `!p.includes(":")` misclassified it.
          let local: string[] | null = null;
          const detailed = body?.peers_detailed;
          if (Array.isArray(detailed)) {
            local = detailed
              .filter((p) => !p.pc && typeof p.address === "string")
              .map((p) => p.address as string);
          } else if (Array.isArray(body?.peers)) {
            // Fallback for a legacy broker without `peers_detailed`.
            local = body!.peers!.filter((p) => !p.includes(":"));
          }
          // No-op when the bridge isn't up (follower / relay down).
          if (local) peer.onLocalPeersChanged(local);
        })
        .catch(() => { /* bridge not bound yet, or list_peers failed */ });
      return;
    }
    if (env.from === "broker") return;  // other broker control messages — ignore

    // Real agent-to-agent message (SessionPeer already correlated replies via
    // env.re before this point). Show it in the app's TOOL timeline and wake
    // the agent as a CUSTOM message — never as the user's own message.
    _deliverMeshMessageToAgent(env);
  });

  // After failover (leader died, we re-elected): the new broker's peers map
  // starts fresh, but our cached `ext.sessionPeerCount` is stale. Re-seed it so
  // surviving peers don't carry the pre-failover count forever.
  //
  // The cross-PC bridge re-attach on failover (drop the stale broker ref,
  // re-wire against the fresh `localBroker()` if we were promoted to leader)
  // is handled INSIDE MeshNode — no manual teardown/ensure needed here.
  peer.onReconnect(() => {
    _refreshSessionPeerCount(peer, ctx);
  });

  const isCurrentCandidate = (): boolean => (
    !ext.disposed &&
    joinGeneration === ext.meshJoinGeneration &&
    ext.meshNode === null
  );

  try {
    const assigned = await peer.connect();
    // The candidate stays local until connect resolves. Shutdown, stop, or a
    // newer join invalidates its generation; close it instead of publishing a
    // ghost peer or allowing _cmdRoot to continue into Relay startup.
    if (!isCurrentCandidate()) {
      try { await peer.close(); } catch { /* best-effort */ }
      return;
    }
    ext.meshNode = peer;
    ext.sessionName = sessionName;
    ext.sessionPeerCount = 1;  // optimistic — overwritten by list_peers below
    // Broker broadcasts `peer_joined` only to existing peers when a new one
    // arrives — the newcomer doesn't get retroactive joined events. Ask the
    // broker for the live peer list to seed the count correctly on join.
    _refreshSessionPeerCount(peer, ctx);
    // Tell RPC clients (e.g. Cockpit) the EFFECTIVE mesh name. The broker
    // appends a `#N` suffix only on a same-(cwd,name) collision, so the name we
    // requested and the one actually assigned can differ. Emit a pure-data event
    // (display:false) carrying both + a `changed` flag so the client can rename
    // the agent in its own UI to match what the mesh/relay will show. Fired on
    // every join (incl. failover re-elect, which can re-assign the name), so the
    // client always reflects the live name, not just the first one.
    //
    // plan/38 decision E: we deliberately DO NOT persist `assigned`. A `#N` is a
    // RUNTIME collision resolution; freezing it into `agent_name` fossilizes an
    // accident and causes cross-folder name ping-pong across restarts. The clean
    // name (wizard / explicit `agent_name`) already lives in config or re-derives
    // from `basename(cwd)`; the event above carries the live `#N` for the UI.
    ext.pi?.sendMessage({
      customType: "remote-pi:name-assigned",
      content: assigned === requestedName
        ? `Mesh name: ${assigned}`
        : `Mesh name reassigned: "${requestedName}" → "${assigned}" (collision)`,
      details: { requested: requestedName, assigned, changed: assigned !== requestedName },
      display: false,
    });
    ctx.ui.notify(
      `[remote-pi] Joined local mesh as "${assigned}" (${peer.currentRole()})`,
      "info",
    );
    _refreshFooter(ctx);
    // Plan/25 Wave B/C: try to bring up cross-PC routing now that the
    // local broker exists. No-op if the relay isn't up yet (will fire
    // again from `_cmdStart`).
    _attachBridgeIfReady();
  } catch (err) {
    // A replacement/stop/newer join can invalidate this candidate before its
    // failure arrives. Clean it up and never notify the outgoing session ctx.
    if (!isCurrentCandidate()) {
      try { await peer.close(); } catch { /* best-effort */ }
      return;
    }
    ctx.ui.notify(`[remote-pi] join failed: ${String(err)}`, "error");
  }
}

// ── routeClientMessage ────────────────────────────────────────────────────────

/**
 * Per-channel router. Replaces the W2D-pre `routeClientMessage` which
 * implicitly used the `_peerChannel` singleton for replies. Each
 * PlainPeerChannel now carries its own `sender` and passes it here so
 * sender-specific responses (cancelled, pong, session_history) flow back
 * through the right wire instead of being broadcast.
 *
 * Broadcast messages (user_input mirror, agent_chunk, tool_*) still use
 * `_broadcastToActive` from the SDK event handlers; this router only
 * handles incoming app→pi requests.
 */
function _abortCurrentTurn(
  fallbackCtx?: Pick<ExtensionContext, "abort">,
): boolean {
  const candidates: Array<Pick<ExtensionContext, "abort"> | null | undefined> = [
    ext.lastEventCtx,
    ext.lastCtx,
    fallbackCtx,
  ];

  for (const candidate of candidates) {
    if (!candidate || candidate === _noopCtx) continue;
    if (typeof candidate.abort !== "function") continue;
    try {
      candidate.abort();
      return true;
    } catch (err) {
      // Only skip SDK stale-ctx throws and try the next candidate. Real abort
      // failures rethrow so the cancel handler can report action_error.
      const msg = err instanceof Error ? err.message : String(err);
      if (/stale|session replacement or reload/i.test(msg)) continue;
      throw err;
    }
  }

  return false;
}

/**
 * Resolve the model registry for an action: prefer the LIVE session registry
 * from the extension ctx (reflects providers registered dynamically by other
 * extensions via `pi.registerProvider(...)`); otherwise fall back to the
 * async disk-backed registry. pi 0.83 made the fallback build async
 * (`ModelRuntime.create()`), so this awaits.
 */
async function _resolveRegistry(ctx: ActionCtx | null): Promise<ActionModelRegistry> {
  return ctx?.modelRegistry ?? (await ensureModelRegistry());
}

export function _routeClientMessageFrom(
  sender: PlainPeerChannel,
  msg: ClientMessage,
  ctx: Pick<ExtensionContext, "abort">,
): Promise<void> | void {
  // session_sync has its own internal guards — handle before the strict
  // pi-binding guard so a missing ext.pi doesn't drop the reply.
  if (msg.type === "session_sync") {
    return _handleSessionSync(sender, msg);
  }
  if (msg.type === "cancel") {
    try {
      const aborted = _abortCurrentTurn(ctx);
      if (!aborted) {
        sender.send({
          type: "error",
          code: "internal_error",
          in_reply_to: msg.id,
          message: "No active Pi context to abort",
        });
        return;
      }
      sender.send({ type: "cancelled", in_reply_to: msg.id, target_id: msg.target_id });
    } catch (err) {
      sender.send({
        type: "error",
        code: "internal_error",
        in_reply_to: msg.id,
        message: `Abort failed: ${String(err)}`,
      });
    }
    return;
  }
  if (msg.type === "extension_ui_response") {
    ext.extensionUiBridge?.respond(msg);
    return;
  }
  if (!ext.pi) return;
  switch (msg.type) {
    case "queued_message_set": {
      const text = msg.text.trim();
      if (!text) {
        _clearQueuedItems(msg.id);
        break;
      }
      _upsertQueuedItem({ id: msg.id, text, editable: true, created_at: Date.now() });
      _maybeDrainQueuedItem();
      _maybeDrainFollowUp();
      break;
    }
    case "queued_message_clear":
      _clearQueuedItems(msg.target_id);
      break;
    case "user_message": {
      // Source-of-truth rebroadcast (plan/24 W2D fix). Echo the message
      // back to every attached owner (sender included) after the SDK accepts
      // the handoff, so optimistic app bubbles only confirm on real delivery.
      //   1. The sender's app waits for this echo to render (no eager
      //      local store), keeping all owners visually consistent.
      //   2. Other owners see what was said, not just the agent's reply.
      //   3. `id` is preserved verbatim, so future dedup logic on the app
      //      side can key off it.
      // The user_message is also recorded in ext.messageBuffer indirectly
      // via `pi.on("message_end")` after the SDK persists the turn — so
      // a later `session_sync` returns it in the history events.
      // Plan/30: echo any inline images too so every owner renders the same
      // image bubble. No-image path is byte-identical to before (no `images`
      // key on the wire).
      const requestedSteer = msg.streaming_behavior === "steer";
      const isFollowUp = msg.streaming_behavior === "followUp";
      // Plan/127 — a follow-up must NOT be inferred as steer; it queues
      // behind the running turn instead of injecting into it.
      const inferredBusySteer =
        !requestedSteer && !isFollowUp && ext.myRoomMeta?.working === true;
      const shouldSteer = requestedSteer || inferredBusySteer;
      // A reconnecting app can correctly send `steer` while our mirror has no
      // turn id (for example, the turn started while no owner was attached).
      // Also be defensive for clients that send a plain user_message while the
      // room is already working. Tell the SDK this is steering; otherwise it
      // rejects the message as a normal busy prompt. Seed a fallback id so
      // later chunks/done have a target instead of being dropped.
      //
      // Plan/127 — a follow-up with an image is rejected up front. Image
      // attachments are not supported on follow-ups in this slice, and
      // letting it reach the image branch below would inject the message as
      // steer into the running turn (wrong attribution). Reject explicitly
      // so the client can surface the limitation instead of mis-delivering.
      if (isFollowUp && msg.images && msg.images.length > 0) {
        sender.send({
          type: "error",
          code: "unsupported_followup_image",
          in_reply_to: msg.id,
          message:
            "Follow-up messages with image attachments are not supported yet; send the image as a normal message or a steer.",
        });
        break;
      }
      if (msg.images && msg.images.length > 0) {
        void _deliverImageUserMessage(sender, msg, shouldSteer).catch((error) => {
          const detail = error instanceof Error ? error.message : String(error);
          console.error(`[remote-pi] failed delivering image message id=${msg.id}: ${detail}`);
        });
        break;
      }

      // Plan/127 — follow-up while busy: hold the message and drain it on
      // turn_end so its turn is attributed to this id (not the running one).
      // "Busy" is recognized by EITHER signal: an active turn id OR
      // myRoomMeta.working — the reconnect state where the turn started while
      // no owner was attached, so we never learned its id. While idle, fall
      // through to a normal send below.
      if (isFollowUp && _isBusyForQueueDrain()) {
        ext.pendingFollowUps.push({ id: msg.id, text: msg.text });
        _echoUserMessage(msg, false);
        break;
      }

      // Plan/109 — one-shot model override: send this message with a different
      // model (new turn only; model is ignored while steering a running turn).
      if (msg.model && !shouldSteer) {
        void _sendWithModelOverride(sender, msg);
        break;
      }

      const previousTurnId = ext.currentTurnId;
      const seededTurnId = !shouldSteer || ext.currentTurnId === null;
      if (seededTurnId) {
        ext.currentTurnId = msg.id;
      }
      // Always include a streaming delivery mode for app-originated messages.
      // The SDK ignores `deliverAs` when idle, but requires it when a turn is
      // already running. This avoids a race where Remote Pi's mirror has not
      // seen turn_start/currentTurnId yet but the SDK is already busy.
      const wake = _wakeAgent(
        msg.text,
        `app user_message id=${msg.id}`,
        "steer",
      );
      if (!wake.ok) {
        if (seededTurnId) ext.currentTurnId = previousTurnId;
        sender.send({
          type: "error",
          code: "internal_error",
          in_reply_to: msg.id,
          message: `Agent rejected incoming message: ${wake.detail}`,
        });
        break;
      }
      if (shouldSteer) _trackPendingSteer(msg.id, msg.text);
      _echoUserMessage(msg, shouldSteer);
      break;
    }
    case "approve_tool":
      // Approval gate was removed (plano 10.2 revisado). Type kept in
      // ClientMessage for forward-compat with a future permissions model;
      // ignore silently if the app still sends it from an older build.
      break;
    case "ping":
      sender.send({ type: "pong", in_reply_to: msg.id });
      break;
    case "pair_request":
      // Already paired — ignore subsequent pair_request to maintain idempotency.
      // (Token is already consumed and peer is in peers.json.)
      break;
    // Plan/28 — Typed app actions. Each delegates to the pure handler in
    // `actions/handlers.ts`; the only thing this layer does is unify the
    // dep injection (sender, ext.pi, ext.lastCtx, registry). `ext.lastCtx` may be
    // null or a narrower Pick than the handlers want, so we cast to
    // `ActionCtx` — fields that aren't present at runtime are surfaced
    // as `action_error` by the handlers, not as a TypeError.
    case "session_compact":
      // Route through ext.lastEventCtx (refreshed on every session_start), NOT the
      // capturable-stale ext.lastCtx — compact must never hit a ctx left stale by
      // a prior New session. compact() is a base-ctx method, so the
      // session_start ctx suffices. Fall back to ext.lastCtx defensively if no
      // session_start has landed yet (keeps the pre-replacement happy path).
      handleSessionCompact((ext.lastEventCtx ?? ext.lastCtx) as ActionCtx | null, sender, msg);
      break;
    case "session_new": {
      const actionCtx = ext.lastCtx as ActionCtx | null;
      const daemonMode = process.env["REMOTE_PI_DAEMON"] === "1";
      // Fresh Pi session via the supervisor: ack, clear remote-pi's mirror, then
      // exit with the private code so the supervisor relaunches without
      // --continue → a genuinely fresh session. Used when there's NO command ctx
      // AND as recovery when the captured ext.lastCtx has gone STALE after an
      // external session replacement (compact, a /new typed in the TUI,
      // reload/resume). Reusing a stale ctx throws "stale after session
      // replacement", which previously surfaced to the app as a hard failure
      // ("session_new failed") and left New Context wedged.
      const restartFresh = () => {
        sender.send({ type: "action_ok", in_reply_to: msg.id, action: "session_new" });
        _resetSessionForNew(msg.id);
        setTimeout(() => process.exit(EXIT_DAEMON_FRESH_SESSION), 100);
      };
      if (!actionCtx?.newSession) {
        if (daemonMode) {
          restartFresh();
          break;
        }
        sender.send({
          type: "action_error",
          in_reply_to: msg.id,
          action: "session_new",
          error: "newSession unavailable (no command ctx yet)",
        });
        break;
      }
      // Fast path: drive newSession in-process on the (hopefully fresh) command
      // ctx, re-capturing the replacement ctx via withSession so later command
      // ops target the current session. If the ctx turns out stale, recover by
      // restarting fresh (daemon) instead of failing the action.
      // Capture the method past the guard above: TS drops the `!actionCtx?.newSession`
      // narrowing inside the async closure, so bind it to a local const first.
      const newSession = actionCtx.newSession;
      void (async () => {
        try {
          const result = await newSession({
            withSession: async (freshCtx) => {
              ext.lastCtx = freshCtx as unknown as typeof ext.lastCtx;
            },
          });
          if (result?.cancelled) {
            sender.send({
              type: "action_error",
              in_reply_to: msg.id,
              action: "session_new",
              error: "cancelled by extension hook",
            });
            return;
          }
          sender.send({ type: "action_ok", in_reply_to: msg.id, action: "session_new" });
          _resetSessionForNew(msg.id);
        } catch (e) {
          const emsg = String((e as Error)?.message ?? e ?? "");
          const stale = /stale|session replacement or reload/i.test(emsg);
          if (daemonMode && stale) {
            restartFresh();
            return;
          }
          sender.send({
            type: "action_error",
            in_reply_to: msg.id,
            action: "session_new",
            error: emsg || "session_new failed",
          });
        }
      })();
      break;
    }
    case "model_set": {
      const msCtx = (ext.lastEventCtx ?? ext.lastCtx) as ActionCtx | null;
      // Capture the guard-narrowed ext.pi into a const: the narrowing from
      // `if (!ext.pi) return` above does NOT survive into the `.then` closure
      // (mutable module-level let), but a const does.
      const pi = ext.pi;
      void _resolveRegistry(msCtx)
        .then((reg) => handleModelSet(pi, msCtx, reg, sender, msg, _persistModelDefault))
        .catch((err) => {
          // _resolveRegistry() rejected (e.g. ensureModelRegistry() failure).
          // Reply so the client isn't left waiting and the promise can't
          // reject unhandled — mirror handleModelSet's action_error shape.
          sender.send({
            type: "action_error",
            in_reply_to: msg.id,
            action: "model_set",
            error: err instanceof Error ? err.message : String(err),
          });
        });
      break;
    }
    case "thinking_set":
      handleThinkingSet(ext.pi, sender, msg);
      break;
    case "list_models": {
      const lmCtx = (ext.lastEventCtx ?? ext.lastCtx) as ActionCtx | null;
      void _resolveRegistry(lmCtx)
        .then((reg) => handleListModels(lmCtx, reg, sender, msg))
        .catch((err) => {
          // Mirror handleListModels' error envelope on registry-resolution
          // failure so the client gets a reply (no unhandled rejection).
          sender.send({
            type: "error",
            in_reply_to: msg.id,
            code: "internal_error",
            message: err instanceof Error ? err.message : String(err),
          });
        });
      break;
    }
    // Plan/107 — on-demand git status snapshot. Runs `git status` in the
    // session cwd (the one already reported in room_meta) and replies with
    // git_status_result; the relay forwards it verbatim (no relay change).
    case "git_status_request":
      void handleGitStatus(sender, msg, ext.myRoomMeta?.cwd ?? null);
      break;
    // Plan/108 — open a new terminal at a project folder (remote `/ps
    // clone`). Spawns wt.exe / Start-Process in the resolved cwd; replies
    // open_terminal_result (ok:false on unsupported platform / bad path).
    case "open_terminal_request":
      void handleOpenTerminal(sender, msg, ext.myRoomMeta?.cwd ?? null);
      break;
    // Plan/112 — worktree tracking: list tracked worktrees (reconciled) and
    // remove one by id (git worktree remove + branch delete + registry prune).
    case "list_worktrees_request":
      handleListWorktrees(sender, msg);
      break;
    case "remove_worktree_request":
      handleRemoveWorktree(sender, msg);
      break;
    // Plan/121 — list git projects discovered under the configured roots
    // (device daemon serves this so the phone can show a Projects list with
    // no live pi). Spawn-from-project reuses open_terminal_request.
    case "list_projects_request":
      handleListProjects(sender, msg);
      break;
    // api.changeLayout — apply a named `.ckp` layout via the Cockpit CLI
    // (orchestrate). Served by the device daemon like the other actions.
    case "change_layout_request":
      void handleChangeLayout(sender, msg);
      break;
    // Plan/124 — bring an offline session back to life in its own cwd: the
    // device daemon asks the supervisor for a transient `pi --mode rpc
    // --continue` spawn (resumes the existing conversation, re-announces the
    // same room). No new worktree, no pin.
    case "start_session_request":
      handleStartSession(sender, msg);
      break;
  }
}

/**
 * Backward-compatible shim for legacy callers + tests that didn't track
 * a specific sender channel. Routes to the most recently attached owner,
 * mirroring the pre-W2D singleton behavior.
 */
export function routeClientMessage(
  msg: ClientMessage,
  ctx: Pick<ExtensionContext, "abort">,
): Promise<void> | void {
  const fallback = [...ext.activePeers.values()].pop();
  if (!fallback) return;
  return _routeClientMessageFrom(fallback, msg, ctx);
}

// ── session_sync handler + helpers ────────────────────────────────────────────

/**
 * `session_sync` is a per-sender query: the owner asking gets the reply,
 * not the whole broadcast. Otherwise a session_sync from owner A would
 * also dump history to owner B's wire — duplicate traffic + the wrong
 * `in_reply_to`.
 */
async function _handleSessionSync(
  sender: PlainPeerChannel,
  msg: Extract<ClientMessage, { type: "session_sync" }>,
): Promise<void> {
  _sendQueuedState(sender);
  if (ext.sessionStartedAt === null) {
    sender.send({
      type: "session_history",
      in_reply_to: msg.id,
      session_started_at: 0,
      events: [],
      eos: true,
      truncated: false,
    });
    return;
  }

  // Plan/128 — the durable `.jsonl` is the source of truth; page backward via
  // the `before` cursor, merged with the live in-RAM tail. On any failure we
  // fall back to serving the RAM tail (today's behavior) so a corrupt or
  // unreadable transcript never blocks a sync reply.
  let events: SessionHistoryEvent[] = [];
  let hasMore = false;
  let nextBefore: string | undefined;
  try {
    const page = await _pageHistory(msg.before, msg.limit);
    events = page.events;
    hasMore = page.hasMore;
    nextBefore = page.nextBefore;
  } catch {
    // File index unavailable — serve the RAM tail's newest slice. We can't emit
    // a paging cursor here, so report has_more=false (an honest "no further
    // paging available") rather than dangle a load-more affordance that
    // `loadMore` would no-op on (it guards on `nextBefore == null`).
    const max = _getSyncLimit();
    const fallback = _mapAgentMessagesToEvents(ext.messageBuffer);
    events = fallback.slice(-max);
    hasMore = false;
  }

  const reply: Extract<ServerMessage, { type: "session_history" }> = {
    type: "session_history",
    in_reply_to: msg.id,
    session_started_at: ext.sessionStartedAt,
    events,
    eos: true,
    truncated: hasMore, // back-compat alias of `has_more` for older clients
    has_more: hasMore,
  };
  if (nextBefore !== undefined) reply.next_before = nextBefore;
  sender.send(reply);

  // Plan/100 — replay ask_user flows still awaiting an answer. The bridge
  // broadcasts `started` once; a peer that connects afterwards would otherwise
  // see the tool call as plain history text while the desktop stays blocked on
  // the TUI dialog (reproduced: close the app, fire ask_user, reopen → no
  // sheet). Sent AFTER the history so the modal opens over a synced chat, and
  // per-sender like the rest of this handler — a sync from owner A must not
  // pop a modal on owner B. Flows past FLOW_TTL_MS are already gone from the
  // bridge, so an abandoned flow is never resurrected.
  for (const req of ext.extensionUiBridge?.pendingRequests() ?? []) {
    sender.send(req);
  }
}

/**
 * Plan/128 — serve one backward page of session history from the durable
 * `.jsonl` index, merged with the live in-RAM tail, honoring the `before`
 * cursor. See `session/file_index.ts` for the index/cache/cursor codec.
 *
 * Unified view: file entries (ts-sorted — the file is append-only ⇒ byteOffset
 * order == ts order) ts-MERGED with RAM-supplement entries (`messageBuffer`
 * items NOT already in the file index: synthetic compaction markers + not-yet-
 * flushed messages, also ts-sorted). A merge (not concatenation) is required
 * because compaction markers are synthetic and interspersed chronologically
 * (a compaction fires mid-session), so a supplement entry can sit between two
 * file entries. Cost is O(N+M) metadata merge + O(page) disk reads.
 */
async function _pageHistory(
  before: string | undefined,
  clientLimit: number | undefined,
): Promise<{ events: SessionHistoryEvent[]; hasMore: boolean; nextBefore?: string }> {
  const serverMax = _getSyncLimit();
  const limit = Math.max(1, Math.min(clientLimit ?? serverMax, serverMax));

  // Resolve + lazily refresh the durable index (cache hit / tail-scan / rebuild).
  const ref = resolveCurrentSessionFile(process.cwd());
  let idx = ext.historyIndex;
  if (ref) {
    try {
      idx = await refreshIndex(idx, ref);
      ext.historyIndex = idx;
    } catch {
      idx = null; // unreadable file → serve the RAM tail only
    }
  } else if (idx) {
    idx = null;
    ext.historyIndex = null;
  }

  type Slot = { kind: "file"; ts: number; role: string; offset: number; byteLen: number } | { kind: "ram"; ts: number; role: string; bufIndex: number };
  // File slots are ts-sorted (the file is append-only ⇒ byteOffset order == ts
  // order); RAM-supplement slots are ts-sorted (messageBuffer is append-only ⇒
  // chronological). Synthetic compaction markers live only in the RAM tail and
  // are interspersed chronologically (a compaction fires mid-session), so we
  // ts-MERGE the two sorted sequences rather than concatenate. Cost is O(N+M)
  // over metadata only — no message bodies, no per-row reads.
  const fileSlots: Slot[] = [];
  if (idx) for (const fe of idx.entries) fileSlots.push({ kind: "file", ts: fe.ts, role: fe.role, offset: fe.byteOffset, byteLen: fe.byteLen });
  const ramSlots: Slot[] = [];
  for (let i = 0; i < ext.messageBuffer.length; i++) {
    const m = ext.messageBuffer[i];
    if (!idx || !idx.keys.has(`${_tsOf(m)}:${_roleOf(m)}`)) {
      ramSlots.push({ kind: "ram", ts: _tsOf(m), role: _roleOf(m), bufIndex: i });
    }
  }
  const slots: Slot[] = [];
  let fi = 0;
  let ri = 0;
  while (fi < fileSlots.length && ri < ramSlots.length) {
    slots.push(fileSlots[fi]!.ts <= ramSlots[ri]!.ts ? fileSlots[fi++]! : ramSlots[ri++]!);
  }
  while (fi < fileSlots.length) slots.push(fileSlots[fi++]!);
  while (ri < ramSlots.length) slots.push(ramSlots[ri++]!);

  // Decode cursor → position of the boundary entry in the unified (ts-sorted)
  // list; the page is the `limit` entries strictly older than it.
  const cursor = decodeCursor(before);

  // Plan/128 (review C3) — the index cap drops the oldest metadata; a cursor
  // at/below the retained floor can't be served from `idx.entries`. Stream the
  // file from offset 0 to serve those on-disk entries so paging below the cap
  // still works (the durable-full-history promise holds past INDEX_MAX). Only
  // runs when capped AND the cursor is a file offset at/below the floor; the
  // common path stays index-based. A read error here propagates to the outer
  // handler's RAM fallback (review C4).
  if (
    idx &&
    idx.olderDropped &&
    cursor &&
    cursor.kind === "off" &&
    idx.entries.length > 0 &&
    cursor.offset <= idx.entries[0]!.byteOffset
  ) {
    const streamed = await streamPageBefore(idx.path, { kind: "off", offset: cursor.offset }, limit);
    if (streamed) {
      const pageMsgs = streamed.entries.length > 0
        ? await readMessages(idx.path, streamed.entries)
        : [];
      const precedingUserId = streamed.precedingUserTs != null ? `sync_${streamed.precedingUserTs}` : undefined;
      return {
        events: _mapAgentMessagesToEvents(pageMsgs, precedingUserId),
        hasMore: streamed.hasMore,
        nextBefore: streamed.nextBefore ? encodeCursor(streamed.nextBefore) : undefined,
      };
    }
    // stream read failed → fall through; the index path degrades gracefully.
  }

  let endIdx: number;
  if (!cursor) {
    endIdx = slots.length;
  } else {
    endIdx = slots.findIndex((s) =>
      cursor.kind === "off"
        ? s.kind === "file" && s.offset === cursor.offset
        : s.kind === "ram" && s.bufIndex === cursor.index,
    );
    if (endIdx === -1) {
      // cursor entry no longer in the (possibly cap-dropped) index: its older
      // neighbors sit below the cap and need a cold re-scan — signal "no more".
      return { events: [], hasMore: false };
    }
  }

  const startIdx = Math.max(0, endIdx - limit);
  const pageSlots = slots.slice(startIdx, endIdx);
  // Plan/128 (review C3) — `olderDropped` means older entries remain on disk
  // even when the page reaches the index floor (startIdx === 0); advertise
  // has_more and point nextBefore at the floor so the next page streams below it.
  const hasMore = startIdx > 0 || idx?.olderDropped === true;
  const nextBefore = hasMore && slots.length > 0 ? _slotCursor(slots[Math.max(0, startIdx)]!) : undefined;

  // Plan/128 (review C2) — seed the mapper with the user id immediately BEFORE
  // the page so an assistant at the page start (whose user msg sits in an older
  // page) still replies to the right id. `sync_<ts>` is stable (derived from the
  // user msg's ts), so the assistant's merge key is invariant under page shifts.
  let precedingUserId: string | undefined;
  for (let i = Math.min(startIdx, slots.length) - 1; i >= 0; i--) {
    if (slots[i]!.role === "user") {
      precedingUserId = `sync_${slots[i]!.ts}`;
      break;
    }
  }

  // Read page messages: file byte-ranges in one batch + RAM entries directly.
  const pageFileEntries = pageSlots
    .filter((s): s is Extract<Slot, { kind: "file" }> => s.kind === "file")
    .map<FileIndexEntry>((s) => ({ byteOffset: s.offset, byteLen: s.byteLen, ts: 0, role: "" }));
  const fileMsgByOffset = new Map<number, BufferMsg>();
  if (idx && pageFileEntries.length > 0) {
    // Plan/128 (review C4) — let a range-read failure propagate to the outer
    // handler's RAM fallback. Swallowing it would advance next_before/has_more
    // over an empty/partial page, making the client skip undelivered events.
    const msgs = await readMessages(idx.path, pageFileEntries);
    for (let i = 0; i < pageFileEntries.length; i++) {
      if (msgs[i]) fileMsgByOffset.set(pageFileEntries[i].byteOffset, msgs[i]);
    }
  }

  const pageMsgs: BufferMsg[] = [];
  for (const s of pageSlots) {
    if (s.kind === "ram") {
      // The buffer may have been cleared (e.g. `session_new`) during the
      // read await above; skip stale indices instead of pushing `undefined`.
      const m = ext.messageBuffer[s.bufIndex];
      if (m) pageMsgs.push(m);
    } else {
      const m = fileMsgByOffset.get(s.offset);
      if (m) pageMsgs.push(m);
    }
  }

  return { events: _mapAgentMessagesToEvents(pageMsgs, precedingUserId), hasMore, nextBefore };
}

function _tsOf(m: BufferMsg): number {
  return typeof m.timestamp === "number" && Number.isFinite(m.timestamp) ? m.timestamp : 0;
}
function _roleOf(m: BufferMsg): string {
  return typeof m.role === "string" ? m.role : "";
}
function _slotCursor(slot: { kind: "file"; offset: number } | { kind: "ram"; bufIndex: number }): string {
  return slot.kind === "file"
    ? encodeCursor({ kind: "off", offset: slot.offset })
    : encodeCursor({ kind: "ram", index: slot.bufIndex });
}

/**
 * Resets the Pi-side session view after a SUCCESSFUL `session_new`. The app's
 * New Session clears its local store on `action_ok`, but that alone isn't
 * durable: `ext.messageBuffer` (which answers `session_sync`) is append-only and
 * `ext.sessionStartedAt` is stamped once, so a later reconnect/restart would
 * replay the OLD history. We clear the buffer, restamp the clock, and
 * broadcast an EMPTY `session_history` — the exact shape `_handleSessionSync`
 * sends, just with `events: []` — so every attached owner drops the stale
 * conversation. The app's `_applyHistory` substitutes its cache wholesale, so
 * no new app-side code is needed.
 *
 * Unlike a per-request session_history reply (which must go to the sender
 * channel only — see `_broadcastToActive`), this is an intentional fan-out:
 * a new session is global state, so every owner must see the reset.
 */
function _resetSessionForNew(inReplyTo: string): void {
  ext.messageBuffer = [];
  ext.historyIndex = null; // new session rotates to a new `.jsonl`; drop the cache
  ext.pendingSteers = [];
  ext.pendingFollowUps = [];
  ext.lastConsumedSteerText = null;
  _resetQueuedItems({ broadcast: true });
  ext.sessionStartedAt = Date.now();
  _broadcastToActive({
    type: "session_history",
    in_reply_to: inReplyTo,
    session_started_at: ext.sessionStartedAt,
    events: [],
    eos: true,
    truncated: false,
  });
}


/**
 * Plan/30: extract `ImageContent` blocks ({type:"image", data, mimeType}) from
 * an SDK message's content and map them to the wire shape (`mimeType` → `mime`).
 * Used by the history mapper so a re-synced image bubble keeps its bytes —
 * `stringifyContent` only pulls text and would otherwise drop the image.
 */
function _imagesFromContent(content: unknown): WireImage[] {
  if (!Array.isArray(content)) return [];
  const out: WireImage[] = [];
  for (const c of content) {
    if (!c || typeof c !== "object") continue;
    const block = c as { type?: string; data?: unknown; mimeType?: unknown };
    if (block.type === "image" && typeof block.data === "string" && typeof block.mimeType === "string") {
      out.push({ data: block.data, mime: block.mimeType });
    }
  }
  return out;
}

/**
 * Maps SDK AgentMessage[] (UserMessage / AssistantMessage / ToolResultMessage)
 * into the flat SessionHistoryEvent[] shape consumed by the app.
 *
 * Caveats (see report): in_reply_to of agent_message is the *last* user_input
 * id seen in a linear scan — fine for typical conversational flow but not
 * a perfect reconstruction of multi-turn ordering when tools interleave.
 * Stable id for user_input is `sync_<timestamp>`.
 */
export function _mapAgentMessagesToEvents(
  messages: BufferMsg[],
  precedingUserId?: string,
): SessionHistoryEvent[] {
  const events: SessionHistoryEvent[] = [];
  // Plan/128 (review C2) — seed with the user id immediately before this page
  // (passed by _pageHistory) so an assistant at the page start replies to a
  // stable id instead of a page-boundary-dependent fallback.
  let lastUserId: string | null = precedingUserId ?? null;

  for (const m of messages) {
    const ts = typeof m.timestamp === "number" ? m.timestamp : 0;

    if (m.role === "compaction") {
      // Plan/32: re-render the compaction notice on history re-sync.
      events.push({
        ts,
        type: "compaction",
        summary: typeof m.content === "string" ? m.content : "",
        tokens_before: typeof m.tokensBefore === "number" ? m.tokensBefore : 0,
      });
    } else if (m.role === "user") {
      const id = `sync_${ts}`;
      lastUserId = id;
      // Plan/30: keep any image blocks so a re-sync rebuilds the bubble. The
      // bytes are already in ext.messageBuffer; only attach `images` when present
      // so the text-only path stays byte-identical (no `images` key).
      const images = _imagesFromContent(m.content);
      const ev: SessionHistoryEvent = {
        ts,
        type: "user_input",
        id,
        text: stringifyContent(m.content),
      };
      if (images.length > 0) ev.images = images;
      events.push(ev);
    } else if (m.role === "assistant") {
      const content = Array.isArray(m.content) ? m.content : [];
      const usage = m.usage
        ? { input_tokens: m.usage.input ?? 0, output_tokens: m.usage.output ?? 0 }
        : undefined;
      for (const raw of content) {
        if (!raw || typeof raw !== "object") continue;
        const block = raw as { type?: string; text?: unknown; id?: unknown; name?: unknown; arguments?: unknown };
        if (block.type === "text") {
          const text = String(block.text ?? "");
          if (!text) continue;
          const ev: SessionHistoryEvent = {
            ts,
            type: "agent_message",
            in_reply_to: lastUserId ?? `sync_${ts}`,
            text,
            ...(usage ? { usage } : {}),
          };
          events.push(ev);
        } else if (block.type === "toolCall") {
          events.push({
            ts,
            type: "tool_request",
            tool_call_id: String(block.id ?? ""),
            tool: String(block.name ?? ""),
            args: (block.arguments as Record<string, unknown>) ?? {},
          });
        }
      }
    } else if (m.role === "toolResult") {
      // Same helper as the live `tool_execution_end` broadcast → live == re-sync.
      const text = stringifyToolResult(m.content);
      const tcid = String(m.toolCallId ?? "");
      events.push(
        m.isError
          ? { ts, type: "tool_result", tool_call_id: tcid, error: text }
          : { ts, type: "tool_result", tool_call_id: tcid, result: text },
      );
    }
  }

  return events;
}

// ── Standalone CLI ────────────────────────────────────────────────────────────

/**
 * `remote-pi restart-supervisor` — restarts the `pi-supervisord` PROCESS
 * (not the daemons). The supervisor is a long-running Node process with no
 * hot-reload, so after a `dist` rebuild the old code keeps running until the
 * process is restarted. The Cockpit "Restart supervisor" button shells out to
 * this; the OS-specific restart lives here so the app stays cross-platform.
 *
 * Restarting the supervisor re-spawns every daemon as a side effect. Exits 0
 * on success, non-zero on failure (the Cockpit detects failure by exit code).
 */
/** One step of a restart sequence. `ignoreFailure` steps (e.g. `schtasks /End`
 *  when the task isn't running) don't abort the sequence. */
export interface RestartStep { cmd: string; args: string[]; ignoreFailure?: boolean }

/** Pure: the OS command sequence that restarts the supervisor service, or null
 *  when the platform isn't supported. Most platforms are 1 step; Windows is 2
 *  (`schtasks /End` then `/Run`). Exported for tests. */
export function _restartSupervisorCommand(
  platform: NodeJS.Platform,
  uid: number,
): RestartStep[] | null {
  if (platform === "darwin") return [{ cmd: "launchctl", args: ["kickstart", "-k", `gui/${uid}/${LAUNCHD_LABEL}`] }];
  if (platform === "linux") return [{ cmd: "systemctl", args: ["--user", "restart", SYSTEMD_UNIT] }];
  if (platform === "win32") return [
    { cmd: "schtasks", args: ["/End", "/TN", WINDOWS_TASK_NAME], ignoreFailure: true },
    { cmd: "schtasks", args: ["/Run", "/TN", WINDOWS_TASK_NAME] },
  ];
  return null;
}

function _restartSupervisor(): void {
  const uid = process.getuid?.() ?? 0;
  const steps = _restartSupervisorCommand(process.platform, uid);
  if (!steps) {
    console.error(
      `[remote-pi] restart-supervisor is not supported on '${process.platform}' yet. ` +
      "Restart pi-supervisord manually.",
    );
    process.exit(1);
  }
  for (const step of steps) {
    const r = spawnSync(step.cmd, step.args, { stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" });
    if (r.error) {
      if (step.ignoreFailure) continue;
      console.error(`[remote-pi] restart-supervisor failed: ${step.cmd} not runnable (${r.error.message}). Is the service installed? Run \`remote-pi install\`.`);
      process.exit(1);
    }
    if (r.status !== 0 && !step.ignoreFailure) {
      const detail = (r.stderr || r.stdout || "").trim();
      console.error(`[remote-pi] restart-supervisor failed (${step.cmd} exited ${r.status})${detail ? `: ${detail}` : ""}.`);
      process.exit(r.status === null ? 1 : r.status);
    }
  }
  console.log("[remote-pi] Supervisor restarted.");
}

function _isDirectRun(): boolean {
  try {
    return fileURLToPath(import.meta.url) === realpathSync(process.argv[1] ?? "");
  } catch {
    return false;
  }
}

/**
 * Read-only probe of the local UDS broker for the mesh roster, backing
 * `remote-pi peers`. Opens a raw connection to `sockPath`, sends a single
 * unregistered `list_peers` request, and resolves with the peer names from the
 * broker's reply (local UDS peers + cross-PC `<pc>:<peer>` entries).
 *
 * The probe deliberately does NOT register as a peer: the broker answers
 * observer probes without assigning a name or broadcasting peer_joined/left
 * (see Broker._tryObserverProbe), so a shell query never perturbs the mesh —
 * no phantom peer flashes in anyone's roster, local or cross-PC.
 *
 * Resolves null when no broker is reachable (connection refused / no socket
 * file — i.e. no Pi or daemon is leading the mesh on this machine), or on
 * timeout, so the caller can print an "offline" message instead of an empty
 * roster.
 */
export async function probeListPeers(
  sockPath: string,
  timeoutMs = 2000,
): Promise<string[] | null> {
  const { createConnection } = await import("node:net");
  return new Promise<string[] | null>((resolve) => {
    const sock = createConnection({ path: sockPath });
    let buf = "";
    let settled = false;
    const done = (result: string[] | null): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { sock.destroy(); } catch { /* already gone */ }
      resolve(result);
    };
    const timer = setTimeout(() => done(null), timeoutMs);
    sock.setEncoding("utf8");
    sock.on("connect", () => {
      try { sock.write(JSON.stringify({ type: "list_peers" }) + "\n"); }
      catch { done(null); }
    });
    sock.on("data", (chunk: string) => {
      buf += chunk;
      const nl = buf.indexOf("\n");
      if (nl < 0) return;  // wait for a full line
      const line = buf.slice(0, nl);
      try {
        const env = JSON.parse(line) as { body?: { type?: string; peers?: unknown } };
        const body = env.body;
        if (body && body.type === "list_peers_reply" && Array.isArray(body.peers)) {
          done(body.peers.filter((p): p is string => typeof p === "string"));
          return;
        }
      } catch { /* fall through */ }
      done(null);  // a line arrived but it wasn't the reply we expected
    });
    sock.on("error", () => done(null));  // ECONNREFUSED / ENOENT → mesh offline
    sock.on("close", () => done(null));
  });
}

if (_isDirectRun()) {
  const [, , subcmd, ...cliArgs] = process.argv;
  if (subcmd === "devices" || subcmd === "list") {
    const peers = (await listPeers())
      .map(_inspectPeerRecord)
      .filter((peer): peer is InspectedPeerRecord => peer !== null);
    if (peers.length === 0) { console.log("[remote-pi] No peers"); }
    else {
      for (const peer of peers) {
        console.log(`• ${peer.rawHandle.slice(0, 8)} — ${peer.record.name}`);
      }
    }
  } else if (subcmd === "revoke") {
    const shortid = (cliArgs[0] ?? "").trim();
    if (!shortid) {
      console.log("Usage: revoke <shortid>");
    } else {
      const matches = (await listPeers())
        .map(_inspectPeerRecord)
        .filter((peer): peer is InspectedPeerRecord => peer !== null)
        .filter((peer) => peer.rawHandle.startsWith(shortid));
      if (matches.length === 0) console.log("No peer matching that shortid");
      else if (matches.length > 1) console.log(`Ambiguous: ${matches.map((peer) => peer.rawHandle.slice(0, 8)).join(", ")}`);
      else {
        const peer = matches[0]!;
        const { removePeer } = await import("./pairing/storage.js");
        await removePeer(peer.rawHandle);
        console.log(`Revoked: ${peer.record.name} (${peer.rawHandle.slice(0, 8)}…)`);
      }
    }
  } else if (subcmd === "set-relay") {
    const raw = (cliArgs[0] ?? "").trim();
    if (!raw) {
      console.log(`Usage: set-relay <url> (default: ${kDefaultRelayUrl})`);
    } else if (isWebSocketScheme(raw)) {
      console.log(`Use http:// or https://. The extension converts to WebSocket automatically.`);
    } else if (!isValidRelayUrl(raw)) {
      console.log(`Invalid URL: ${raw}. Must start with http:// or https://`);
    } else {
      saveConfig({ relay: raw });
      console.log(`Relay set to ${raw}`);
    }
  } else if (subcmd === "set-advertise") {
    const raw = (cliArgs[0] ?? "").trim();
    if (!raw) {
      saveConfig({ advertise: undefined });
      console.log("Advertised address cleared — the pairing QR falls back to this machine's LAN address");
    } else if (isWebSocketScheme(raw)) {
      console.log(`Use http:// or https://. The extension converts to WebSocket automatically.`);
    } else if (!isValidRelayUrl(raw)) {
      console.log(`Invalid URL: ${raw}. Must start with http:// or https://`);
    } else {
      saveConfig({ advertise: raw });
      console.log(`Pairing QR will advertise ${raw}`);
    }
  } else if (subcmd === "create") {
    // Standalone: `remote-pi create <cwd> [--name "X"]`. The shell already
    // split the args and stripped the outer quotes, so an arg like
    // `Tmp Agent` arrives as a single element with embedded space. Re-add
    // quotes around any arg containing whitespace so the regex-based
    // parser (shared with the slash-command path) sees the same shape
    // as it would from a Pi interactive prompt.
    const joined = cliArgs.map((a) => (/\s/.test(a) ? `"${a}"` : a)).join(" ");
    await cmdCreate(joined, {
      ui: { notify: (msg: string) => console.log(msg) } as unknown as ExtensionContext["ui"],
    });
  } else if (subcmd === "remove") {
    const id = (cliArgs[0] ?? "").trim();
    await cmdRemove(id, {
      ui: { notify: (msg: string) => console.log(msg) } as unknown as ExtensionContext["ui"],
    });
  } else if (subcmd === "daemons") {
    // Mirror the slash handler: ask the supervisor when reachable,
    // fall back to registry-only when not.
    const stubCtx = { ui: { notify: (msg: string) => console.log(msg) } as unknown as ExtensionContext["ui"] };
    await cmdDaemonsList(stubCtx);
  } else if (subcmd === "daemon") {
    // `remote-pi daemon <op> [args]`. Reuse the fleet-ops handlers — they
    // already accept a minimal ctx with `notify`.
    const op = cliArgs[0] ?? "";
    const rest = cliArgs.slice(1).map((a) => (/\s/.test(a) ? `"${a}"` : a)).join(" ");
    const stubCtx = { ui: { notify: (msg: string) => console.log(msg) } as unknown as ExtensionContext["ui"] };
    if      (op === "start")   { await cmdDaemonStart(stubCtx, cliArgs[1]); }
    else if (op === "stop")    { await cmdDaemonStop(stubCtx, cliArgs[1]); }
    else if (op === "restart") { await cmdDaemonRestart(stubCtx, cliArgs[1]); }
    else if (op === "status")  { await cmdDaemonStatus(stubCtx); }
    else if (op === "send")    { await cmdDaemonSend(rest, stubCtx); }
    else {
      console.log("Usage: remote-pi daemon <start|stop|restart [<id>]|status|send <id> \"<text>\">");
    }
  } else if (subcmd === "cron") {
    // `remote-pi cron <op> [args]`. Re-quote args with spaces so the shared
    // parser sees the same shape as a Pi slash prompt.
    const joined = cliArgs.map((a) => (/\s/.test(a) ? `"${a}"` : a)).join(" ");
    const stubCtx = { ui: { notify: (msg: string) => console.log(msg) } as unknown as ExtensionContext["ui"] };
    await cmdCron(joined, stubCtx);
  } else if (subcmd === "peers") {
    // Read-only roster of the local + cross-PC mesh. Unlike `devices` (which
    // reads paired phones from peers.json), the mesh roster lives only in the
    // running broker's memory, so we probe the UDS broker. The probe never
    // registers as a peer — it leaves no trace on the mesh (see
    // Broker._tryObserverProbe). Null = no broker reachable on this machine.
    const peers = await probeListPeers(sessionSockPath(LOCAL_SESSION_NAME));
    if (peers === null) {
      console.log("[remote-pi] Mesh offline — no agent is running on this machine.");
    } else {
      console.log(`[remote-pi] peers:\n${formatPeerInventory(peers)}`);
    }
  } else if (subcmd === "claude") {
    await _cmdClaudeCli(cliArgs);
  } else if (subcmd === "install") {
    // CLI mode = user installed via `npm install -g remote-pi`, so the
    // `remote-pi` / `pi-supervisord` bins are already on $PATH via npm's
    // global prefix. Explicit `linkCli: false` so we never stomp those
    // with symlinks pointing at a parallel Pi-extension install.
    const stubCtx = { ui: { notify: (msg: string) => console.log(msg) } as unknown as ExtensionContext["ui"] };
    // Propagate failure as a non-zero exit so callers (Cockpit / CI) detect it
    // — installService throws on a failed schtasks/launchctl/systemctl step.
    if (!cmdInstall(stubCtx, { linkCli: false })) process.exit(1);
  } else if (subcmd === "uninstall") {
    const stubCtx = { ui: { notify: (msg: string) => console.log(msg) } as unknown as ExtensionContext["ui"] };
    // `linkCli: true` even from the CLI: unlinking is ALWAYS safe and must run
    // regardless of how install ran. `unlinkCliBinaries` only removes OUR
    // reserved symlinks (`remote-pi` / `pi-supervisord`) under `~/.local/bin`;
    // npm-global bins live in a different prefix and are never touched. So a
    // user who installed via the TUI (`/remote-pi install`, which links) and
    // uninstalls from a shell still gets the links cleaned up — the asymmetry
    // that left an orphaned `~/.local/bin/remote-pi` behind.
    cmdUninstall(stubCtx, { linkCli: true });
  } else if (subcmd === "restart-supervisor") {
    _restartSupervisor();
  } else {
    console.log([
      "Usage: remote-pi <command>",
      "",
      "Daemon registry:",
      "  create <cwd> [--name \"Name\"]   Register a folder as a daemon",
      "  remove <id>                     Unregister a daemon",
      "  daemons                         List registered daemons",
      "",
      "Fleet control:",
      "  daemon start [<id>]             Start all daemons, or one by id",
      "  daemon stop [<id>]              Stop all daemons, or one by id",
      "  daemon restart [<id>]           Restart all daemons, or one by id",
      "  daemon status                   Show pid / uptime / restarts",
      "  daemon send <id> \"<text>\"       Send a prompt to a daemon",
      "  cron add <id> \"<expr>\" \"<txt>\"  Schedule a recurring prompt (≥60s; --tz, --wake)",
      "  cron list|run|remove|log        Manage scheduled prompts (needs the supervisor)",
      "",
      "Service:",
      "  install                         Install pi-supervisord as a system service",
      "  uninstall                       Remove the system service",
      "  restart-supervisor              Restart the pi-supervisord process",
      "",
      "Devices:",
      "  devices                         List paired phones (peers.json)",
      "  revoke <shortid>                Revoke a paired device",
      "",
      "Config:",
      "  set-relay <url>                 Set the relay URL this machine connects to",
      "  set-advertise [<url>]           Set the address the pairing QR advertises",
      "                                  (e.g. a Tailscale IP); empty clears it",
      "",
      "Agent mesh:",
      "  peers                           List agents on the local + cross-PC mesh",
      "  claude [cwd]                    Start Claude Code connected to the agent mesh",
    ].join("\n"));
  }
}

// ── `remote-pi claude` — launch Claude Code connected to the mesh ─────────────

/**
 * Resolve the packaged agent-network skill path
 * (`<pkgRoot>/skills/agent-network/SKILL.md`). Single source of truth shared
 * by both runtimes: Pi discovers it via `resources_discover`, and the Claude
 * launcher injects it as a system prompt (see `_cmdClaudeCli`). Returns null
 * if the file is missing (e.g. running before `pnpm build`).
 */
function _agentNetworkSkillPath(): string | null {
  const here = fileURLToPath(import.meta.url);            // dist/index.js (or src/index.ts via tsx)
  const pkgRoot = dirname(dirname(here));                 // package root (dist → ..; src → ..)
  const skill = join(pkgRoot, "skills", "agent-network", "SKILL.md");
  return existsSync(skill) ? skill : null;
}

async function _cmdClaudeCli(args: string[]): Promise<void> {
  // Contract: `remote-pi claude [cwd] [claude-flags...]`. The optional cwd is
  // ONLY the leading positional (first token, not a flag); everything after it
  // is forwarded verbatim to the `claude` binary (e.g. `--resume`, `-c`,
  // `-p "prompt"`). Restricting cwd to the leading token avoids mistaking a
  // flag's value (e.g. the id in `--resume <id>`) for the cwd.
  const hasCwdArg = args.length > 0 && !args[0]!.startsWith("-");
  const targetCwd = hasCwdArg ? args[0]! : process.cwd();
  const passthroughArgs = hasCwdArg ? args.slice(1) : args;

  // Wizard when no local config exists
  if (!localConfigExists(targetCwd)) {
    const suggested = defaultAgentName(targetCwd);
    process.stdout.write(`\n[remote-pi] No config found for ${targetCwd}\n`);
    process.stdout.write("Let's set up this agent.\n\n");

    const rl = createInterface({ input: process.stdin, output: process.stdout });
    const agentName: string = await new Promise((res) =>
      rl.question(`Agent name [${suggested}]: `, (ans) => { rl.close(); res(ans.trim() || suggested); }),
    );

    saveLocalConfig(targetCwd, { agent_name: agentName, auto_start_relay: true });
    process.stdout.write(`[remote-pi] Config saved: agent="${agentName}"\n\n`);
  }

  // Resolve mesh server script path (dist/mcp/mesh_server.js)
  const here = fileURLToPath(import.meta.url);
  const distRoot = dirname(here);
  const meshServerPath = resolve(distRoot, "mcp/mesh_server.js");

  if (!existsSync(meshServerPath)) {
    console.log(`[remote-pi] mesh server not found at ${meshServerPath}. Run pnpm build first.`);
    process.exit(1);
  }

  const absCwd = resolve(targetCwd);
  const SERVER_NAME = "remote-pi-mesh";

  // The mesh MCP must be visible ONLY inside a `remote-pi claude` session — a
  // plain `claude` in the same repo must NOT inherit it (otherwise every
  // ordinary session silently joins the mesh as a stray agent).
  //
  // Older builds registered the server with `claude mcp add -s local`. That
  // scope lives in `~/.claude.json` keyed by the **git repo root** and is
  // inherited by EVERY claude session under that root — which is exactly the
  // leak we're closing. So we no longer write any persistent scope; we load
  // the server through an ephemeral `--mcp-config <tmpfile>` passed on the
  // launch command line (see below). That config is session-only: it is never
  // recorded in any scope `claude mcp list` enumerates, so a normal `claude`
  // sees nothing.
  //
  // Migration: best-effort scrub of the stale `-s local` entry that prior
  // versions left behind (and that is the source of the inherited-mesh bug).
  // Idempotent — a no-op (non-zero, ignored) when the entry is already gone.
  spawnSync("claude", ["mcp", "remove", SERVER_NAME, "-s", "local"], {
    cwd: absCwd, stdio: "ignore", shell: false,
  });

  // Ephemeral MCP config consumed by `--mcp-config` below. We do NOT bake a
  // `cwd` into it: the server resolves its folder from its own `process.cwd()`,
  // which Claude sets to the directory the session was launched in (verified
  // empirically — NOT the git root, NOT CLAUDE_PROJECT_DIR). We spawn claude
  // with `cwd: absCwd`, the MCP child inherits it, so the server self-identifies
  // as the right agent without leaking that path to any other session.
  // Unique per pid so concurrent `remote-pi claude` launches don't collide.
  const mcpConfigPath = join(tmpdir(), `remote-pi-mesh-mcp-${process.pid}.json`);
  writeFileSync(mcpConfigPath, JSON.stringify({
    mcpServers: {
      [SERVER_NAME]: { command: process.execPath, args: [meshServerPath] },
    },
  }));

  // Inject the agent-network protocol as a system prompt instead of deploying a
  // skill file into ~/.claude. Anyone running `remote-pi claude` is here to use
  // the mesh, so load the protocol unconditionally — no lazy skill gating, no
  // global skills-dir pollution, and the packaged file is the single source of
  // truth shared with the Pi runtime. Skipped only if the file is missing.
  const skillPath = _agentNetworkSkillPath();

  // Launch flags:
  //   --mcp-config <tmpfile>                       — load the mesh server for
  //       THIS session only (never a persistent scope). We intentionally omit
  //       `--strict-mcp-config` so the user's own persistent MCP servers stay
  //       available alongside the mesh.
  //   --dangerously-load-development-channels TAG  — enable claude/channel push
  //       for our local (non-allowlisted) server, so incoming mesh messages
  //       wake Claude instead of waiting for a get_messages poll. Entries must
  //       be tagged: `server:<name>` for a manually configured MCP server
  //       (`plugin:<name>@<marketplace>` is the plugin form). Shows a one-time
  //       confirmation dialog at startup. Works against the `--mcp-config`
  //       server in current Claude Code; if a build ever fails to match it, the
  //       per-turn `get_messages` poll (mandated by the mesh protocol) still
  //       delivers — we lose the wake, not the messages.
  //   --dangerously-skip-permissions               — auto-approve tool calls
  //   --append-system-prompt-file=<skill>           — load the mesh protocol
  // `--append-system-prompt-file` uses the glued `--flag=value` form (a SINGLE
  // argv token) on purpose: tools that restore a session by capturing and
  // replaying the live process's argv (e.g. cmux) drop the TRAILING token,
  // which here was the skill path — leaving a dangling `--append-system-prompt-file`
  // → `claude` aborts with "argument missing" and the session never comes back.
  // As one token, the worst case is the whole flag being dropped: claude still
  // starts (just without the injected protocol), which is recoverable instead
  // of fatal. (The other flags stay separate pairs — never last, so unaffected,
  // and we don't risk a parser that may not accept `=`.)
  // Any extra args the user passed (e.g. `--resume`, `-c`) are appended last so
  // they reach the claude binary; ours come first as sensible defaults.
  try {
    spawnSync("claude", [
      "--mcp-config", mcpConfigPath,
      "--dangerously-load-development-channels", `server:${SERVER_NAME}`,
      "--dangerously-skip-permissions",
      ...(skillPath ? [`--append-system-prompt-file=${skillPath}`] : []),
      ...passthroughArgs,
    ], {
      cwd: absCwd,
      stdio: "inherit",
      shell: false,
    });
  } finally {
    // Session over — drop the ephemeral config so it never lingers as a stray
    // file. spawnSync blocks until claude exits, so claude has long since read
    // it. Best-effort: ignore if already gone.
    try { unlinkSync(mcpConfigPath); } catch { /* already removed */ }
  }
}
