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
 * EVERY import here is `import type`: the object's initializers are all null /
 * zero / empty, so this module has no runtime dependencies and cannot form an
 * import cycle.
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
import type { Ed25519Keypair } from "./pairing/crypto.js";
import type { QueuedMessageItem, ThinkingLevel, WireGitStatus } from "./protocol/types.js";

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
    git?: WireGitStatus | null;
    context_usage?: WireContextUsage | null;
  } | null;
  currentModel: string | undefined;
  currentThinking: ThinkingLevel | undefined;
  pendingModelRevert: FullSdkModel | null;
  sessionStartedAt: number | null;
  /** Plan/137 — the two OR-ed sources behind `myRoomMeta.waiting_for_input`:
   *  the SDK's `ui_prompt_start/end` signal (plan/134, any blocking ctx.ui
   *  prompt) and the ask-bridge's active-flow signal (fallback for pis that
   *  don't emit the events). Kept as separate booleans so one source's
   * falling edge can't clear a still-open prompt from the other source. */
  waitingSdkInput: boolean;
  waitingBridgeFlow: boolean;

  // mesh
  meshNode: MeshNode | null;
  sessionName: string | null;
  sessionPeerCount: number;
  meshJoinGeneration: number;
  pendingMeshMessages: MeshEnvelope[];
  meshDrainScheduled: boolean;

  // lifecycle flags
  disposed: boolean;
  autoInited: boolean;
  hasGlobalPairings: boolean;

  // agent run / turn
  agentRunActive: boolean;
  agentRunGeneration: number;
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
  waitingSdkInput: false,
  waitingBridgeFlow: false,

  // mesh
  meshNode: null,
  sessionName: null,
  sessionPeerCount: 0,
  meshJoinGeneration: 0,
  pendingMeshMessages: [],
  meshDrainScheduled: false,

  // lifecycle flags
  disposed: false,
  autoInited: false,
  hasGlobalPairings: false,

  // agent run / turn
  agentRunActive: false,
  agentRunGeneration: 0,
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
    relayLifecycleGeneration: 0,
    rootLifecycleGeneration: 0,
    cmdRootInFlight: null,
    myRoomId: null,
    myRoomMeta: null,
    currentModel: undefined,
    currentThinking: undefined,
    pendingModelRevert: null,
    sessionStartedAt: null,
    waitingSdkInput: false,
    waitingBridgeFlow: false,
    meshNode: null,
    sessionName: null,
    sessionPeerCount: 0,
    meshJoinGeneration: 0,
    pendingMeshMessages: [],
    meshDrainScheduled: false,
    disposed: false,
    autoInited: false,
    hasGlobalPairings: false,
    agentRunActive: false,
    agentRunGeneration: 0,
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
