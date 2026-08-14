import type { ClientMessage, ServerMessage } from "../protocol/types.js";
import { signInnerCtV2, verifyInnerEnvelope } from "./inner_sig.js";
import type { Ed25519Keypair } from "../pairing/crypto.js";
import type { RelayClient } from "./relay_client.js";

/** Sink for ServerMessage outbound to the remote app. */
export interface PeerChannel {
  send(msg: ServerMessage): void;
}

/**
 * Outer envelope shape forwarded by the relay.
 * { "peer": "<sender_peer_id>", "room"?: "<room_id>", "ct": "<base64 JSON inner>",
 *   "sig"?: "<base64 sig>", "ts"?: <epoch-ms number> }
 *
 * Post rollback (plano 06): `ct` is base64(JSON.stringify(inner)) — no cipher,
 * no MAC. Relay continues opaque (never JSON.parses ct).
 *
 * Security fix 2026-08: `sig` is the SENDER's Ed25519 signature (see
 * ./inner_sig.ts — v2 binds the RECIPIENT pubkey + a timestamp) — end-to-end
 * sender authenticity the relay cannot forge and cannot redirect to another
 * Pi of the same owner. The relay forwards `sig`/`ts` verbatim (never strips
 * them). Recipients drop frames whose signature is present-but-invalid,
 * stale (outside the freshness window), bound to a different recipient, or —
 * once the peer's `signing` ratchet is on in peers.json — unsigned.
 *
 * `room` (plano 17): identifies which Pi room sent the envelope. Lets the
 * relay multiplex N peers with the same Ed25519 pubkey but distinct cwds.
 * Optional for backward-compat with single-room relays.
 */
interface OuterEnvelope {
  peer: string;
  room?: string;
  ct: string;
  sig?: string;
  ts?: number;
}

/** Inbound signature policy — injected by the host (index.ts). */
export interface InnerSigPolicy {
  /** This Pi's keypair — signs every outbound frame. */
  keypair: Ed25519Keypair;
  /** This Pi's own relay peer id (canonical standard-base64 of its public
   *  key) — the `dest` binding for inbound v2 verification. */
  ownPeerId: string;
  /** Testable clock (epoch ms) for the v2 freshness window. */
  now: () => number;
  /** True when the peer's `signing` ratchet is on → unsigned frames drop.
   *  SYNC against an in-memory cache — delivery must stay synchronous so
   *  handlers can reply within the same tick (tests + app latency). */
  requiresSignature: (peerId: string) => boolean;
  /** Called when ANY signature is present (before verification) — flips the
   *  unsigned-drop ratchet synchronously so a following unsigned frame can
   *  never slip through the async gap (review follow-up #4). */
  onSignaturePresent: (peerId: string) => void;
  /** Called when a VALID v2 signature is verified — flips the persistence
   *  ratchet (peers.json best-effort; idempotent). */
  onSignatureVerified: (peerId: string) => void;
}

/**
 * Plaintext PeerChannel backed by a RelayClient WebSocket.
 *
 * Usage (after pair_request handshake completes):
 *   const channel = new PlainPeerChannel(relay, appPeerId, myRoomId, onMsg)
 *   channel.send(serverMessage)          // base64-encodes JSON, routes via relay
 *   // incoming relay messages destined for appPeerId are auto-decoded
 *   // and delivered via onMessage callback
 *
 * `myRoomId` is the *local* Pi's room id — sent on every outbound envelope
 * so the app can correlate which Pi sent it (multi-pi support, plano 17).
 */
export class PlainPeerChannel implements PeerChannel {
  private readonly _unsubscribe: () => void;

  constructor(
    private readonly relay: RelayClient,
    private readonly remotePeerId: string,
    /**
     * This Pi's room id. Currently NOT injected in the outer envelope
     * (defensive — relay/app not yet ready). Kept in the constructor for
     * forward-compat so callers don't need to change again when we re-enable.
     */
    myRoomId: string | undefined,
    private readonly onMessage: (msg: ClientMessage) => void,
    /** Called when this specific peer connection is considered lost. */
    _onDisconnect?: () => void,
    /** Security fix 2026-08 — signing/verification policy. Optional so
     *  non-production callers (tests) keep the legacy unsigned wire format. */
    private readonly sigPolicy?: InnerSigPolicy,
  ) {
    const listener = (line: string) => this._onLine(line);
    relay.on("message", listener);
    this._unsubscribe = () => relay.off("message", listener);
    void _onDisconnect;
    void myRoomId;  // intentionally unused — see send() comment
  }

  // ── PeerChannel interface ──────────────────────────────────────────────────

  send(msg: ServerMessage): void {
    const ct = Buffer.from(JSON.stringify(msg)).toString("base64");
    // NOTE: `room` removed from the outer envelope until relay (W1.A) + app
    // (W1.C) accept the field. Multi-Pi multiplexing already works via
    // `room_id`/`room_meta` in the WS-level `hello` — outer routing stays by
    // `peer` alone. Re-add the field once downstream is ready.
    //
    // Security fix 2026-08 (v2): sign dest(this peer's own id) || ts || ct —
    // recipient-bound + replay-windowed. Old relays drop the unknown fields
    // (harmless); new relays forward them verbatim.
    const outer: OuterEnvelope = { peer: this.remotePeerId, ct };
    const policy = this.sigPolicy;
    if (policy) {
      const ts = policy.now();
      outer.ts = ts;
      outer.sig = signInnerCtV2(policy.keypair.secretKey, this.remotePeerId, ts, ct);
    }
    // Best-effort delivery. The relay WS can be mid-reconnect (idle/NAT drop, or
    // a session_new/session-replacement teardown) when we push a server→app frame
    // — notably the action_ok/action_error ack a handler emits right after
    // newSession. `relay.send` throws "relay: not connected" in that window; since
    // this runs inside an async SDK event callback, letting it propagate becomes an
    // uncaughtException that kills the whole pi process. The relay auto-reconnects
    // and the app re-syncs via session_sync, so a dropped frame is recoverable — a
    // crash is not. Mirrors RelayClient.sendControl's no-op-when-closed policy.
    try {
      this.relay.send(JSON.stringify(outer));
    } catch {
      /* relay down — drop this frame; reconnect + session_sync will recover */
    }
  }

  /** Detaches from relay (does not close the relay itself). */
  detach(): void {
    this._unsubscribe();
  }

  // ── Incoming line from relay ────────────────────────────────────────────────

  private _onLine(line: string): void {
    let outer: OuterEnvelope;
    try {
      outer = JSON.parse(line) as OuterEnvelope;
    } catch {
      return; // malformed line
    }

    if (outer.peer !== this.remotePeerId) return;
    if (!outer.ct) return;

    // Security fix 2026-08 + PR #24 follow-up — end-to-end sender verification.
    // `peer` is the relay-asserted sender pubkey. Outcomes:
    //   sig present            → flip the unsigned-drop ratchet SYNCHRONOUSLY
    //                           (review #4: a trailing unsigned frame must not
    //                           slip past the async gap), then verify.
    //   sig valid v2           → deliver (dest-bound + ts-window checked),
    //                           persist the ratchet.
    //   sig valid v1 (no ts)   → deliver (legacy transition, sender-bound
    //                           only — accepted per "accept both").
    //   sig present + INVALID  → DROP always (tampering, cross-peer redirect,
    //                           stale replay).
    //   sig absent             → deliver only if the peer hasn't demonstrated
    //                           signing support yet (legacy transition).
    // Plus: inner-id dedup (LRU) so a replayed frame — even one inside the
    // v2 freshness window — never executes twice (review #1).
    const policy = this.sigPolicy;
    if (policy) {
      if (typeof outer.sig === "string" && outer.sig.length > 0) {
        policy.onSignaturePresent(outer.peer);
        const verdict = verifyInnerEnvelope(
          outer.peer,
          policy.ownPeerId,
          outer.ct,
          outer.sig,
          outer.ts,
          policy.now(),
        );
        if (!verdict.ok) return;
        if (verdict.version === 2) policy.onSignatureVerified(outer.peer);
        this._deliver(outer.ct);
        return;
      }
      if (policy.requiresSignature(outer.peer)) return; // ratcheted, unsigned — drop
    }
    this._deliver(outer.ct);
  }

  /** Bounded LRU of seen inner message ids — replay defense (review #1).
   *  Map preserves insertion order: evict oldest when over cap. */
  private readonly _seenIds = new Map<string, true>();
  private static readonly SEEN_IDS_CAP = 2048;

  private _seenBefore(id: unknown): boolean {
    if (typeof id !== "string" || id.length === 0) return false;
    if (this._seenIds.has(id)) return true;
    if (this._seenIds.size >= PlainPeerChannel.SEEN_IDS_CAP) {
      const oldest = this._seenIds.keys().next().value;
      if (oldest !== undefined) this._seenIds.delete(oldest);
    }
    this._seenIds.set(id, true);
    return false;
  }

  private _deliver(ct: string): void {
    let plaintext: string;
    try {
      plaintext = Buffer.from(ct, "base64").toString("utf8");
    } catch {
      return;
    }

    let msg: unknown;
    try {
      msg = JSON.parse(plaintext);
    } catch {
      return;
    }

    if (
      !msg ||
      typeof msg !== "object" ||
      typeof (msg as Record<string, unknown>).type !== "string"
    ) {
      return;
    }

    // Replay defense: an id we've already delivered on this channel is a
    // replayed frame — drop it. (Unsigned legacy frames get the same
    // treatment; ids are client-generated UUIDs, never legitimately reused.)
    if (this._seenBefore((msg as Record<string, unknown>).id)) return;

    this.onMessage(msg as ClientMessage);
  }
}
