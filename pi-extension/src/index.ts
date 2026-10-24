#!/usr/bin/env node
/**
 * pi-extension — remote-pi THIN ENTRY (plan/143, issue #61)
 *
 * Exported as ExtensionFactory (default export) to be loaded by Pi SDK:
 *   pi -e $(pwd)/dist/index.js
 *
 * Pi loads extensions sequentially and awaits each factory, so every
 * millisecond of module-level imports here is added to pi STARTUP. This file
 * therefore keeps a near-zero static footprint:
 *
 *   - Static imports: extension-state (zero-dep state object), session/tools
 *     (hand-written JSON Schema literals — NOT typebox, which costs ~0.5 s
 *     and is unnecessary because pi validates plain JSON Schema natively),
 *     session/global_config + session/local_config (node builtins only),
 *     images/pipeline (node builtins; its one SDK value import is dynamic),
 *     images/render (~0.1 s pi-tui — the TUI renderer registration).
 *   - Everything else (ws, qrcode-terminal, @noble/ed25519, the pi-coding-agent
 *     SDK, ~45 internal modules) lives in ./main.js and is dynamic-imported at
 *     use sites: command handlers, heavy event-hook halves, test hooks, CLI
 *     bootstrap.
 *
 * What MUST stay synchronous here (SDK contracts):
 *   - `resources_discover` / `context` handlers return values synchronously.
 *   - `input` returns `{ action: "handled" }` for CTRL_PREFIX control lines.
 *   - `session_before_compact` mutates `event.preparation` synchronously.
 *   - `session_start` runs the cheap auto-start gate inline (daemon /
 *     print-mode / cwd / local-config check) so sessions without auto-start
 *     never load the runtime at all.
 *
 * Forwarding model: `fwd()` runs the runtime call SYNCHRONOUSLY once the
 * runtime is loaded (cached module reference), so timing matches the old
 * monolith. Until the first load, low-activity event handlers take INLINE
 * ext-write paths (see `runtimeIdle()` + the mirror block below) — an
 * interactive session without auto-start, or a one-shot `pi -p` run, then
 * never pays the runtime's ~2 s import at all. Tests (and the CLI) can force
 * the cache with `_preloadRuntimeForTest()`.
 *
 * The runtime itself (state machine, pairing, relay, mesh) is unchanged —
 * see ./main.ts for the handler bodies that the forwarders below invoke.
 */

import { ext, CTRL_PREFIX } from "./extension-state.js";
export type { RemoteState, RelayConnectivity } from "./extension-state.js";
import type { BufferMsg, ExtensionState } from "./extension-state.js";
import { registerAgentTools } from "./session/tools.js";
import { ensureGlobalDirs, skillsDir } from "./session/global_config.js";
import { effectiveAutoStartRelay, loadLocalConfig, localConfigExists } from "./session/local_config.js";
import {
  filterReceivedImageMessagesFromContext,
  flushPendingReceivedImagePreviews,
  registerShowFileTool,
  registerShowImageTool,
  type ImagePipelineDeps,
} from "./images/pipeline.js";
import { registerReceivedImageRenderer } from "./images/render.js";
import { createExtensionUiBridge } from "./extension_ui_bridge.js";
import type { ServerMessage } from "./protocol/types.js";
import { copyFileSync, existsSync, mkdirSync, realpathSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionFactory } from "@earendil-works/pi-coding-agent";

export { CTRL_PREFIX };

// ── Lazy runtime handle ──────────────────────────────────────────────────────

type MainModule = typeof import("./main.js");

/** Cached runtime namespace once the first dynamic import resolved. Null
 *  until then — every forwarder checks it for a synchronous fast path. */
let mainLoaded: MainModule | null = null;

const _main = (): Promise<MainModule> => import("./main.js");

/** Await the runtime (cached after the first call). */
async function getMain(): Promise<MainModule> {
  if (!mainLoaded) mainLoaded = await _main();
  return mainLoaded;
}

/** Fire-and-forget forward with a synchronous fast path. Until the runtime
 *  has loaded once, the call queues behind the dynamic import (Node caches
 *  the module, so ordering is preserved); afterwards it runs synchronously,
 *  matching the old monolith's timing. */
function fwd(fn: (m: MainModule) => void): void {
  const m = mainLoaded;
  if (m) {
    fn(m);
    return;
  }
  void _main()
    .then((loaded) => {
      mainLoaded = loaded;
      fn(loaded);
    })
    .catch((err) => {
      // PR #62 review: never let a deferred forward kill the host process —
      // an import failure or a throwing handler would otherwise surface as an
      // unhandled rejection (the monolith's sync handlers propagated to pi's
      // event runner instead). Log and keep pi alive.
      console.error("[remote-pi] runtime forward failed:", err);
    });
}

/** Force-load the runtime NOW (tests + CLI). After this resolves, every
 *  forwarder runs synchronously — test assertions behave exactly as they did
 *  against the old monolith entry. */
export async function _preloadRuntimeForTest(): Promise<MainModule> {
  return getMain();
}

// ── Light helpers (kept in the entry: zero heavy dependencies) ───────────────

/**
 * Issue #105 — pure-data events must not reach the model.
 *
 * `display: false` only suppresses TUI rendering. Pi still persists the message
 * as a `CustomMessageEntry`, and those DO participate in LLM context, so every
 * relay flap / name collision / pairing was being replayed to the model on
 * every subsequent call ("Relay connected", "Mesh name reassigned: …"). The
 * agent burned tokens on internal telemetry and sometimes reasoned about it as
 * if it were user input.
 *
 * The filter is non-destructive: the entries stay in the session (Cockpit and
 * any other RPC client still read them off the stream), the LLM just never sees
 * them. Keyed on `display === false` rather than a customType allowlist, so any
 * pure-data event we add later is covered by construction. Events meant for the
 * human (`remote-pi:mesh-message`, `remote-pi:mesh-revoked`, …) set
 * `display: true` and pass through untouched.
 *
 * Senders of filtered messages must pass `{ triggerTurn: false }`. Without it,
 * pi steers a message sent mid-stream into the running turn and makes another
 * LLM call; this filter then strips the message, so the request ends with an
 * assistant message and models without prefill support reject it with a 400.
 */
function _isPureDataContextMessage(message: unknown): boolean {
  if (typeof message !== "object" || message === null) return false;
  const m = message as { role?: unknown; customType?: unknown; display?: unknown };
  return m.role === "custom"
    && typeof m.customType === "string"
    && m.customType.startsWith("remote-pi:")
    && m.display === false;
}

function _filterInternalMessagesFromContext<T>(messages: T[] | undefined): T[] {
  // Compose the modular pipeline's received-image filter (images/pipeline.ts)
  // with the #105 pure-data filter — one pass, both concerns.
  return filterReceivedImageMessagesFromContext(messages).filter(
    (message) => !_isPureDataContextMessage(message),
  );
}

function _isDirectRun(): boolean {
  try {
    return fileURLToPath(import.meta.url) === realpathSync(process.argv[1] ?? "");
  } catch {
    return false;
  }
}

// ── Inline light mirrors of runtime helpers (plan/143) ─────────────────────
// Every function below touches only `ext` + node builtins. Each one mirrors
// the cheap prefix of the matching main.ts handler so a low-activity session
// (no relay, no mesh, no peers — e.g. a `pi -p` one-shot or an interactive pi
// before the first /remote-pi) never triggers the runtime import at all.
//
// Fidelity rule: a mirror may run only when the heavy halves it skips are
// provably no-ops. Relay/mesh handles and owner peers can only be created BY
// the runtime, so `runtimeIdle()` true implies they are all null/empty; the
// skipped halves are guarded by exactly those handles in main.ts too. Once
// the runtime is loaded we forward instead (see each handler), so the
// mirrors never race the real handlers on an active session.

/** True when nothing the runtime owns exists. Conservative: any live handle
 *  (or a non-idle state) means the runtime has work to do, so we forward. */
const runtimeIdle = (): boolean =>
  ext.state === "idle" &&
  ext.relay === null &&
  ext.meshNode === null &&
  ext.activePeers.size === 0 &&
  ext.cwdLock === null;

/** Mirror of main.ts's `_publishWaitingForUser`: ext writes + the ext.pi
 *  custom-message transition (valid runtime-free — pi is bound at factory).
 *  The relay publish is skipped by construction (relay is null here). */
function publishWaitingForUserInline(waiting: boolean, kind?: string, title?: string): void {
  const prev = ext.myRoomMeta?.waiting_for_input ?? false;
  if (waiting) {
    console.log(`[remote-pi] ui_prompt_start (kind=${kind ?? "?"}${title ? `, title=${JSON.stringify(title)}` : ""}) — publishing waiting_for_input=true`);
  }
  if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, waiting_for_input: waiting };
  if (waiting !== prev) {
    try {
      ext.pi?.sendMessage({
        customType: "remote-pi:ui-prompt",
        content: waiting
          ? `Waiting for your input${title ? ` (${title})` : ""}`
          : "Prompt answered",
        details: {
          waiting,
          ...(kind ? { kind } : {}),
          ...(title ? { title } : {}),
        },
        display: false,
      }, { triggerTurn: false });
    } catch {
      // ext.pi stale (session replaced) or runtime not yet bound — same
      // discipline as main.ts: swallow, the next transition re-emits.
    }
  }
}

/** Bridge broadcast trampoline: bridge flows only ever broadcast to attached
 *  owners, and attaching an owner goes through the runtime — so by the time a
 *  broadcast is meaningful the forward runs synchronously. */
const bridgeBroadcast = (msg: ServerMessage): void => {
  fwd((m) => { m._broadcastToActive(msg); });
};

/** Bridge hook: runs at factory time (inline bridge creation) but must hit
 *  the RUNTIME's `_setWaitingBridgeFlow` once loaded — the relay-side publish
 *  of `waiting_for_input` requires main's relay wiring. Pre-load (no relay
 *  possible) the inline mirror below is the complete behavior. */
function setWaitingBridgeFlowInline(active: boolean): void {
  const m = mainLoaded;
  if (m) { m._setWaitingBridgeFlow(active); return; }
  ext.waitingBridgeFlow = active;
  publishWaitingForUserInline(ext.waitingSdkInput || ext.waitingBridgeFlow, "ask_flow");
}

/** Mirror of main.ts's `_recreateExtensionUiBridge`, created inline because
 *  extension_ui_bridge.ts is light (type-only imports). */
function recreateBridgeInline(pi: ExtensionAPI): void {
  ext.extensionUiBridge?.dispose();
  ext.waitingBridgeFlow = false;
  ext.extensionUiBridge = createExtensionUiBridge(pi, bridgeBroadcast, {
    onActiveFlowsChanged: (active) => setWaitingBridgeFlowInline(active),
  });
}

/** Mirror of main.ts's `_deployAgentNetworkSkill` + `_resolveExtensionDir` —
 *  node:fs only. index.ts/main.ts share the same directory (dist/ or src/),
 *  so the resolution logic is identical in both. */
function deployAgentNetworkSkillInline(): void {
  const here = fileURLToPath(import.meta.url);
  const parent = here.replace(/\/[^/]+$/, "");
  const candidateA = join(parent, "..", "skills"); // dist → ../skills
  const candidateB = join(parent, "skills");        // src → skills
  const root = existsSync(candidateA)
    ? parent.replace(/\/dist$/, "")
    : parent;
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

// ── Light test accessors (read/write `ext` only — no runtime import needed) ──

export function _getDisposedForTest(): boolean { return ext.disposed; }
export function _setDisposedForTest(v: boolean): void { ext.disposed = v; }
export function _resetAutoInitedForTest(): void { ext.autoInited = false; }
export function _setAutoInitedForTest(value: boolean): void { ext.autoInited = value; }
export function _hasMeshNodeForTest(): boolean { return ext.meshNode !== null; }
export function _getLockedNameForTest(): string | null { return ext.lockedName; }

/** Test-only: release + clear the cwd lock (the lock normally survives stop). */
export function _resetCwdLockForTest(): void {
  try { ext.cwdLock?.release(); } catch { /* ignored */ }
  ext.cwdLock = null;
  ext.lockedName = null;
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
export function _resetHistoryIndexForTest(): void { ext.historyIndex = null; }

/** Test-only override of session started timestamp. */
export function _setSessionStartedAtForTest(ts: number | null): void { ext.sessionStartedAt = ts; }

/** Test-only: reset the cached model name (between tests). */
export function _setCurrentModelForTest(name: string | undefined): void { ext.currentModel = name; }

/** Test-only: read the active turn id used for plain `cancel` routing. */
export function _getCurrentTurnIdForTest(): string | null { return ext.currentTurnId; }

/** Test-only: seeds ext.currentTurnId (normally set by the user_message
 *  routing path) so cleanup-on-last-owner-offline can be asserted directly. */
export function _setCurrentTurnIdForTest(v: string | null): void { ext.currentTurnId = v; }

/** Test-only override of the bound AgentSession so a spy can capture the
 *  content handed to `sendUserMessage` (plan/30 multimodal ingest). */
export function _setPiForTest(pi: unknown): void {
  ext.pi = pi as typeof ext.pi;
}

/** Test-only: exposes pending reconnect timer state. */
export function _hasPendingReconnect(): boolean { return ext.reconnectTimer !== null; }

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
export function _getActivePeerCountForTest(): number { return ext.activePeers.size; }

export function _getRoomMetaForTest(): ExtensionState["myRoomMeta"] { return ext.myRoomMeta; }

/** Test-only: true if a specific peer (base64 std) has an attached channel. */
export function _hasActivePeerForTest(appPeerIdStd: string): boolean { return ext.activePeers.has(appPeerIdStd); }

/**
 * Test-only (plan/137, PR #59 review #2): the bridge-flow half of the merged
 * `waiting_for_input` flag. Lets tests prove the `session_start` rebind kept
 * the `onActiveFlowsChanged` hook wired — the flag flipping on a `started`
 * event is the observable of that wiring, no relay needed.
 */
export function _getWaitingBridgeFlowForTest(): boolean { return ext.waitingBridgeFlow; }

/** Test-only: shrink the owner-presence re-subscribe delay so tests don't
 *  wait 10s (stored on `ext` so the lazy runtime sees the same value). */
export function _setPresenceResubscribeMsForTest(ms: number): void { ext.presenceResubscribeMs = ms; }

// ── Heavy test hooks / runtime exports (async forwarders, signatures kept) ───

export function _connectForTest(ctx: unknown): Promise<void> { return getMain().then((m) => m._connectForTest(ctx)); }
export function _stopForTest(ctx: unknown): Promise<void> { return getMain().then((m) => m._stopForTest(ctx)); }
export function _checkSelfRevokeForTest(): Promise<void> { return getMain().then((m) => m._checkSelfRevokeForTest()); }
export function _startRelayForTest(ctx: unknown): Promise<void> { return getMain().then((m) => m._startRelayForTest(ctx)); }
export function _handleControl(cmd: string): Promise<void> { return getMain().then((m) => m._handleControl(cmd)); }
export function probeListPeers(sockPath: string, timeoutMs?: number): Promise<string[] | null> {
  return getMain().then((m) => m.probeListPeers(sockPath, timeoutMs));
}

// ── Factory ──────────────────────────────────────────────────────────────────

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

  // Plano 19: ensure ~/.pi/piper/{sessions,skills}/ exist — pure node:fs, so
  // it runs inline. The rest of the factory preamble (pi-ask bridge rebind,
  // agent-network skill deploy) is light too and runs inline here; only the
  // global-pairings cache seed defers to the runtime's first load (main.ts
  // top level) because the pairing chain is heavy and the footer dots it
  // feeds only render once a session/relay UI exists — via the runtime.
  try {
    ensureGlobalDirs();
  } catch { /* best-effort init */ }
  recreateBridgeInline(pi);
  try {
    deployAgentNetworkSkillInline();
  } catch { /* best-effort init */ }

  pi.on("resources_discover", () => ({ skillPaths: [skillsDir()] }));

  // Plano 20: agent_send + agent_request tools so the LLM can drive the
  // session network natively. Getter captures `ext.meshNode` live so the
  // tool always sees the current state. The tool module is thin (plain JSON
  // Schema literals + type-only imports — no typebox), so it stays static.
  registerAgentTools(pi, () => ext.meshNode?.peer() ?? null);

  // Inject the two cross-cutting concerns the image pipeline needs from the
  // host (broadcasting to owners + "any peer active?") so the pipeline module
  // has no back-dependency on the runtime (avoids an import cycle). The
  // pipeline module is light (node builtins; the SDK conversion import inside
  // it is dynamic); the broadcast callback trampolines into the lazy runtime —
  // by the time a tool broadcasts to an attached owner, the runtime is loaded
  // (attaching an owner goes through it).
  const imageDeps: ImagePipelineDeps = {
    broadcast: (msg) => { fwd((m) => { m._broadcastToActive(msg); }); },
    anyPeerActive: () => ext.activePeers.size > 0,
  };
  registerShowImageTool(pi, imageDeps);
  registerShowFileTool(pi, imageDeps);
  registerReceivedImageRenderer(pi);

  // Received-image preview entries are for local TUI display only. Pi's custom
  // messages normally become user-role LLM context, so strip this type before
  // every provider request; the actual Android image still reaches the model via
  // the paired sendUserMessage call. Inline: the filter is light AND the SDK
  // requires the return value synchronously.
  pi.on("context", (event) => ({
    messages: _filterInternalMessagesFromContext(event.messages),
  }));

  // Tool calls execute without prompting the remote user. The Pi SDK has no
  // native `requiresApproval` per tool, and a hardcoded gate (Bash/Edit/Write)
  // misfired on every custom tool from third-party packages. Approval will
  // come back when the Pi ecosystem ships a permissions convention. tool_result
  // is still forwarded so the app shows tool activity transparently.

  // Mirror input typed in the Pi terminal (or sent via RPC) to every
  // connected owner. 'extension' source is our own sendUserMessage call
  // from routeClientMessage, which already set ext.currentTurnId — skip to
  // avoid a double turnId. The CTRL_PREFIX fast path is inline because the
  // `{ action: "handled" }` swallow must return synchronously. The rest of
  // the handler (main.onInputRest) is a no-op without attached peers, so it
  // only forwards when peers exist.
  pi.on("input", (event) => {
    if (event.text.startsWith(CTRL_PREFIX)) {
      fwd((m) => { m._handleControl(event.text.slice(CTRL_PREFIX.length).trim()); });
      return { action: "handled" } as const;
    }
    if (ext.activePeers.size > 0) fwd((m) => m.onInputRest(event));
    return undefined;
  });

  // Track active model so the app can show it in the SessionTile (plano 18).
  pi.on("model_select", (event) => {
    if (mainLoaded || !runtimeIdle()) { fwd((m) => m.onModelSelect(event)); return; }
    const m = (event as { model?: unknown } | undefined | null)?.model as { name?: string; id?: string } | undefined;
    const modelName = m?.name ?? m?.id;
    if (!modelName) return;
    // ext-write prefix of main.onModelSelect; its relay publish is impossible
    // on this path (relay is null by construction).
    ext.currentModel = modelName;
    if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, model: modelName };
  });
  // Plan/28 Wave D.1: mirror model's room_meta_update path for thinking level.
  pi.on("thinking_level_select", (event) => {
    if (mainLoaded || !runtimeIdle()) { fwd((m) => m.onThinkingLevelSelect(event)); return; }
    const level = (event as { level?: unknown } | undefined | null)?.level as ExtensionState["currentThinking"];
    if (!level) return;
    ext.currentThinking = level;
    if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, thinking: level };
  });

  pi.on("agent_start", (_event, ctx) => {
    if (mainLoaded || !runtimeIdle()) { fwd((m) => m.onAgentStart(pi, ctx)); return; }
    ext.agentRunActive = true;
    ext.agentRunGeneration += 1;
    ext.turnText = "";      // a fresh run's replayable text starts empty
    ext.turnTextTurn = null; // (and belongs to no turn until the first delta)
  });
  // main.onMessageStart only broadcasts a consumed-steer notice, peers-gated.
  pi.on("message_start", (event) => {
    if (ext.activePeers.size > 0) fwd((m) => m.onMessageStart(event));
  });
  pi.on("message_update", (event) => {
    if (mainLoaded || !runtimeIdle()) { fwd((m) => m.onMessageUpdate(event)); return; }
    const ae = (event as { assistantMessageEvent?: { type?: unknown; delta?: unknown } }).assistantMessageEvent;
    if (ae?.type !== "text_delta") return;
    // No peers/turn id can exist here, so main's buffer path can't fire; what
    // remains is the mid-run-attach replay accumulation (ext.turnText).
    if (ext.agentRunActive) ext.turnText += ae.delta as string;
  });
  // main.onToolExecutionStart/End are peers-gated owner notifications.
  pi.on("tool_execution_start", (event) => {
    if (ext.activePeers.size > 0) fwd((m) => m.onToolExecutionStart(event));
  });
  pi.on("tool_execution_end", (event) => {
    if (ext.activePeers.size > 0) fwd((m) => m.onToolExecutionEnd(event));
  });
  pi.on("message_end", (event) => {
    if (mainLoaded || !runtimeIdle()) { fwd((m) => m.onMessageEnd(event)); return; }
    const m = (event as { message?: unknown }).message as { role?: string; content?: unknown } | undefined;
    if (!m) return;
    // Peers-gated steer/error broadcasts and the relay context_usage publish
    // are impossible here; the cumulative session buffer (session_sync replay
    // once a relay session starts later) is the whole job of this path.
    if (m.role === "user" || m.role === "assistant" || m.role === "toolResult") {
      ext.messageBuffer.push(m as unknown as BufferMsg);
    }
  });
  pi.on("agent_end", (_event, ctx) => {
    if (mainLoaded || !runtimeIdle()) { fwd((m) => m.onAgentEnd(pi, ctx)); return; }
    flushPendingReceivedImagePreviews();  // empty pre-relay — kept for fidelity
    ext.turnText = "";
    ext.turnTextTurn = null;
    ext.lastConsumedSteerText = null;
    // Same deferred busy-flag release as main.onAgentEnd (the generation
    // check protects a queued run started before this timer fires). Queue
    // drains are skipped: app queues can only fill via the relay.
    const endedGeneration = ext.agentRunGeneration;
    setTimeout(() => {
      if (ext.agentRunGeneration !== endedGeneration) return;
      ext.agentRunActive = false;
      if (ext.currentTurnId !== null && ext.currentTurnId.startsWith("resume_")) {
        ext.currentTurnId = null;
      }
    }, 0);
  });
  pi.on("turn_start", (_event, ctx) => {
    if (mainLoaded || !runtimeIdle()) { fwd((m) => m.onTurnStart(ctx)); return; }
    // Late model hydration (same as main.onTurnStart); the room_meta publish
    // and context-usage refresh are relay-gated and impossible here.
    if (!ext.currentModel) {
      try {
        const m = (ctx as { getModel?: () => { name?: string; id?: string } | undefined }).getModel?.();
        const name = m?.name ?? m?.id;
        if (name) {
          ext.currentModel = name;
          if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, model: name };
        }
      } catch { /* defensive — never block a turn on a model lookup */ }
    }
    if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, working: true };
  });
  pi.on("turn_end", () => {
    if (mainLoaded || !runtimeIdle()) { fwd((m) => m.onTurnEnd()); return; }
    if (ext.myRoomMeta) ext.myRoomMeta = { ...ext.myRoomMeta, working: false };
  });
  pi.on("ui_prompt_start", (event) => {
    if (mainLoaded || !runtimeIdle()) { fwd((m) => m.onUiPromptStart(event)); return; }
    const kind = typeof (event as { kind?: unknown })?.kind === "string" ? (event as { kind?: string }).kind : undefined;
    const title = typeof (event as { title?: unknown })?.title === "string" ? (event as { title?: string }).title : undefined;
    ext.waitingSdkInput = true;
    publishWaitingForUserInline(true, kind, title);
  });
  pi.on("ui_prompt_end", () => {
    if (mainLoaded || !runtimeIdle()) { fwd((m) => m.onUiPromptEnd()); return; }
    ext.waitingSdkInput = false;
    publishWaitingForUserInline(false);
  });

  // Plan/32: compaction feedback. The event.preparation filter mutation must
  // complete synchronously (the SDK reads it after the handler returns), so it
  // runs inline; the working=true publication forwards to the runtime.
  pi.on("session_before_compact", (event) => {
    if (event.preparation) {
      event.preparation.messagesToSummarize = _filterInternalMessagesFromContext(
        event.preparation.messagesToSummarize,
      );
      event.preparation.turnPrefixMessages = _filterInternalMessagesFromContext(
        event.preparation.turnPrefixMessages,
      );
    }
    // working=true publication: meta+relay-gated in main, so skip when the
    // runtime has nothing live (compaction without a relay session).
    if (mainLoaded || !runtimeIdle()) fwd((m) => m.onSessionBeforeCompact());
  });

  pi.on("session_compact", (event) => {
    if (mainLoaded || !runtimeIdle()) { fwd((m) => m.onSessionCompact(event)); return; }
    const entry = (event as { compactionEntry?: unknown })?.compactionEntry as { summary?: unknown; tokensBefore?: unknown } | undefined;
    const summary = typeof entry?.summary === "string" ? entry.summary : "";
    const tokensBefore = typeof entry?.tokensBefore === "number" ? entry.tokensBefore : 0;
    // Only the synthetic marker survives pre-runtime: the live broadcast is
    // peers-gated, the working publish is relay-gated, and the app queues can
    // only fill via the relay.
    ext.messageBuffer.push({ role: "compaction", content: summary, timestamp: Date.now(), tokensBefore });
  });

  // Re-capture the freshest base ctx on every session replacement so compact
  // never operates on a stale captured ctx — this is the fix for the
  // "stale after session replacement" crash when the app taps Compact after a
  // New session. Fires on startup/new/fork/reload/resume; the ctx is always
  // bound to the current session. The auto-start gate runs INLINE (it only
  // reads process.env + the local config file) so a session whose cwd has no
  // auto-start config never loads the runtime at all; the heavy half (waiting
  // reset, bridge rebind, disposed re-arm, relay auto-start) forwards.
  pi.on("session_start", (_event, ctx) => {
    ext.lastEventCtx = ctx;
    // Delivery state is light and per-pi. Capture idle even when the heavy
    // runtime correctly stays unloaded for this unconfigured/idle session.
    ext.meshDelivery.for(pi).captureContext(ctx);
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
    // cwd=undefined and skipped auto-start even though the process runs in the
    // configured worktree dir (the session *dir* is still derived from
    // process.cwd(), so the two disagreed). Skipped under vitest so tests
    // with a minimal ctx keep the historical no-autostart behaviour.
    const cwd = isDaemon
      ? process.cwd()
      : "cwd" in ctx
        ? ctx.cwd
        : (process.env.VITEST ? undefined : process.cwd());
    const autoStart =
      !ext.autoInited &&
      !isPrintMode &&
      !!cwd &&
      localConfigExists(cwd) &&
      effectiveAutoStartRelay(loadLocalConfig(cwd));
    // Mark auto-inited synchronously (as the original did inside the gate)
    // so a rapid second session_start can't double-fire.
    if (autoStart) ext.autoInited = true;
    // Bridge rebind for module-reusing hosts (session replacement disposed
    // it) — inline, same condition as main.onSessionStart's. The bridge is
    // light, so this never justifies loading the runtime.
    if (!ext.extensionUiBridge) recreateBridgeInline(pi);
    // Forward to the runtime ONLY when it has real work: relay auto-start, a
    // live runtime owning handles (!runtimeIdle), a disposed-module rearm, or
    // a stale waiting flag to reset+publish. Otherwise this session never
    // pays the runtime import at all (issue #61).
    const needsRuntime =
      autoStart ||
      !runtimeIdle() ||
      ext.disposed ||
      ext.myRoomMeta?.waiting_for_input === true;
    if (needsRuntime) {
      // PR #62 review (race fix): if session_shutdown fires while the runtime
      // import is still resolving, its teardown bumps rootLifecycleGeneration
      // — skip this deferred start, or main.onSessionStart would see
      // ext.disposed, treat it as a module-reuse rearm, and _cmdRoot would
      // re-create mesh/relay on a session that was just shut down. The
      // monolith was synchronous (start always preceded shutdown); the token
      // restores that ordering guarantee for the deferred path. When the
      // runtime is already loaded the forward is synchronous and the token
      // cannot change in between.
      const startToken = ext.rootLifecycleGeneration;
      fwd((m) => {
        if (ext.rootLifecycleGeneration !== startToken) return;
        m.onSessionStart(pi, ctx, autoStart);
      });
    }
  });

  // Tear down THIS instance's live handles when the SDK replaces the session.
  // The SDK AWAITS this handler (`teardownCurrent`) before creating the
  // replacement runtime — hence the returned promise (see main.onSessionShutdown
  // for the full rationale). Sync fast path matters: the synchronous prefix of
  // onSessionShutdown (disposed flag, generation revocation, _goIdle) must run
  // before this handler returns, exactly as it did in the monolith.
  pi.on("session_shutdown", () => {
    // Dispose synchronously: even a deferred runtime import must not allow an
    // outgoing queue to wake after this session has been replaced.
    ext.meshDelivery.dispose(pi);
    const m = mainLoaded;
    if (m) return m.onSessionShutdown(pi);
    if (runtimeIdle()) {
      // Inline teardown (plan/143) — mirrors main.onSessionShutdown's
      // synchronous prefix: disposed flag + generation revocation + bridge
      // dispose + stale-ctx drop. The mesh/cwd-lock tails are no-ops here
      // (both null by construction).
      ext.disposed = true;
      ext.rootLifecycleGeneration += 1;
      ext.relayLifecycleGeneration += 1;
      ext.meshJoinGeneration += 1;
      ext.extensionUiBridge?.dispose();
      ext.extensionUiBridge = null;
      ext.lastCtx = null;
      ext.lastEventCtx = null;
      return Promise.resolve();
    }
    return _main().then((loaded) => { mainLoaded = loaded; return loaded.onSessionShutdown(pi); });
  });

  // ── Commands ──────────────────────────────────────────────────────────────
  //
  // Final surface: 8 commands. Pre-2026-05-23 we had 20 commands covering
  // multi-session UDS + granular relay control; in practice every install
  // converged on one session and the relay was always either fully on or
  // fully off. The simplified surface keeps the day-to-day path one-key
  // (`/remote-pi`) and exposes only the actions that have distinct user
  // intent: setup, status, stop, pair, devices, revoke, set-relay.
  //
  // Handlers forward to main.dispatchRootCommand — the SAME routing table the
  // main command uses, so a nested registration and its `/remote-pi <sub>`
  // spelling can never drift apart.
  pi.registerCommand("remote-pi", {
    description: "Connect (join local mesh + start relay), or run setup on first use",
    getArgumentCompletions: async (prefix) => {
      if (prefix.startsWith("revoke ") || prefix === "revoke") {
        const shortPrefix = prefix === "revoke" ? "" : prefix.slice("revoke ".length);
        return getMain().then((m) => m._shortidCompletions(shortPrefix, "revoke "));
      }
      return [
        "setup", "status", "stop",
        "pair", "devices", "revoke",
        "rename",
        "set-relay", "set-advertise",
        "relay", "relay start", "relay stop", "relay status", "relay url",
        "config",
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
      await dispatch(args, ctx);
    },
  });

  // Nested registrations (one entry per public action). The flat handler
  // above already routes `/remote-pi <sub>` — these exist for the SDK's
  // command palette and slash-autocomplete in some UI modes.
  // dispatch() uses the synchronous fast path: callers that fire-and-forget
  // (e.g. `void stop()`) must see the runtime's synchronous prefix run before
  // the returned promise settles, exactly as they did against the monolith.
  const dispatch = (sub: string, ctx: unknown): Promise<void> => {
    const m = mainLoaded;
    if (m) return m.dispatchRootCommand(sub, ctx as Parameters<typeof m.dispatchRootCommand>[1]);
    return _main().then((loaded) => {
      mainLoaded = loaded;
      return loaded.dispatchRootCommand(sub, ctx as Parameters<typeof loaded.dispatchRootCommand>[1]);
    });
  };
  pi.registerCommand("remote-pi setup",    { description: "Run the setup wizard and update local config", handler: async (_, ctx) => { ext.lastCtx = ctx; await dispatch("setup", ctx); } });
  pi.registerCommand("remote-pi status",   { description: "Show local mesh + relay status", handler: async (_, ctx) => { ext.lastCtx = ctx; await dispatch("status", ctx); } });
  pi.registerCommand("remote-pi stop",     { description: "Stop everything (leave local mesh + disconnect relay)", handler: async (_, ctx) => { ext.lastCtx = ctx; await dispatch("stop", ctx); } });
  pi.registerCommand("remote-pi pair",     { description: "Show a QR code to pair a new mobile device (optional: --ttl <seconds>)", handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`pair ${args.trim()}`, ctx); } });
  pi.registerCommand("remote-pi devices",  { description: "List paired mobile devices", handler: async (_, ctx) => { ext.lastCtx = ctx; await dispatch("devices", ctx); } });
  pi.registerCommand("remote-pi rename",  { description: "Rename this agent in the current session (updates mesh + relay room)", handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`rename ${args.trim()}`, ctx); } });
  pi.registerCommand("remote-pi revoke", {
    description: "Revoke a paired device by its shortid",
    getArgumentCompletions: async (prefix) => getMain().then((m) => m._shortidCompletions(prefix)),
    handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`revoke ${args.trim()}`, ctx); },
  });
  pi.registerCommand("remote-pi set-relay", { description: "Persist a new relay URL to user config", handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`set-relay ${args.trim()}`, ctx); } });
  pi.registerCommand("remote-pi set-advertise", { description: "Set the address the pairing QR advertises (e.g. a Tailscale IP); empty clears it", handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`set-advertise ${args.trim()}`, ctx); } });
  pi.registerCommand("remote-pi config", { description: "Show the effective relay URL and where it came from", handler: async (_, ctx) => { ext.lastCtx = ctx; await dispatch("config", ctx); } });
  pi.registerCommand("remote-pi relay", { description: "Relay control: start | stop | status | url <http(s) url> (no arg toggles)", handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`relay ${args.trim()}`, ctx); } });

  // Plan/25 Wave D
  pi.registerCommand("remote-pi peers", {
    description: "List local + cross-PC mesh peers, grouped by PC label",
    handler: async (_, ctx) => { ext.lastCtx = ctx; await dispatch("peers", ctx); },
  });

  // Daemon registry (plan/26 Wave 1) — create + remove. start/stop/send/
  // status/install/uninstall come in later waves with the supervisor.
  pi.registerCommand("remote-pi create", {
    description: "Register a folder as a daemon and start it (when the supervisor is running)",
    handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`create ${args.trim()}`, ctx); },
  });
  pi.registerCommand("remote-pi remove", {
    description: "Stop + unregister a daemon by id (local config is preserved)",
    handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`remove ${args.trim()}`, ctx); },
  });

  // Fleet ops via the supervisor (plan/26 W2). `/remote-pi stop` stays as
  // local stop — fleet stop is `/remote-pi daemon stop`.
  pi.registerCommand("remote-pi daemons",        { description: "List registered daemons + state", handler: async (_, ctx) => { ext.lastCtx = ctx; await dispatch("daemons", ctx); } });
  pi.registerCommand("remote-pi daemon start",   { description: "Start daemons: all, or one by id (`daemon start <id>`)", handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`daemon start ${args.trim()}`, ctx); } });
  pi.registerCommand("remote-pi daemon stop",    { description: "Stop daemons: all, or one by id (`daemon stop <id>`)", handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`daemon stop ${args.trim()}`, ctx); } });
  pi.registerCommand("remote-pi daemon restart", { description: "Restart daemons: all, or one by id (`daemon restart <id>`)", handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`daemon restart ${args.trim()}`, ctx); } });
  pi.registerCommand("remote-pi daemon status",  { description: "Show fleet runtime status (pid, uptime, restarts)", handler: async (_, ctx) => { ext.lastCtx = ctx; await dispatch("daemon status", ctx); } });
  pi.registerCommand("remote-pi daemon send",    { description: "Send a prompt to a daemon: `daemon send <id> \"<text>\"`", handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`daemon send ${args.trim()}`, ctx); } });
  pi.registerCommand("remote-pi cron",           { description: "Schedule recurring prompts to daemons: `cron <add|list|remove|enable|disable|run|log>`", handler: async (args, ctx) => { ext.lastCtx = ctx; await dispatch(`cron ${args.trim()}`, ctx); } });

  // Service install / uninstall (plan/26 W3)
  pi.registerCommand("remote-pi install",   { description: "Install pi-supervisord as a system service + link the remote-pi CLI (systemd/launchd/Task Scheduler; Windows prompts for admin)", handler: async (_, ctx) => { ext.lastCtx = ctx; await dispatch("install", ctx); } });
  pi.registerCommand("remote-pi uninstall", { description: "Remove the pi-supervisord system service + the CLI shims (daemons registry preserved; Windows prompts for admin)", handler: async (_, ctx) => { ext.lastCtx = ctx; await dispatch("uninstall", ctx); } });

  // Auto-init now runs from the session_start handler (above), AFTER the
  // SDK calls bindCore(). The original setTimeout(0) here fired before bindCore
  // replaced the throwing action-method stubs, so the first pi.sendMessage in
  // _emitRelayState crashed the headless pi process with "Extension runtime not
  // initialized" in a 5s supervisor crash-loop. The session_start handler now
  // auto-starts for ANY session with auto_start_relay (default true), so new
  // interactive pi sessions are on remote automatically — no /remote-pi needed.
};

export default extension;

// ── CLI bootstrap (`remote-pi <subcmd>` bin points HERE) ─────────────────────
//
// Direct-run means this process IS the CLI (`node dist/index.js`), never a
// pi-loaded extension — so loading the heavy runtime costs nothing here, and
// `void` (not top-level await) keeps the module await-free for jiti-loaded
// hosts. Node keeps the process alive until runCli's work settles.
if (_isDirectRun()) {
  void import("./main.js").then((m) => { mainLoaded = m; return m.runCli(process.argv); });
}
