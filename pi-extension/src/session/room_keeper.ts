/**
 * Plan/140 A — room keeper: durable-history presence for dark rooms.
 *
 * The phone's chat history is only reachable while the owning pi session's
 * extension is live in its (cwd-derived) relay room. Rooms go dark for many
 * reasons — session closed, crash, relay-socket wedge, PC reboot, session
 * restarted from a different cwd — and while dark, every `session_sync`
 * from a paired phone is silently dropped by the relay: a frozen chat on
 * the phone, undiagnosable from either end (verified 2026-09-05/08).
 *
 * The keeper runs INSIDE the supervisor process (watchdog-guarded, always
 * up) and closes that gap: for every recently-seen room in
 * `~/.pi/piper/rooms.json` it opens one lightweight relay connection in
 * that room under the SAME PC pubkey and answers exactly one client
 * message — `session_sync` — from the room's newest durable transcript
 * (`~/.pi/agent/sessions/<cwd>/*.jsonl`), with `offline: true` on the
 * reply so the app can badge the chat "Pi offline".
 *
 * Yield semantics (a real session always wins):
 *  - If a room is held (RoomAlreadyOpenError), the keeper backs off and
 *    retries — the holder is either the real session or a stale zombie.
 *  - A real session that ITSELF hits RoomAlreadyOpen asks the supervisor
 *    (`claim_room`, daemon/control_protocol.ts) to drop the keeper's
 *    connection for that room, then retries and wins.
 *  - `dropRoom` is also the supervisor's hook for "a real daemon for this
 *    cwd is starting" (proactive yield).
 *
 * The keeper never broadcasts anything (no agent events exist) and never
 * mutates transcripts — it is a read-only mirror of the durable store.
 */

import { basename } from "node:path";
import type { Ed25519Keypair } from "../pairing/crypto.js";
import { listPeers, peerSigningEnforced, markPeerSigning } from "../pairing/storage.js";
import { toWebSocketUrl } from "../config.js";
import { RelayClient, RoomAlreadyOpenError } from "../transport/relay_client.js";
import {
  PlainPeerChannel,
  type InnerSigPolicy,
} from "../transport/peer_channel.js";
import {
  decodeCursor,
  encodeCursor,
  readMessages,
  refreshIndex,
  resolveCurrentSessionFile,
  type FileIndex,
} from "./file_index.js";
import { readRoomsRegistry, type RoomsRegistryEntry } from "./rooms_registry.js";
import { DEVICE_ROOM } from "../rooms.js";

/** Lazy accessor for the ext's message→events mapper. Imported dynamically on
 *  first sync to keep this module free of a static index.ts edge — the
 *  supervisor imports THIS module, and index.ts (transitively) imports the
 *  supervisor, so a static edge would close a module cycle. */
type MapMessages = (msgs: unknown[], precedingUserId?: string) => unknown[];
let cachedMapper: MapMessages | null = null;
async function mapAgentMessages(): Promise<MapMessages> {
  if (!cachedMapper) {
    const mod = await import("../index.js");
    cachedMapper = mod._mapAgentMessagesToEvents as MapMessages;
  }
  return cachedMapper;
}

/** Minimal relay-client surface the keeper needs (tests inject a fake). */
export interface KeeperRelayClient {
  connect(options?: { roomId?: string; roomMeta?: Record<string, unknown> }): Promise<void>;
  send(line: string): void;
  close(): void;
  on(event: "message", fn: (line: string) => void): unknown;
  on(event: "close", fn: () => void): unknown;
  off(event: string, fn: (...args: never[]) => void): unknown;
}

export interface RoomKeeperOptions {
  /** Canonical http(s):// relay URL (converted to ws(s):// here). */
  relayUrl: string;
  /** The PC's long-term Ed25519 keypair — same identity as every ext. */
  keypair: Ed25519Keypair;
  /** Structured log line sink (supervisor wires stderr). */
  log?: (line: string) => void;
  /** Injectable clock (tests). */
  now?: () => number;
  /** Registry file path override (tests). Default: roomsRegistryPath(). */
  registryPath?: string;
  /** Rooms not seen within this window are not kept. Default 14 days. */
  maxAgeMs?: number;
  /** Re-sweep cadence for new/stale rooms. Default 60 s. */
  sweepIntervalMs?: number;
  /** Reconnect cadence while a room is held by a real session. Default 60 s. */
  retryMs?: number;
  /** Cooldown after a claim before the keeper may retake the room. Default 10 s. */
  claimCooldownMs?: number;
  /** History page size cap (mirrors the ext's sync limit). Default 2000. */
  historyLimit?: number;
  /** Injectable paired-peer ids (tests). Default: pairing/storage listPeers. */
  listPairedPeers?: () => Promise<string[]>;
  /** Injectable relay-client factory (tests). */
  makeClient?: (wsUrl: string, keypair: Ed25519Keypair) => KeeperRelayClient;
}

interface HeldRoom {
  entry: RoomsRegistryEntry;
  relay: KeeperRelayClient;
  /** Per-sender verified channels (lazily created, paired peers only). */
  channels: Map<string, PlainPeerChannel>;
  /** The channel's own line-listener, registered via the sink adapter — the
   *  keeper dispatches explicitly, so no listener-added-during-emit race. */
  channelSinks: Map<string, (line: string) => void>;
  /** Cached file index for the room's transcript. */
  index: FileIndex | null;
}

const DEFAULT_MAX_AGE_MS = 14 * 24 * 3_600_000;
const DEFAULT_SWEEP_MS = 60_000;
const DEFAULT_RETRY_MS = 60_000;
const DEFAULT_CLAIM_COOLDOWN_MS = 10_000;
const DEFAULT_HISTORY_LIMIT = 2_000;

export class RoomKeeper {
  private readonly held = new Map<string, HeldRoom>();
  private readonly suppressedUntil = new Map<string, number>();
  private readonly retryTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private sweepTimer: ReturnType<typeof setInterval> | null = null;
  private stopped = false;
  private readonly opts: Required<Pick<RoomKeeperOptions, "maxAgeMs" | "sweepIntervalMs" | "retryMs" | "claimCooldownMs" | "historyLimit">> & RoomKeeperOptions;

  constructor(opts: RoomKeeperOptions) {
    this.opts = {
      maxAgeMs: opts.maxAgeMs ?? DEFAULT_MAX_AGE_MS,
      sweepIntervalMs: opts.sweepIntervalMs ?? DEFAULT_SWEEP_MS,
      retryMs: opts.retryMs ?? DEFAULT_RETRY_MS,
      claimCooldownMs: opts.claimCooldownMs ?? DEFAULT_CLAIM_COOLDOWN_MS,
      historyLimit: opts.historyLimit ?? DEFAULT_HISTORY_LIMIT,
      ...opts,
    };
  }

  private get now(): number {
    return this.opts.now?.() ?? Date.now();
  }

  private log(line: string): void {
    this.opts.log?.(line);
  }

  async start(): Promise<void> {
    this.stopped = false;
    // Pre-warm the mapper's dynamic import (the full ext module + SDK) so
    // the FIRST session_sync isn't paid that latency — the phone's retry
    // cadence is ~30 s; a cold first reply could be mistaken for a drop.
    void mapAgentMessages().catch(() => { /* retried on first sync */ });
    await this.sweep();
    this.sweepTimer = setInterval(() => void this.sweep(), this.opts.sweepIntervalMs);
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.sweepTimer !== null) clearInterval(this.sweepTimer);
    this.sweepTimer = null;
    for (const roomId of [...this.held.keys()]) this._release(roomId, "stop");
  }

  /** Desired-room sweep: connect new dark rooms, release stale ones. */
  async sweep(): Promise<void> {
    if (this.stopped) return;
    const registry = readRoomsRegistry(this.opts.registryPath);
    const cutoff = this.now - this.opts.maxAgeMs;
    const desired = new Set<string>();
    for (const [roomId, entry] of registry) {
      if (entry.lastSeenAt < cutoff) continue;
      if (roomId === DEVICE_ROOM || entry.roomId === DEVICE_ROOM) continue;
      desired.add(roomId);
    }
    for (const roomId of [...this.held.keys()]) {
      if (!desired.has(roomId)) this._release(roomId, "stale");
    }
    for (const roomId of desired) {
      if (this.held.has(roomId)) continue;
      if ((this.suppressedUntil.get(roomId) ?? 0) > this.now) continue;
      await this._connectRoom(registry.get(roomId)!);
    }
  }

  /**
   * Claim hook (supervisor `claim_room`): drop the keeper's connection so
   * the claiming real session can take the room. The room goes into a
   * short suppression so the claiming reconnect isn't raced.
   */
  dropRoom(roomId: string): boolean {
    const had = this.held.has(roomId);
    this._release(roomId, "claim");
    this.suppressedUntil.set(roomId, this.now + this.opts.claimCooldownMs);
    return had;
  }

  // ── connection management ────────────────────────────────────────────────

  private async _connectRoom(entry: RoomsRegistryEntry): Promise<void> {
    const make = this.opts.makeClient ?? ((url: string, kp: Ed25519Keypair) =>
      new RelayClient(url, kp) as unknown as KeeperRelayClient);
    const relay = make(toWebSocketUrl(this.opts.relayUrl), this.opts.keypair);
    try {
      await relay.connect({
        roomId: entry.roomId,
        roomMeta: { name: basename(entry.cwd) || entry.cwd, cwd: entry.cwd },
      });
    } catch (err) {
      try { relay.close(); } catch { /* best-effort */ }
      if (err instanceof RoomAlreadyOpenError) {
        // Held by a live session (the normal case while the room is healthy).
        this._scheduleRetry(entry.roomId);
        return;
      }
      // Relay down / auth failure — retry on the same cadence.
      this.log(`room-keeper: connect ${entry.roomId} failed: ${String(err)}`);
      this._scheduleRetry(entry.roomId);
      return;
    }

    const room: HeldRoom = { entry, relay, channels: new Map(), channelSinks: new Map(), index: null };
    this.held.set(entry.roomId, room);
    relay.on("close", () => {
      if (this.held.get(entry.roomId) === room) {
        this._release(entry.roomId, "socket-close");
        this._scheduleRetry(entry.roomId);
      }
    });
    relay.on("message", (line: string) => this._onRoomLine(room, line));
    // Warm the paired-peer set so the first sync from a paired phone is
    // served immediately (unknown senders trigger a refresh and retry).
    void this._refreshPaired();
    this.log(`room-keeper: holding ${entry.roomId} (${entry.cwd})`);
  }

  /** Envelope dispatch: paired senders only — history is sensitive and the
   *  keeper serves no pairing handshake. Unknown sender → refresh the set
   *  (the phone's ~30 s sync retry lands once warm) and drop the frame. */
  private _onRoomLine(room: HeldRoom, line: string): void {
    let peerId: string | undefined;
    try {
      const outer = JSON.parse(line) as { peer?: unknown };
      if (typeof outer.peer === "string") peerId = outer.peer;
    } catch {
      return; // not an outer envelope (relay control line) — ignore
    }
    if (!peerId) return;
    if (!this.pairedPeers.has(peerId)) {
      // Unknown sender: refresh the paired set and serve THIS frame when the
      // sender turns out to be paired (covers the first sync right after a
      // keeper start, before the warm refresh landed). Never serve unpaired.
      void this._refreshPaired().then(() => {
        if (this.pairedPeers.has(peerId) && this.held.get(room.entry.roomId) === room) {
          this._dispatch(room, peerId!, line);
        }
      });
      return;
    }
    this._dispatch(room, peerId, line);
  }

  private _dispatch(room: HeldRoom, peerId: string, line: string): void {
    const sink = room.channelSinks.get(peerId);
    if (!sink) {
      // First frame from this paired peer: create the verified channel —
      // its sink misses THIS dispatch, so re-deliver explicitly after create.
      try {
        this._channelFor(room, peerId);
      } catch (err) {
        this.log(`room-keeper: channel create failed (${peerId}): ${String(err)}`);
        return;
      }
      const created = room.channelSinks.get(peerId);
      if (!created) {
        this.log(`room-keeper: sink missing after channel create (${peerId})`);
        return;
      }
      try {
        created(line);
      } catch (err) {
        this.log(`room-keeper: sink dispatch failed (${peerId}): ${String(err)}`);
      }
      return;
    }
    sink(line);
  }

  private pairedPeers = new Set<string>();
  private pairedRefreshPromise: Promise<void> | null = null;

  private _refreshPaired(): Promise<void> {
    // Dedupe by RETURNING the in-flight promise — an early-returning
    // `refreshing` boolean made concurrent callers resolve BEFORE the set
    // was warm, silently dropping the frame that triggered them.
    if (this.pairedRefreshPromise) return this.pairedRefreshPromise;
    const p = (async () => {
      try {
        const ids = this.opts.listPairedPeers
          ? await this.opts.listPairedPeers()
          : (await listPeers()).map((p2) => p2.remote_epk);
        for (const id of ids) this.pairedPeers.add(id);
      } catch {
        // peers.json unreadable — nothing gets served; retried on next frame.
      }
    })();
    this.pairedRefreshPromise = p;
    void p.then(() => {
      if (this.pairedRefreshPromise === p) this.pairedRefreshPromise = null;
    });
    return p;
  }

  private _channelFor(room: HeldRoom, peerId: string): PlainPeerChannel {
    const existing = room.channels.get(peerId);
    if (existing) return existing;
    // Sink adapter: the channel subscribes to "message" on this object and
    // sends through the room's real relay — the keeper keeps dispatch control.
    const sink = {
      on: (_event: "message", fn: (line: string) => void) => {
        room.channelSinks.set(peerId, fn);
        return sink;
      },
      off: (_event: string, fn: (...args: never[]) => void) => {
        if (room.channelSinks.get(peerId) === (fn as unknown as (line: string) => void)) {
          room.channelSinks.delete(peerId);
        }
      },
      send: (line: string) => {
        room.relay.send(line);
      },
    };
    const channel = new PlainPeerChannel(
      sink as unknown as RelayClient,
      peerId,
      room.entry.roomId,
      (msg) => this._onClientMessage(room, peerId, msg as { type?: string } & Record<string, unknown>),
      undefined,
      this._sigPolicy(),
    );
    room.channels.set(peerId, channel);
    return channel;
  }

  private _onClientMessage(room: HeldRoom, peerId: string, msg: { type?: string } & Record<string, unknown>): void {
    this.log(`room-keeper: client message ${String(msg.type)} from ${peerId.slice(0, 8)}`);
    if (msg.type !== "session_sync") return; // read-only mirror: nothing else is served
    void this._serveSync(room, peerId, msg).catch((err) => {
      this.log(`room-keeper: session_sync failed (${room.entry.roomId}): ${String(err)}`);
    });
  }

  // ── history serving ──────────────────────────────────────────────────────

  private async _serveSync(
    room: HeldRoom,
    peerId: string,
    msg: Record<string, unknown>,
  ): Promise<void> {
    const channel = this._channelFor(room, peerId);
    const limit = typeof msg["limit"] === "number" && Number.isFinite(msg["limit"])
      ? Math.max(1, Math.min(Math.floor(msg["limit"]), this.opts.historyLimit))
      : this.opts.historyLimit;

    const ref = resolveCurrentSessionFile(room.entry.cwd);
    let events: unknown[] = [];
    let hasMore = false;
    let nextBefore: string | undefined;
    let sessionStartedAt = 0;
    if (ref) {
      sessionStartedAt = sessionStartedAtFromFileName(ref.path);
      try {
        const mapMessages = await mapAgentMessages();
        room.index = await refreshIndex(room.index, ref);
        const idx = room.index;
        // Mirror of the ext's index path (plan/128) minus the RAM supplement —
        // the keeper has no live session, the durable file is the whole truth.
        // Entries are byteOffset-ascending == ts-ascending (append-only file).
        const entries = idx.entries;
        let endIdx = entries.length;
        const cursor = typeof msg["before"] === "string" ? decodeCursor(msg["before"]) : null;
        if (cursor && cursor.kind === "off") {
          // Page = the `limit` entries strictly OLDER than the cursor's file
          // offset (same contract as the ext's `_pageHistory`).
          endIdx = entries.findIndex((e) => e.byteOffset >= cursor.offset);
          if (endIdx < 0) endIdx = entries.length;
        }
        const startIdx = Math.max(0, endIdx - limit);
        const pageEntries = entries.slice(startIdx, endIdx);
        const messages = pageEntries.length > 0 ? await readMessages(ref.path, pageEntries) : [];
        // Seed the reply target for an assistant row at the page start with
        // the newest user ts strictly older than the page (review C2).
        let precedingUserTs: number | null = null;
        for (let i = startIdx - 1; i >= 0; i--) {
          if (entries[i]!.role === "user") {
            precedingUserTs = entries[i]!.ts;
            break;
          }
        }
        const precedingUserId = precedingUserTs !== null ? `sync_${precedingUserTs}` : undefined;
        events = mapMessages(messages, precedingUserId);
        hasMore = startIdx > 0;
        if (hasMore && pageEntries.length > 0) {
          nextBefore = encodeCursor({ kind: "off", offset: pageEntries[0]!.byteOffset });
        }
      } catch (err) {
        this.log(`room-keeper: page failed (${room.entry.roomId}): ${String(err)}`);
      }
    }

    const reply: Record<string, unknown> = {
      type: "session_history",
      in_reply_to: msg["id"] ?? "",
      session_started_at: sessionStartedAt,
      events,
      eos: true,
      truncated: hasMore,
      has_more: hasMore,
      // Plan/140 A — the app badges this chat "Pi offline" (old apps ignore it).
      offline: true,
    };
    if (nextBefore !== undefined) reply["next_before"] = nextBefore;
    channel.send(reply as Parameters<PlainPeerChannel["send"]>[0]);
  }

  // ── plumbing ─────────────────────────────────────────────────────────────

  private readonly signingRatchet = new Map<string, boolean>();
  private readonly peerV2 = new Map<string, boolean>();
  private readonly seenIds = new Map<string, { at: number }>();

  /** Keeper-local InnerSigPolicy — mirrors the ext's `_innerSigPolicy`. */
  private _sigPolicy(): InnerSigPolicy {
    const kp = this.opts.keypair;
    return {
      keypair: kp,
      ownPeerId: Buffer.from(kp.publicKey).toString("base64"),
      now: () => this.now,
      requiresSignature: (peerId) => this.signingRatchet.get(peerId) === true,
      peerV2: (peerId) => this.peerV2.get(peerId) === true,
      seenId: (peerId, id) => {
        const key = `${peerId}:${id}`;
        return this.seenIds.has(key);
      },
      onSignaturePresent: (peerId) => {
        this.signingRatchet.set(peerId, true);
      },
      onV2Verified: (peerId) => {
        this.peerV2.set(peerId, true);
      },
      onSignatureVerified: (peerId) => {
        void markPeerSigning(peerId).catch(() => { /* best-effort persist */ });
      },
    };
  }

  /** Warms the signing ratchet from peers.json so unsigned frames from
   *  ratcheted peers drop immediately after a keeper restart. Skipped when
   *  the paired list is injected (tests — no real storage). */
  async warmRatchets(): Promise<void> {
    if (this.opts.listPairedPeers) return;
    try {
      for (const peer of await listPeers()) {
        if (await peerSigningEnforced(peer.remote_epk)) {
          this.signingRatchet.set(peer.remote_epk, true);
        }
      }
    } catch {
      // peers.json unreadable — first verified frame re-warms.
    }
  }

  private _scheduleRetry(roomId: string): void {
    if (this.stopped || this.retryTimers.has(roomId)) return;
    const t = setTimeout(() => {
      this.retryTimers.delete(roomId);
      const entry = readRoomsRegistry(this.opts.registryPath).get(roomId);
      if (entry) void this._connectRoom(entry);
    }, this.opts.retryMs);
    this.retryTimers.set(roomId, t);
  }

  private _release(roomId: string, reason: string): void {
    const room = this.held.get(roomId);
    if (room) {
      for (const ch of room.channels.values()) ch.detach();
      try { room.relay.close(); } catch { /* best-effort */ }
      this.held.delete(roomId);
      this.log(`room-keeper: released ${roomId} (${reason})`);
    }
    const t = this.retryTimers.get(roomId);
    if (t) {
      clearTimeout(t);
      this.retryTimers.delete(roomId);
    }
  }
}

/** Extracts the session-start epoch ms from a pi transcript file name
 *  (`2026-09-05T13-24-04-555Z_<uuid>.jsonl` → epoch ms). 0 when unparsable.
 *
 *  Serving the FILE's start time (not the keeper's clock) is load-bearing:
 *  the app's new-session guard (plan/128 C1) wipes the local chat when
 *  session_started_at changes — a keeper reporting its own start would
 *  erase the phone's history on every keeper takeover. */
export function sessionStartedAtFromFileName(path: string): number {
  const name = basename(path);
  const m = name.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3})Z_/);
  if (!m) return 0;
  const [, y, mo, d, h, mi, s, ms] = m;
  const epoch = Date.UTC(+y, +mo - 1, +d, +h, +mi, +s, +ms);
  return Number.isFinite(epoch) ? epoch : 0;
}
