import type { ClientMessage, ServerMessage } from "../protocol/types.js";
import { signInnerCt, signInnerCtV2, verifyInnerDual } from "./inner_sig.js";
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
  /** v1 signature — sender-bound. Kept on every new-sender frame so legacy
   *  recipients (app 1.3.0 / pre-#25 Pis) still verify (PR #25 review #1). */
  sig?: string;
  /** v2 signature — dest-bound + ts-windowed. Preferred by new recipients. */
  sig2?: string;
  /** Sender epoch-ms covered by `sig2` (v2). Forwarded verbatim like the sigs. */
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
  /** True when this peer has DEMONSTRATED v2 (a verified `sig2`). v1-only
   *  frames from such a peer are a downgrade strip → drop (review #1). */
  peerV2: (peerId: string) => boolean;
  /** Cross-channel replay dedup (review #3 on #25): the seen-id LRU lives
   *  with the policy — it must survive channel re-creation on reconnect.
 *  Returns true when `id` was already delivered for this peer. */
  seenId: (peerId: string, id: string) => boolean;
  /** Called when ANY signature is present (before verification) — flips the
   *  unsigned-drop ratchet synchronously so a following unsigned frame can
   *  never slip through the async gap (review #4 on #24). */
  onSignaturePresent: (peerId: string) => void;
  /** Called when a VALID v2 signature is verified — flips the persistence
   *  ratchet (peers.json best-effort; idempotent). */
  onSignatureVerified: (peerId: string) => void;
  /** Called when a VALID v2 signature is verified — marks the peer v2-capable
   *  (in-memory is enough; a restart just re-learns on the next frame). */
  onV2Verified: (peerId: string) => void;
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
    // Security fix 2026-08 (dual-sig, PR #25 review #1): every outbound frame
    // carries BOTH signatures — `sig` (v1) so legacy recipients (app 1.3.0,
    // pre-#25 Pis) keep verifying, `sig2`+`ts` (v2) for the recipient binding
    // and replay window. Old relays drop the unknown fields (harmless); new
    // relays forward them verbatim.
    const outer: OuterEnvelope = { peer: this.remotePeerId, ct };
    const policy = this.sigPolicy;
    if (policy) {
      const ts = policy.now();
      outer.sig = signInnerCt(policy.keypair.secretKey, ct);
      outer.sig2 = signInnerCtV2(policy.keypair.secretKey, this.remotePeerId, ts, ct);
      outer.ts = ts;
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

    // Security fix 2026-08 + PR #25 review follow-up — end-to-end sender
    // verification. `peer` is the relay-asserted sender pubkey. Outcomes:
    //   sig2 present            → flip the unsigned-drop ratchet SYNCHRONOUSLY
    //                            (review #4/#24: a trailing unsigned frame must
    //                            not slip past the async gap), then STRICT v2
    //                            verify (dest + ts). Invalid → drop, NO v1
    //                            fallback (legit senders sign both; a broken
    //                            pair means tampering).
    //   sig only                → if the peer is v2-ratcheted, this is a
    //                            downgrade strip → drop (review #1/#25).
    //                            Else legacy v1 transition → verify & deliver.
    //   both absent             → deliver only pre-ratchet (legacy transition).
    // Replay dedup lives with the policy so it survives re-attachment.
    const policy = this.sigPolicy;
    if (policy) {
      const hasSig2 = typeof outer.sig2 === "string" && outer.sig2.length > 0;
      const hasSig = typeof outer.sig === "string" && outer.sig.length > 0;
      if (hasSig2 || hasSig) policy.onSignaturePresent(outer.peer);
      if (hasSig2) {
        const verdict = verifyInnerDual(
          outer.peer,
          policy.ownPeerId,
          outer.ct,
          outer.sig,
          outer.sig2,
          outer.ts,
          policy.now(),
        );
        if (!verdict.ok) return;
        policy.onV2Verified(outer.peer);
        policy.onSignatureVerified(outer.peer);
        this._deliver(outer.ct);
        return;
      }
      if (hasSig) {
        if (policy.peerV2(outer.peer)) return; // downgrade strip from a v2 peer
        const verdict = verifyInnerDual(
          outer.peer,
          policy.ownPeerId,
          outer.ct,
          outer.sig,
          undefined,
          undefined,
          policy.now(),
        );
        if (!verdict.ok) return;
        this._deliver(outer.ct);
        return;
      }
      if (policy.requiresSignature(outer.peer)) return; // ratcheted, unsigned — drop
    }
    this._deliver(outer.ct);
  }

  /** Auto-listener reconnect path (PR #25 review #3): deliver an
   *  already-verified ct through the normal pipeline — parse → dedup →
   *  onMessage — instead of bypassing the channel. Replays of a captured
   *  frame across a reconnect hit the same policy-level seen-id LRU. */
  deliverVerified(ct: string): void {
    this._deliver(ct);
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

    // Replay defense (PR #24/#25 reviews): ids already delivered for this
    // peer are replayed frames — drop. The LRU lives with the POLICY so it
    // survives channel re-creation on reconnect (review #3/#25); channels
    // without a policy (tests) keep a per-channel fallback LRU.
    //
    // BUG 2026-08-22 (ask_user stuck sheet): `extension_ui_response` frames
    // legitimately REUSE the originating request's id (the pi-ask flowId) —
    // a user RETRY after a rejected answer resends the exact same id. The
    // LRU ate the retry, so the bridge never saw it and the phone stayed
    // stuck. Responses are idempotent at the pi-ask level (an active flow
    // accepts it; a resolved flow answers flow_not_found), so they bypass
    // the dedupe. Streaming state (chunks/echoes) keeps full dedupe.
    const type = (msg as Record<string, unknown>).type;
    const id = (msg as Record<string, unknown>).id;
    if (type !== "extension_ui_response") {
      if (this.sigPolicy && typeof id === "string") {
        if (this.sigPolicy.seenId(this.remotePeerId, id)) return;
      } else if (this._seenBeforeLocal(id)) {
        return;
      }
    }

    this.onMessage(msg as ClientMessage);
  }

  /** Fallback per-channel LRU when no policy is injected (test channels). */
  private readonly _seenLocal = new Map<string, true>();
  private _seenBeforeLocal(id: unknown): boolean {
    if (typeof id !== "string" || id.length === 0) return false;
    if (this._seenLocal.has(id)) return true;
    if (this._seenLocal.size >= 2048) {
      const oldest = this._seenLocal.keys().next().value;
      if (oldest !== undefined) this._seenLocal.delete(oldest);
    }
    this._seenLocal.set(id, true);
    return false;
  }
}
