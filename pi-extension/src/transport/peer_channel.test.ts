/**
 * Security fix 2026-08 + PR #24 review follow-up — unit tests for
 * inner-envelope signatures (transport/inner_sig.ts) and the PlainPeerChannel
 * signing/verification policy wiring.
 *
 * Covers the three review findings:
 *   #1 replay — v2 timestamp window + inner-id dedup
 *   #2 cross-peer injection — v2 recipient binding (signed-for-A fails on B)
 *   #4 ratchet race — flip on sig-present, before/synchronously with verify
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
  verifyInnerEnvelope,
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

function signedV2Frame(
  from: string,
  inner: object,
  dest: string,
  ts = NOW,
  id?: string,
): string {
  const ct = ctOf(id ? inner : inner);
  const sig = signInnerCtV2(ownerKp.secretKey, dest, ts, ct);
  return JSON.stringify({ peer: from, ct, sig, ts });
}

function unsignedFrame(from: string, inner: object): string {
  return JSON.stringify({ peer: from, ct: ctOf(inner) });
}

/** Policy factory matching the InnerSigPolicy interface. */
function makePolicy(overrides: {
  ownPeerId?: string;
  ratchet?: Set<string>;
} = {}) {
  const ratchet = overrides.ratchet ?? new Set<string>();
  return {
    keypair: piAKp,
    ownPeerId: overrides.ownPeerId ?? piAId,
    now: () => NOW,
    requiresSignature: (p: string) => ratchet.has(p),
    onSignaturePresent: (p: string) => ratchet.add(p),
    onSignatureVerified: vi.fn(),
  };
}

describe("inner_sig helpers (v1/v2)", () => {
  test("v2 sign → verify round-trips for the intended recipient", () => {
    const ct = ctOf({ type: "pong", id: "x" });
    const sig = signInnerCtV2(ownerKp.secretKey, piAId, NOW, ct);
    expect(verifyInnerSigV2(ownerPk, piAId, NOW, ct, sig, NOW)).toEqual({
      ok: true,
      version: 2,
    });
  });

  test("#2 cross-peer: a frame signed for Pi A does NOT verify on Pi B", () => {
    const ct = ctOf({ type: "user_message", id: "u1", text: "rm -rf" });
    const sigForA = signInnerCtV2(ownerKp.secretKey, piAId, NOW, ct);
    // Pi B (same owner pubkey) receives the frame relay-redirected to it.
    expect(verifyInnerSigV2(ownerPk, piBId, NOW, ct, sigForA, NOW)).toEqual({
      ok: false,
      reason: "mismatch",
    });
  });

  test("#1 replay: stale timestamp is rejected", () => {
    const ct = ctOf({ type: "user_message", id: "u2" });
    const old = NOW - MAX_AGE_MS - 1_000;
    const sig = signInnerCtV2(ownerKp.secretKey, piAId, old, ct);
    expect(verifyInnerSigV2(ownerPk, piAId, old, ct, sig, NOW)).toEqual({
      ok: false,
      reason: "stale",
    });
    // Just inside the window still passes.
    const edge = NOW - MAX_AGE_MS + 1_000;
    const sigEdge = signInnerCtV2(ownerKp.secretKey, piAId, edge, ct);
    expect(verifyInnerSigV2(ownerPk, piAId, edge, ct, sigEdge, NOW)).toEqual({
      ok: true,
      version: 2,
    });
  });

  test("verifyInnerEnvelope dispatches on ts presence (v2 strict, v1 legacy)", () => {
    const ct = ctOf({ type: "pong", id: "p" });
    const v1 = signInnerCt(ownerKp.secretKey, ct);
    expect(verifyInnerEnvelope(ownerPk, piAId, ct, v1, undefined, NOW)).toEqual({
      ok: true,
      version: 1,
    });
    // A ts-bearing frame with a v1 sig must NOT fall through to v1 —
    // v1 senders never emit ts.
    const v1Bytes = Buffer.from(DOMAIN_PREFIX + ct, "utf8");
    expect(verifyInnerEnvelope(ownerPk, piAId, ct, v1, NOW, NOW).ok).toBe(false);
    // Sanity: domain strings are pinned (wire stability).
    expect(DOMAIN_PREFIX).toBe("piper/inner/v1\n");
    expect(DOMAIN_PREFIX_V2).toBe("piper/inner/v2\n");
  });

  test("v1 still verifies standalone (transition)", () => {
    const ct = ctOf({ type: "pong", id: "p" });
    const sig = signInnerCt(ownerKp.secretKey, ct);
    expect(verifyInnerSig(ownerPk, ct, sig)).toEqual({ ok: true, version: 1 });
    // Rebinding (different ct) fails.
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

describe("PlainPeerChannel + InnerSigPolicy (v2)", () => {
  function makeChannel(policy: ReturnType<typeof makePolicy> | undefined) {
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

  test("outbound frames are v2-signed (dest = remote peer, ts attached)", () => {
    const { relay, channel } = makeChannel(makePolicy());
    channel.send({ type: "pong", in_reply_to: "q" } as ServerMessage);
    const outer = JSON.parse(relay.send.mock.calls[0]![0] as string) as {
      ct: string; sig: string; ts: number;
    };
    expect(typeof outer.ts).toBe("number");
    // Sig must verify as v2 for the REMOTE peer (the app) as recipient.
    expect(
      verifyInnerSigV2(
        Buffer.from(piAKp.publicKey).toString("base64"),
        ownerPk,
        outer.ts,
        outer.ct,
        outer.sig,
        NOW,
      ),
    ).toEqual({ ok: true, version: 2 });
  });

  test("valid v2 delivers and persists the ratchet", () => {
    const policy = makePolicy();
    const { relay, got } = makeChannel(policy);
    relay.emit("message", signedV2Frame(ownerPk, { type: "session_sync", id: "s1" }, piAId));
    expect(got).toHaveLength(1);
    expect(policy.onSignatureVerified).toHaveBeenCalledWith(ownerPk);
  });

  test("#2 cross-peer redirect is dropped: frame signed for Pi B, arriving at Pi A", () => {
    const policy = makePolicy();
    const { relay, got } = makeChannel(policy);
    // Relay forwards the owner's frame intended for Pi B to Pi A. The dest
    // in the signature is piBId — verification against Pi A's own id fails.
    relay.emit("message", signedV2Frame(ownerPk, { type: "user_message", id: "x1" }, piBId));
    expect(got).toHaveLength(0);
    expect(policy.onSignatureVerified).not.toHaveBeenCalled();
  });

  test("#1 replay: identical signed frame twice → second is dropped (id dedup)", () => {
    const { relay, got } = makeChannel(makePolicy());
    const frame = signedV2Frame(ownerPk, { type: "user_message", id: "same-id" }, piAId);
    relay.emit("message", frame);
    relay.emit("message", frame); // replayed verbatim by the relay
    expect(got).toHaveLength(1);
  });

  test("#1 replay: stale v2 frame is dropped even with a fresh id", () => {
    const { relay, got } = makeChannel(makePolicy());
    const old = NOW - MAX_AGE_MS - 60_000;
    const ct = ctOf({ type: "user_message", id: "fresh-id" });
    const sig = signInnerCtV2(ownerKp.secretKey, piAId, old, ct);
    relay.emit("message", JSON.stringify({ peer: ownerPk, ct, sig, ts: old }));
    expect(got).toHaveLength(0);
  });

  test("v1 frame is accepted (transition) and flips the unsigned-drop ratchet", () => {
    const policy = makePolicy();
    const { relay, got } = makeChannel(policy);
    const ct = ctOf({ type: "session_sync", id: "legacy-1" });
    const v1 = signInnerCt(ownerKp.secretKey, ct);
    relay.emit("message", JSON.stringify({ peer: ownerPk, ct, sig: v1 }));
    expect(got).toHaveLength(1); // v1 accepted — app 1.3.0 compat
    // Ratchet (unsigned-drop) flipped by sig presence; v2 persist NOT fired.
    expect(policy.onSignatureVerified).not.toHaveBeenCalled();
    // ...and unsigned frames from the same peer now drop.
    relay.emit("message", unsignedFrame(ownerPk, { type: "user_message", id: "legacy-2" }));
    expect(got).toHaveLength(1);
  });

  test("invalid signature is dropped even pre-ratchet", () => {
    const { relay, got } = makeChannel(makePolicy());
    const ct = ctOf({ type: "user_message", id: "u9" });
    const wrongKey = generateEd25519Keypair();
    const sig = signInnerCtV2(wrongKey.secretKey, piAId, NOW, ct);
    relay.emit("message", JSON.stringify({ peer: ownerPk, ct, sig, ts: NOW }));
    expect(got).toHaveLength(0);
  });

  test("#4 race: unsigned frame right after a valid signed frame is dropped (sync flip)", () => {
    const { relay, got } = makeChannel(makePolicy());
    relay.emit("message", signedV2Frame(ownerPk, { type: "session_sync", id: "r1" }, piAId));
    // Emitted in the SAME tick as the signed frame — the ratchet must
    // already be flipped synchronously (no async gap).
    relay.emit("message", unsignedFrame(ownerPk, { type: "user_message", id: "r2" }));
    expect(got).toHaveLength(1);
    expect(got[0]).toMatchObject({ type: "session_sync" });
  });

  test("unsigned delivers pre-ratchet only; no policy = legacy wire format", () => {
    const { relay, got, channel } = makeChannel(undefined);
    relay.emit("message", unsignedFrame(ownerPk, { type: "session_sync", id: "n1" }));
    expect(got).toHaveLength(1);
    channel.send({ type: "pong", in_reply_to: "q" } as ServerMessage);
    const outer = JSON.parse((relay.send.mock.calls[0]![0] as string)) as Record<string, unknown>;
    expect("sig" in outer).toBe(false);
    expect("ts" in outer).toBe(false);
  });
});
