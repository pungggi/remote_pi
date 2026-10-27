/**
 * The single source of truth for the remote-pi extension's mutable runtime
 * state.
 *
 * Historically `src/index.ts` held ~48 module-level `let _foo` singletons
 * scattered across 6000+ lines. That made the file un-splittable: every
 * helper read/wrote those singletons directly, so no cohesive block could
 * move to its own module without losing access to the state it needs.
 *
 * Consolidating them into one exported `ext` object is the foundation that
 * unblocks the domain split (images, commands, lifecycle, …). Any module can
 * now `import { ext }` and reach the live state. Property mutation
 * (`ext.relay = x`) is legal on an imported `const` object — unlike
 * reassigning an imported binding — which is why this is an object, not a set
 * of `export let`.
 *
 * Imports are type-only except the lightweight MeshDeliveryRegistry. That
 * class has no SDK/runtime imports; its back-reference here is type-only, so
 * the lazy boundary stays acyclic at runtime.
 *
 * Field names drop the historical `_` prefix — they are the public properties
 * of the state object, not "private helpers" of a monolith. The state-machine
 * value keeps the name `state` (`ext.state`), matching the codebase vocabulary
 * ("idle → started").
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { RelayClient } from "./transport/relay_client.js";
import type { PlainPeerChannel } from "./transport/peer_channel.js";
import type { MeshNode } from "./session/mesh_node.js";
import type { SelfRevoke } from "./mesh/self_revoke.js";
import type { MeshTopologySnapshot } from "./mesh/siblings.js";
import type { AcquiredLock } from "./session/cwd_lock.js";
import type { FileIndex } from "./session/file_index.js";
import type { ExtensionUiBridge } from "./extension_ui_bridge.js";
import { MeshDeliveryRegistry } from "./session/mesh_delivery.js";
import type { Ed25519Keypair } from "./pairing/crypto.js";
import type { JournaledFrame, QueuedMessageItem, ThinkingLevel, WireGhRef, WireGitStatus, WireSessionStats } from "./protocol/types.js";

// ── Shared light constants (plan/143: live here so BOTH the thin entry and
//    the lazy runtime can import them without pulling heavy modules) ──

/** Sentinel prefix for a transparent control message an RPC client sends on the
 *  `prompt` channel (stdin). The `input` hook intercepts it, runs the action,
 *  and swallows it (`action:"handled"`) so it never becomes an LLM turn or
 *  transcript entry. Starts with NUL so it can't collide with real user input
 *  and doesn't begin with "/" (which would route to the command parser). */
export const CTRL_PREFIX = "\x00remote-pi-ctrl:";

// ── State-shape types (moved here from index.ts — they describe state contents) ─

export type RemoteState = "idle" | "started";

/** Relay connectivity as seen by an RPC client (Cockpit). Derived from
 *  `ext.state` + `ext.relay`. */
export type RelayConnectivity = "connected" | "reconnecting" | "disconnected";

/** Context-window fill published as `room_meta.context_usage`. */
export type WireContextUsage = { tokens: number | null; contextWindow: number; percent: number | null };

/** The SDK's full Model shape (what `ExtensionAPI.setModel` expects). */
export type FullSdkModel = Parameters<ExtensionAPI["setModel"]>[0];

export type ReceivedImageDetails = {
  messageId: string;
  index: number;
  mime: string;
  size?: number;
  path?: string;
  previewPath?: string;
  text?: string;
  error?: string;
  reason?: string;
};

/** Inbound message shape accumulated for session_sync replay. `role` is a
 *  widened union (the SDK emits a handful of literal roles plus free-form
 *  strings), and every field but `role` is optional. Mirrors the shape the
 *  `message_end` hook pushes verbatim. */
export type BufferMsg = {
  role: "user" | "assistant" | "toolResult" | string;
  content?: unknown;
  timestamp?: number;
  toolCallId?: string;
  toolName?: string;
  isError?: boolean;
  usage?: { input?: number; output?: number };
  /** Plan/32: pre-compaction token count, set on the synthetic
   *  `role:"compaction"` marker pushed in `session_compact`. */
  tokensBefore?: number;
};

export type PendingSteer = { id: string; text: string };

/** Plan/127 — a follow-up user_message held until the running turn ends.
 *  Echoed to owners immediately (a committed follow-up bubble); its turn is
 *  started by `_maybeDrainFollowUp` on turn_end, which sets currentTurnId to
 *  its id so the streaming chunks attribute correctly. */
export type PendingFollowUp = { id: string; text: string };

export type AndroidQueuedItem = QueuedMessageItem & { editable: true };

export type MeshEnvelope = { id: string; from: string; re: string | null; body: unknown };

// ── The state object ──────────────────────────────────────────────────────────

export interface ExtensionState {
  // connection / state machine
  state: RemoteState;
  relay: RelayClient | null;
  lastRelayStatus: RelayConnectivity | null;
  relayUrl: string | null;
  peerShort: string;                 // shortid of the most recently attached peer (UX hint)
  activePeers: Map<string, PlainPeerChannel>;
  reconnectTimer: ReturnType<typeof setTimeout> | null;
  reconnectAttempt: number;
  /** Upstream #128 — background retry for a FAILED INITIAL `relay.connect()`.
   *  Distinct from `reconnectTimer`, which only engages (via `_onRelayClose`)
   *  once a connection was established; a first-connect failure never reaches
   *  `state === "started"`, so without this nothing retries and a daemon
   *  whose boot raced DNS stays offline until a manual restart. */
  initialConnectRetryTimer: ReturnType<typeof setTimeout> | null;
  initialConnectRetryAttempt: number;
  /** Delay before the one-shot owner-presence re-subscribe (the relay may
   *  not have propagated a freshly paired owner's blob yet). Test-shrinkable
   *  via `_setPresenceResubscribeMsForTest` in the entry. */
  presenceResubscribeMs: number;
  relayLifecycleGeneration: number;
  rootLifecycleGeneration: number;
  cmdRootInFlight: Promise<void> | null;

  // room / model / context meta
  myRoomId: string | null;
  myRoomMeta: {
    name: string;
    cwd: string;
    model?: string;
    thinking?: ThinkingLevel;
    working?: boolean;
    /** Plan/134 — true while a blocking user-facing ctx.ui prompt (any
     *  extension's confirm/select/input/editor/custom) is open. Independent
     *  of `working`: the turn is still open while the prompt blocks. */
    waiting_for_input?: boolean;
    /** Latest LLM turn failed at the provider (rate limit, API error, etc.).
     *  Cleared when a new turn/session starts; surfaced red on Home. */
    provider_error?: boolean;
    git?: WireGitStatus | null;
    context_usage?: WireContextUsage | null;
    /** Plan/149 — GitHub ref linked to this session (manual/gh-sourced).
     *  Mirrors the rooms-registry entry; pushed at change time. */
    gh_ref?: WireGhRef | null;
    /** Plan/149 — chat-scan suggestion (source "chat"). Ephemeral: never
     *  persisted to the registry, only carried in room_meta so the app can
     *  offer a one-tap link. */
    gh_suggestion?: WireGhRef | null;
    /** Plan/149 — activity counters, pushed ONLY at turn boundaries. */
    stats?: WireSessionStats | null;
  } | null;
  currentModel: string | undefined;
  currentThinking: ThinkingLevel | undefined;
  pendingModelRevert: FullSdkModel | null;
  sessionStartedAt: number | null;
  /** Plan/152 — SDK session ID persisted in the room registry for exact
   *  terminal resume after the process goes offline. */
  piSessionId: string | null;
  /** Plan/137 — the two OR-ed sources behind `myRoomMeta.waiting_for_input`:
   *  the SDK's `ui_prompt_start/end` signal (plan/134, any blocking ctx.ui
   *  prompt) and the ask-bridge's active-flow signal (fallback for pis that
   *  don't emit the events). Kept as separate booleans so one source's
   * falling edge can't clear a still-open prompt from the other source. */
  waitingSdkInput: boolean;
  waitingBridgeFlow: boolean;

  // Plan/145 — delivery ledger. `roomSeq` is the seq of the last stamped
  // broadcast (0 = none yet); `roomJournal` is a bounded ring of the most
  // recent stamped frames, replayed on demand when an app reports itself
  // behind (`report_seq`). The epoch IS `sessionStartedAt` — both fields
  // share its lifecycle (preserved across stop/start cycles, reset when the
  // epoch is restamped: `_resetSessionForNew`, `resetExtensionState`).
  roomSeq: number;
  roomJournal: JournaledFrame[];
  /** Plan/149 — running session-slot counters (cumulative per room, seeded
   *  from the rooms registry at relay connect so a `pi --continue` resumes
   *  the totals). Pushed ONLY at turn boundaries — never per message. */
  statsTurns: number;
  statsUserMsgs: number;

  // mesh
  meshNode: MeshNode | null;
  sessionName: string | null;
  sessionPeerCount: number;
  meshJoinGeneration: number;
  /** Per-pi delivery state plus the owner whose MeshNode receives envelopes. */
  meshDelivery: MeshDeliveryRegistry;

  // lifecycle flags
  disposed: boolean;
  autoInited: boolean;
  hasGlobalPairings: boolean;

  // agent run / turn
  agentRunActive: boolean;
  agentRunGeneration: number;
  /** Replayable text of the in-flight agent run (plan/143: moved from main's
   *  module scope so the thin entry's inline `message_update` path can
   *  accumulate it without loading the runtime). */
  turnText: string;
  turnTextTurn: string | null;
  currentTurnId: string | null;
  messageBuffer: BufferMsg[];
  /** Plan/128 — cached durable `.jsonl` index (metadata only); the volatile
   *  in-RAM tail stays in `messageBuffer`. Null until first `session_sync`. */
  historyIndex: FileIndex | null;
  pendingSteers: PendingSteer[];
  lastConsumedSteerText: string | null;
  queuedItems: AndroidQueuedItem[];
  pendingFollowUps: PendingFollowUp[];

  // pi api + bridges
  pi: ExtensionAPI | null;
  extensionUiBridge: ExtensionUiBridge | null;
  stopAutoListener: (() => void) | null;

  // identity / self-revoke
  cachedEd25519: Ed25519Keypair | null;
  selfRevoke: SelfRevoke | null;
  selfRevokeEpoch: number;
  selfRevokeTopologyReadyEpoch: number;
  selfRevokeTopology: MeshTopologySnapshot | null;

  // cwd lock
  cwdLock: AcquiredLock | null;
  lockedName: string | null;

  // git status polling
  gitRefreshTimer: ReturnType<typeof setInterval> | null;
  lastGitStatus: WireGitStatus | null | undefined;

  // captured contexts (refreshed by session_start / each command)
  lastCtx: Pick<ExtensionContext, "ui" | "abort" | "cwd"> | null;
  lastEventCtx: Pick<ExtensionContext, "compact" | "abort" | "ui" | "getContextUsage"> | null;

  // received-image preview pipeline (mutable accumulator)
  imageCacheDir: string | undefined;
  pendingReceivedImagePreviews: ReceivedImageDetails[];
}

export const ext: ExtensionState = {
  // connection / state machine
  state: "idle",
  relay: null,
  lastRelayStatus: null,
  relayUrl: null,
  peerShort: "",
  activePeers: new Map<string, PlainPeerChannel>(),
  reconnectTimer: null,
  reconnectAttempt: 0,
  initialConnectRetryTimer: null,
  initialConnectRetryAttempt: 0,
  presenceResubscribeMs: 10_000,
  relayLifecycleGeneration: 0,
  rootLifecycleGeneration: 0,
  cmdRootInFlight: null,

  // room / model / context meta
  myRoomId: null,
  myRoomMeta: null,
  currentModel: undefined,
  currentThinking: undefined,
  pendingModelRevert: null,
  sessionStartedAt: null,
  piSessionId: null,
  waitingSdkInput: false,
  waitingBridgeFlow: false,
  roomSeq: 0,
  roomJournal: [],
  /** Plan/149 — running session-slot counters (cumulative per room, seeded
   *  from the rooms registry at relay connect so a `pi --continue` resumes
   *  the totals). Pushed ONLY at turn boundaries — never per message. */
  statsTurns: 0,
  statsUserMsgs: 0,

  // mesh
  meshNode: null,
  sessionName: null,
  sessionPeerCount: 0,
  meshJoinGeneration: 0,
  meshDelivery: new MeshDeliveryRegistry(),

  // lifecycle flags
  disposed: false,
  autoInited: false,
  hasGlobalPairings: false,

  // agent run / turn
  agentRunActive: false,
  agentRunGeneration: 0,
  turnText: "",
  turnTextTurn: null,
  currentTurnId: null,
  messageBuffer: [],
  historyIndex: null,
  pendingSteers: [],
  lastConsumedSteerText: null,
  queuedItems: [],
  pendingFollowUps: [],

  // pi api + bridges
  pi: null,
  extensionUiBridge: null,
  stopAutoListener: null,

  // identity / self-revoke
  cachedEd25519: null,
  selfRevoke: null,
  selfRevokeEpoch: 0,
  selfRevokeTopologyReadyEpoch: -1,
  selfRevokeTopology: null,

  // cwd lock
  cwdLock: null,
  lockedName: null,

  // git status polling
  gitRefreshTimer: null,
  lastGitStatus: undefined,

  // captured contexts
  lastCtx: null,
  lastEventCtx: null,

  // received-image preview pipeline
  imageCacheDir: undefined,
  pendingReceivedImagePreviews: [],
};

/**
 * Reset every field to its initial value. Useful for test isolation and for
 * the `session_shutdown` teardown path. Mutates `ext` in place so all importers
 * see the reset.
 */
export function resetExtensionState(): void {
  // Invalidate queued delivery callbacks before resetting their generations.
  ext.meshDelivery.disposeAll();
  // A reset must not orphan live timers: nulling the field without
  // clearTimeout leaves a scheduled callback that could fire against the
  // zeroed generations (upstream #128 hardening — `_scheduleInitialConnectRetry`
  // re-checks the captured generation, and clearing here closes the collision
  // window where a post-reset `++relayLifecycleGeneration` re-issues a value a
  // stale timer still holds).
  if (ext.reconnectTimer !== null) clearTimeout(ext.reconnectTimer);
  if (ext.initialConnectRetryTimer !== null) clearTimeout(ext.initialConnectRetryTimer);
  Object.assign(ext, {
    state: "idle",
    relay: null,
    lastRelayStatus: null,
    relayUrl: null,
    peerShort: "",
    activePeers: new Map<string, PlainPeerChannel>(),
    reconnectTimer: null,
    reconnectAttempt: 0,
    initialConnectRetryTimer: null,
    initialConnectRetryAttempt: 0,
    // Preserved across resets (was a module-level let before plan/143): tests
    // shrink it via _setPresenceResubscribeMsForTest and expect it to stick.
    presenceResubscribeMs: ext.presenceResubscribeMs,
    relayLifecycleGeneration: 0,
    rootLifecycleGeneration: 0,
    cmdRootInFlight: null,
    myRoomId: null,
    myRoomMeta: null,
    currentModel: undefined,
    currentThinking: undefined,
    pendingModelRevert: null,
    sessionStartedAt: null,
    piSessionId: null,
    waitingSdkInput: false,
    waitingBridgeFlow: false,
    roomSeq: 0,
    roomJournal: [],
    // Plan/149 — counters reset with the room lifecycle (a reset re-seeds
    // from the registry at the next relay connect).
    statsTurns: 0,
    statsUserMsgs: 0,
    meshNode: null,
    sessionName: null,
    sessionPeerCount: 0,
    meshJoinGeneration: 0,
    meshDelivery: ext.meshDelivery,
    disposed: false,
    autoInited: false,
    hasGlobalPairings: false,
    agentRunActive: false,
    agentRunGeneration: 0,
    turnText: "",
    turnTextTurn: null,
    currentTurnId: null,
    messageBuffer: [],
    historyIndex: null,
    pendingSteers: [],
    lastConsumedSteerText: null,
    queuedItems: [],
    pendingFollowUps: [],
    pi: null,
    extensionUiBridge: null,
    stopAutoListener: null,
    cachedEd25519: null,
    selfRevoke: null,
    selfRevokeEpoch: 0,
    selfRevokeTopologyReadyEpoch: -1,
    selfRevokeTopology: null,
    cwdLock: null,
    lockedName: null,
    gitRefreshTimer: null,
    lastGitStatus: undefined,
    lastCtx: null,
    lastEventCtx: null,
    imageCacheDir: undefined,
    pendingReceivedImagePreviews: [],
  } satisfies ExtensionState);
}
