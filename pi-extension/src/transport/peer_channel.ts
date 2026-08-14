import type { ClientMessage, ServerMessage } from "../protocol/types.js";
import { signInnerCt, verifyInnerSig } from "./inner_sig.js";
import type { Ed25519Keypair } from "../pairing/crypto.js";
import type { RelayClient } from "./relay_client.js";

/** Sink for ServerMessage outbound to the remote app. */
export interface PeerChannel {
  send(msg: ServerMessage): void;
}

/**
 * Outer envelope shape forwarded by the relay.
 * { "peer": "<sender_peer_id>", "room"?: "<room_id>", "ct": "<base64 JSON inner>", "sig"?: "<base64 sig>" }
 *
 * Post rollback (plano 06): `ct` is base64(JSON.stringify(inner)) — no cipher,
 * no MAC. Relay continues opaque (never JSON.parses ct).
 *
 * Security fix 2026-08: `sig` is the SENDER's Ed25519 signature over the `ct`
 * string (see ./inner_sig.ts) — end-to-end sender authenticity the relay
 * cannot forge. The relay forwards it verbatim (never strips it). Recipients
 * drop frames whose signature is present-but-invalid, and — once the peer's
 * `signing` ratchet is on in peers.json — unsigned frames too.
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
}

/** Inbound signature policy — injected by the host (index.ts). */
export interface InnerSigPolicy {
  /** This Pi's keypair — signs every outbound frame. */
  keypair: Ed25519Keypair;
  /** True when the peer's `signing` ratchet is on → unsigned frames drop.
   *  SYNC against an in-memory cache — delivery must stay synchronous so
   *  handlers can reply within the same tick (tests + app latency). */
  requiresSignature: (peerId: string) => boolean;
  /** Called when a VALID signature is verified — flips the ratchet
   *  (in-memory immediately, peers.json best-effort; idempotent). */
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
    const outer: OuterEnvelope = {
      peer: this.remotePeerId,
      ct,
      // Security fix 2026-08 — sign every outbound frame. Old relays drop
      // unknown fields (harmless); new relays forward `sig` verbatim.
      ...(this.sigPolicy
        ? { sig: signInnerCt(this.sigPolicy.keypair.secretKey, ct) }
        : {}),
    };
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

    // Security fix 2026-08 — end-to-end sender verification. `peer` is the
    // relay-asserted sender pubkey; verify `sig` against it. Three outcomes:
    //   sig present + valid    → deliver, flip the peer's ratchet once.
    //   sig present + INVALID  → DROP always (relay tampering or corruption —
    //                           never deliver a frame whose signature fails).
    //   sig absent             → deliver only if the peer hasn't demonstrated
    //                           signing support yet (legacy transition).
    // Stays synchronous: the ratchet is an in-memory cache warmed at relay
    // start, so handlers still reply within the same tick.
    const policy = this.sigPolicy;
    if (policy) {
      if (typeof outer.sig === "string" && outer.sig.length > 0) {
        const verdict = verifyInnerSig(outer.peer, outer.ct, outer.sig);
        if (!verdict.ok) return;
        policy.onSignatureVerified(outer.peer);
        this._deliver(outer.ct);
        return;
      }
      if (policy.requiresSignature(outer.peer)) return; // ratcheted, unsigned — drop
    }
    this._deliver(outer.ct);
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

    this.onMessage(msg as ClientMessage);
  }
}
