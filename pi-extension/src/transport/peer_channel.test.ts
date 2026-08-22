/**
 * Security fix 2026-08 + PR #24/#25 review follow-ups — unit tests for
 * inner-envelope signatures (transport/inner_sig.ts) and the PlainPeerChannel
 * dual-sign / verification policy wiring.
 *
 * Review findings covered:
 *   #24-1 replay — v2 timestamp window + policy-level id dedup
 *   #24-2 cross-peer injection — v2 recipient binding
 *   #24-4 ratchet race — flip on sig-present, synchronously
 *   #25-1 dual-sign interop — v1 `sig` kept for legacy recipients; v2
 *        preferred; downgrade strip (sig2 removed) drops after v2 ratchet
 *   #25-3 reconnect replay — dedup lives with the policy, not the channel
 */
import { describe, expect, test, vi } from "vitest";
import { EventEmitter } from "node:events";
import { generateEd25519Keypair } from "../pairing/crypto.js";
import {
  DOMAIN_PREFIX,
  DOMAIN_PREFIX_V2,
  MAX_AGE_MS,
  signInnerCt,
  signInnerCtV2,
  verifyInnerDual,
  verifyInnerSig,
  verifyInnerSigV2,
} from "../transport/inner_sig.js";
import { PlainPeerChannel } from "../transport/peer_channel.js";
import type { ClientMessage, ServerMessage } from "../protocol/types.js";

class MockRelay extends EventEmitter {
  send = vi.fn();
}

const ownerKp = generateEd25519Keypair(); // the app/owner (sender)
const piAKp = generateEd25519Keypair(); // this Pi (recipient)
const piBKp = generateEd25519Keypair(); // a DIFFERENT Pi of the same owner
const ownerPk = Buffer.from(ownerKp.publicKey).toString("base64");
const piAId = Buffer.from(piAKp.publicKey).toString("base64");
const piBId = Buffer.from(piBKp.publicKey).toString("base64");

const NOW = 1_739_577_600_000;

function ctOf(inner: object): string {
  return Buffer.from(JSON.stringify(inner)).toString("base64");
}

/** Dual-signed frame from the owner (what a new app/Pi sends). */
function dualFrame(from: string, inner: object, dest: string, ts = NOW): string {
  const ct = ctOf(inner);
  return JSON.stringify({
    peer: from,
    ct,
    sig: signInnerCt(ownerKp.secretKey, ct),
    sig2: signInnerCtV2(ownerKp.secretKey, dest, ts, ct),
    ts,
  });
}

/** v1-only frame (legacy sender, or a relay that STRIPPED sig2+ts). */
function v1Frame(from: string, inner: object): string {
  const ct = ctOf(inner);
  return JSON.stringify({ peer: from, ct, sig: signInnerCt(ownerKp.secretKey, ct) });
}

function unsignedFrame(from: string, inner: object): string {
  return JSON.stringify({ peer: from, ct: ctOf(inner) });
}

/** Policy factory matching the InnerSigPolicy interface. */
function makePolicy(opts: { ownPeerId?: string } = {}) {
  const ratchet = new Set<string>();
  const v2 = new Set<string>();
  const seen = new Set<string>();
  return {
    keypair: piAKp,
    ownPeerId: opts.ownPeerId ?? piAId,
    now: () => NOW,
    requiresSignature: (p: string) => ratchet.has(p),
    peerV2: (p: string) => v2.has(p),
    seenId: (_p: string, id: string) => {
      if (seen.has(id)) return true;
      seen.add(id);
      return false;
    },
    onSignaturePresent: (p: string) => ratchet.add(p),
    onV2Verified: (p: string) => v2.add(p),
    onSignatureVerified: vi.fn(),
    // expose internals for assertions
    _ratchet: ratchet,
    _v2: v2,
  };
}

function makeChannel(policy?: ReturnType<typeof makePolicy>) {
  const relay = new MockRelay();
  const got: ClientMessage[] = [];
  const channel = new PlainPeerChannel(
    relay as never,
    ownerPk,
    "main",
    (m) => got.push(m),
    undefined,
    policy ?? undefined,
  );
  return { relay, got, channel };
}

describe("inner_sig helpers (v1/v2 + dual)", () => {
  test("v2 sign → verify round-trips for the intended recipient", () => {
    const ct = ctOf({ type: "pong", id: "x" });
    const sig = signInnerCtV2(ownerKp.secretKey, piAId, NOW, ct);
    expect(verifyInnerSigV2(ownerPk, piAId, NOW, ct, sig, NOW)).toEqual({
      ok: true,
      version: 2,
    });
  });

  test("#24-2 cross-peer: a frame signed for Pi A does NOT verify on Pi B", () => {
    const ct = ctOf({ type: "user_message", id: "u1", text: "rm -rf" });
    const sigForA = signInnerCtV2(ownerKp.secretKey, piAId, NOW, ct);
    expect(verifyInnerSigV2(ownerPk, piBId, NOW, ct, sigForA, NOW)).toEqual({
      ok: false,
      reason: "mismatch",
    });
  });

  test("#24-1 replay: stale timestamp is rejected; window edge passes", () => {
    const ct = ctOf({ type: "user_message", id: "u2" });
    const old = NOW - MAX_AGE_MS - 1_000;
    const sigOld = signInnerCtV2(ownerKp.secretKey, piAId, old, ct);
    expect(verifyInnerSigV2(ownerPk, piAId, old, ct, sigOld, NOW)).toEqual({
      ok: false,
      reason: "stale",
    });
    const edge = NOW - MAX_AGE_MS + 1_000;
    const sigEdge = signInnerCtV2(ownerKp.secretKey, piAId, edge, ct);
    expect(verifyInnerSigV2(ownerPk, piAId, edge, ct, sigEdge, NOW)).toEqual({
      ok: true,
      version: 2,
    });
  });

  test("verifyInnerDual prefers sig2 strictly; no v1 fallback when sig2 present", () => {
    const ct = ctOf({ type: "pong", id: "p" });
    const v1 = signInnerCt(ownerKp.secretKey, ct);
    // Valid v1 + GARBAGE sig2 → drop (tampered pair), never v1 fallback.
    expect(
      verifyInnerDual(ownerPk, piAId, ct, v1, "garbage!!", NOW, NOW).ok,
    ).toBe(false);
    // Valid v1 alone → legacy transition.
    expect(verifyInnerDual(ownerPk, piAId, ct, v1, undefined, undefined, NOW)).toEqual({
      ok: true,
      version: 1,
    });
    // No sigs at all.
    expect(
      verifyInnerDual(ownerPk, piAId, ct, undefined, undefined, undefined, NOW),
    ).toEqual({ ok: false, reason: "no_signature" });
    // Domain strings pinned (wire stability).
    expect(DOMAIN_PREFIX).toBe("piper/inner/v1\n");
    expect(DOMAIN_PREFIX_V2).toBe("piper/inner/v2\n");
  });

  test("v1 still verifies standalone (transition)", () => {
    const ct = ctOf({ type: "pong", id: "p" });
    const sig = signInnerCt(ownerKp.secretKey, ct);
    expect(verifyInnerSig(ownerPk, ct, sig)).toEqual({ ok: true, version: 1 });
    const other = ctOf({ type: "pong", id: "q" });
    expect(verifyInnerSig(ownerPk, other, sig)).toEqual({ ok: false, reason: "mismatch" });
  });

  test("bad pubkey / bad sig b64 rejected, never thrown", () => {
    const ct = ctOf({ type: "a" });
    const sig = signInnerCtV2(ownerKp.secretKey, piAId, NOW, ct);
    expect(verifyInnerSigV2("not-a-key!", piAId, NOW, ct, sig, NOW)).toEqual({
      ok: false,
      reason: "bad_pubkey",
    });
    expect(verifyInnerSigV2(ownerPk, piAId, NOW, ct, "short", NOW)).toEqual({
      ok: false,
      reason: "bad_sig_b64",
    });
  });
});

describe("PlainPeerChannel + InnerSigPolicy (dual-sign)", () => {
  test("#25-1 outbound frames carry BOTH sigs — legacy recipients keep verifying", () => {
    const { relay, channel } = makeChannel(makePolicy());
    channel.send({ type: "pong", in_reply_to: "q" } as ServerMessage);
    const outer = JSON.parse(relay.send.mock.calls[0]![0] as string) as {
      ct: string; sig: string; sig2: string; ts: number;
    };
    expect(typeof outer.ts).toBe("number");
    // v1 sig verifies as v1 (app 1.3.0 path).
    expect(verifyInnerSig(
      Buffer.from(piAKp.publicKey).toString("base64"),
      outer.ct,
      outer.sig,
    )).toEqual({ ok: true, version: 1 });
    // v2 sig verifies for the REMOTE peer as recipient.
    expect(verifyInnerSigV2(
      Buffer.from(piAKp.publicKey).toString("base64"),
      ownerPk,
      outer.ts,
      outer.ct,
      outer.sig2,
      NOW,
    )).toEqual({ ok: true, version: 2 });
  });

  test("valid dual frame delivers, ratchets, and marks the peer v2", () => {
    const policy = makePolicy();
    const { relay, got } = makeChannel(policy);
    relay.emit("message", dualFrame(ownerPk, { type: "session_sync", id: "s1" }, piAId));
    expect(got).toHaveLength(1);
    expect(policy.onSignatureVerified).toHaveBeenCalledWith(ownerPk);
    expect(policy._v2.has(ownerPk)).toBe(true);
  });

  test("#24-2 cross-peer redirect is dropped: dual frame signed for Pi B at Pi A", () => {
    const policy = makePolicy();
    const { relay, got } = makeChannel(policy);
    relay.emit("message", dualFrame(ownerPk, { type: "user_message", id: "x1" }, piBId));
    expect(got).toHaveLength(0);
    expect(policy.onSignatureVerified).not.toHaveBeenCalled();
  });

  test("#24-1 replay: identical dual frame twice → second dropped (policy dedup)", () => {
    const { relay, got } = makeChannel(makePolicy());
    const frame = dualFrame(ownerPk, { type: "user_message", id: "same-id" }, piAId);
    relay.emit("message", frame);
    relay.emit("message", frame); // replayed verbatim by the relay
    expect(got).toHaveLength(1);
  });

  // Regression (2026-08-22, ask_user stuck sheet): the app RETRIES an
  // `extension_ui_response` with the SAME id (the pi-ask flowId) after a
  // rejected answer. The policy-level seen-id LRU ate the retry, so the
  // bridge never saw it and the phone stayed stuck with no feedback.
  // Responses are idempotent at the pi-ask level and bypass the dedupe.
  test("extension_ui_response retry with the same id is DELIVERED twice", () => {
    const { relay, got } = makeChannel(makePolicy());
    const resp = (id: string) =>
      dualFrame(
        ownerPk,
        { type: "extension_ui_response", id, ask: { flow_id: id, kind: "answer", mode: "submit", answers: {} } },
        piAId,
      );
    relay.emit("message", resp("tool:tc_9"));
    relay.emit("message", resp("tool:tc_9")); // user retry — must deliver
    expect(got).toHaveLength(2);
    expect(got[0]?.type).toBe("extension_ui_response");
    expect(got[1]?.type).toBe("extension_ui_response");
    // Streaming state keeps full dedupe (same id, different type → dropped).
    const echo = dualFrame(ownerPk, { type: "user_message", id: "tool:tc_9" }, piAId);
    relay.emit("message", echo);
    relay.emit("message", echo);
    expect(got).toHaveLength(3);
  });

  test("#25-3 reconnect replay: dedup survives channel re-creation (policy-level)", () => {
    const policy = makePolicy();
    const first = makeChannel(policy);
    first.relay.emit("message", dualFrame(ownerPk, { type: "user_message", id: "reconnect-1" }, piAId));
    expect(first.got).toHaveLength(1);
    // Reconnect: a FRESH channel with the SAME policy receives the replay.
    const second = makeChannel(policy);
    second.relay.emit("message", dualFrame(ownerPk, { type: "user_message", id: "reconnect-1" }, piAId));
    expect(second.got).toHaveLength(0);
  });

  test("#25-3 deliverVerified routes through the same dedup pipeline", () => {
    const policy = makePolicy();
    const { got, channel } = makeChannel(policy);
    const ct = ctOf({ type: "user_message", id: "dv-1" });
    channel.deliverVerified(ct);
    expect(got).toHaveLength(1);
    channel.deliverVerified(ct); // reconnect-path replay of the same ct
    expect(got).toHaveLength(1);
  });

  test("#24-1 replay: stale dual frame dropped even with a fresh id", () => {
    const { relay, got } = makeChannel(makePolicy());
    const old = NOW - MAX_AGE_MS - 60_000;
    relay.emit("message", dualFrame(ownerPk, { type: "user_message", id: "fresh-id" }, piAId, old));
    expect(got).toHaveLength(0);
  });

  test("v1-only frame accepted pre-v2 (transition), flips unsigned-drop ratchet", () => {
    const policy = makePolicy();
    const { relay, got } = makeChannel(policy);
    relay.emit("message", v1Frame(ownerPk, { type: "session_sync", id: "legacy-1" }));
    expect(got).toHaveLength(1); // legacy sender — v1 path
    expect(policy.onSignatureVerified).not.toHaveBeenCalled(); // no persist on v1
    expect(policy._ratchet.has(ownerPk)).toBe(true); // unsigned-drop flipped
    // ...and unsigned frames from the same peer now drop.
    relay.emit("message", unsignedFrame(ownerPk, { type: "user_message", id: "legacy-2" }));
    expect(got).toHaveLength(1);
  });

  test("#25-1 downgrade strip: v1-only from a v2-ratcheted peer is dropped", () => {
    const policy = makePolicy();
    const { relay, got } = makeChannel(policy);
    // Peer demonstrates v2...
    relay.emit("message", dualFrame(ownerPk, { type: "session_sync", id: "v2-1" }, piAId));
    expect(got).toHaveLength(1);
    // ...then the relay strips sig2+ts from subsequent frames — drop.
    relay.emit("message", v1Frame(ownerPk, { type: "user_message", id: "stripped-1" }));
    expect(got).toHaveLength(1);
  });

  test("invalid v2 (garbage sig2) is dropped with NO v1 fallback", () => {
    const { relay, got } = makeChannel(makePolicy());
    const ct = ctOf({ type: "user_message", id: "u9" });
    relay.emit("message", JSON.stringify({
      peer: ownerPk,
      ct,
      sig: signInnerCt(ownerKp.secretKey, ct),
      sig2: "Z2FyYmFnZQ==", // valid b64, wrong bytes
      ts: NOW,
    }));
    expect(got).toHaveLength(0);
  });

  test("#24-4 race: unsigned frame right after a valid dual frame is dropped (sync flip)", () => {
    const { relay, got } = makeChannel(makePolicy());
    relay.emit("message", dualFrame(ownerPk, { type: "session_sync", id: "r1" }, piAId));
    relay.emit("message", unsignedFrame(ownerPk, { type: "user_message", id: "r2" }));
    expect(got).toHaveLength(1);
    expect(got[0]).toMatchObject({ type: "session_sync" });
  });

  test("no policy = legacy wire format (unsigned out, unsigned in)", () => {
    const { relay, got, channel } = makeChannel(undefined);
    relay.emit("message", unsignedFrame(ownerPk, { type: "session_sync", id: "n1" }));
    expect(got).toHaveLength(1);
    channel.send({ type: "pong", in_reply_to: "q" } as ServerMessage);
    const outer = JSON.parse((relay.send.mock.calls[0]![0] as string)) as Record<string, unknown>;
    expect("sig" in outer).toBe(false);
    expect("sig2" in outer).toBe(false);
    expect("ts" in outer).toBe(false);
  });
});
