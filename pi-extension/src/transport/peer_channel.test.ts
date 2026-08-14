/**
 * Security fix 2026-08 — unit tests for inner-envelope signatures
 * (transport/inner_sig.ts) and the PlainPeerChannel signing/verification
 * policy wiring.
 */
import { describe, expect, test, vi } from "vitest";
import { EventEmitter } from "node:events";
import { generateEd25519Keypair } from "../pairing/crypto.js";
import {
  DOMAIN_PREFIX,
  signInnerCt,
  verifyInnerSig,
} from "../transport/inner_sig.js";
import { PlainPeerChannel } from "../transport/peer_channel.js";
import type { ClientMessage, ServerMessage } from "../protocol/types.js";

class MockRelay extends EventEmitter {
  send = vi.fn();
}

const senderKp = generateEd25519Keypair();
const piKp = generateEd25519Keypair();
const senderPk = Buffer.from(senderKp.publicKey).toString("base64");

function makeOuter(peer: string, inner: object, sig?: string): string {
  const ct = Buffer.from(JSON.stringify(inner)).toString("base64");
  return JSON.stringify(sig ? { peer, ct, sig } : { peer, ct });
}

describe("inner_sig helpers", () => {
  test("sign → verify round-trips", () => {
    const ct = Buffer.from(JSON.stringify({ type: "pong", id: "x" })).toString("base64");
    const sig = signInnerCt(senderKp.secretKey, ct);
    expect(verifyInnerSig(senderPk, ct, sig)).toEqual({ ok: true });
  });

  test("signature does NOT verify for a different ct (rebinding)", () => {
    const ctA = Buffer.from('{"type":"a"}').toString("base64");
    const ctB = Buffer.from('{"type":"b"}').toString("base64");
    const sig = signInnerCt(senderKp.secretKey, ctA);
    expect(verifyInnerSig(senderPk, ctB, sig)).toEqual({ ok: false, reason: "mismatch" });
  });

  test("signature does not verify under another key", () => {
    const ct = Buffer.from('{"type":"a"}').toString("base64");
    const sig = signInnerCt(piKp.secretKey, ct);
    expect(verifyInnerSig(senderPk, ct, sig)).toEqual({ ok: false, reason: "mismatch" });
  });

  test("bad pubkey / bad sig b64 are rejected, never thrown", () => {
    const ct = Buffer.from('{"type":"a"}').toString("base64");
    const sig = signInnerCt(senderKp.secretKey, ct);
    expect(verifyInnerSig("not-a-key!", ct, sig)).toEqual({ ok: false, reason: "bad_pubkey" });
    expect(verifyInnerSig(senderPk, ct, "short")).toEqual({ ok: false, reason: "bad_sig_b64" });
  });

  test("domain prefix is versioned (wire stability)", () => {
    expect(DOMAIN_PREFIX).toBe("piper/inner/v1\n");
  });
});

describe("PlainPeerChannel + InnerSigPolicy", () => {
  test("outbound frames are signed when a policy is present", () => {
    const relay = new MockRelay();
    const ratchet = new Map<string, boolean>();
    const channel = new PlainPeerChannel(
      relay as never, "app-peer", "main", () => {}, undefined,
      {
        keypair: piKp,
        requiresSignature: (p) => ratchet.get(p) === true,
        onSignatureVerified: (p) => ratchet.set(p, true),
      },
    );
    channel.send({ type: "pong", in_reply_to: "q" } as ServerMessage);
    const outer = JSON.parse(relay.send.mock.calls[0]![0] as string) as { ct: string; sig: string };
    expect(typeof outer.sig).toBe("string");
    // The signature must verify against the Pi's public key.
    expect(verifyInnerSig(Buffer.from(piKp.publicKey).toString("base64"), outer.ct, outer.sig))
      .toEqual({ ok: true });
  });

  test("valid signature delivers and flips the ratchet", () => {
    const relay = new MockRelay();
    const ratchet = new Map<string, boolean>();
    const got: ClientMessage[] = [];
    new PlainPeerChannel(
      relay as never, senderPk, "main",
      (m) => got.push(m), undefined,
      {
        keypair: piKp,
        requiresSignature: (p) => ratchet.get(p) === true,
        onSignatureVerified: (p) => ratchet.set(p, true),
      },
    );
    const ct = Buffer.from(JSON.stringify({ type: "session_sync", id: "s1" })).toString("base64");
    relay.emit("message", JSON.stringify({ peer: senderPk, ct, sig: signInnerCt(senderKp.secretKey, ct) }));
    expect(got).toHaveLength(1);
    expect(ratchet.get(senderPk)).toBe(true);
  });

  test("invalid signature is dropped even pre-ratchet", () => {
    const relay = new MockRelay();
    const got: ClientMessage[] = [];
    new PlainPeerChannel(
      relay as never, senderPk, "main", (m) => got.push(m), undefined,
      {
        keypair: piKp,
        requiresSignature: () => false,
        onSignatureVerified: () => {},
      },
    );
    const ct = Buffer.from(JSON.stringify({ type: "user_message", id: "u1" })).toString("base64");
    const wrongKey = generateEd25519Keypair();
    relay.emit("message", JSON.stringify({ peer: senderPk, ct, sig: signInnerCt(wrongKey.secretKey, ct) }));
    expect(got).toHaveLength(0);
  });

  test("unsigned frame delivers pre-ratchet, drops after the ratchet flips", () => {
    const relay = new MockRelay();
    const ratchet = new Map<string, boolean>();
    const got: ClientMessage[] = [];
    new PlainPeerChannel(
      relay as never, senderPk, "main", (m) => got.push(m), undefined,
      {
        keypair: piKp,
        requiresSignature: (p) => ratchet.get(p) === true,
        onSignatureVerified: (p) => ratchet.set(p, true),
      },
    );
    // Pre-ratchet: legacy unsigned frame delivers (transition-safe).
    relay.emit("message", makeOuter(senderPk, { type: "session_sync", id: "s1" }));
    expect(got).toHaveLength(1);
    // A signed frame flips the ratchet…
    const ct = Buffer.from(JSON.stringify({ type: "session_sync", id: "s2" })).toString("base64");
    relay.emit("message", JSON.stringify({ peer: senderPk, ct, sig: signInnerCt(senderKp.secretKey, ct) }));
    expect(got).toHaveLength(2);
    // …and from now on unsigned frames are dropped (relay strip attack).
    relay.emit("message", makeOuter(senderPk, { type: "user_message", id: "u1" }));
    expect(got).toHaveLength(2);
  });

  test("no policy = legacy wire format (unsigned out, unsigned in)", () => {
    const relay = new MockRelay();
    const got: ClientMessage[] = [];
    const channel = new PlainPeerChannel(
      relay as never, senderPk, "main", (m) => got.push(m), undefined,
    );
    channel.send({ type: "pong", in_reply_to: "q" } as ServerMessage);
    const outer = JSON.parse(relay.send.mock.calls[0]![0] as string) as Record<string, unknown>;
    expect("sig" in outer).toBe(false);
    relay.emit("message", makeOuter(senderPk, { type: "session_sync", id: "s1" }));
    expect(got).toHaveLength(1);
  });
});
