/**
 * Inner-envelope Ed25519 signatures (security fix 2026-08, review finding H1).
 *
 * The outer envelope `{peer, room?, ct, sig?}` is routed by the relay, which
 * asserts the SENDER's WS-auth pubkey in `peer`. Post-rollback (plan 06) the
 * `ct` payload is plaintext base64 — no cipher, no MAC — so a malicious or
 * compromised relay can read every inner message AND forge one: rewriting
 * `peer` is enough to impersonate a paired Owner.
 *
 * `sig` closes the forgery half (not confidentiality): the sender signs the
 * exact `ct` string with the SAME long-term Ed25519 key it used for the WS
 * handshake, and the recipient verifies against the relay-asserted sender
 * pubkey. A relay cannot forge a signature for a key it doesn't hold, so
 * "sender really controls that pubkey" becomes end-to-end instead of
 * relay-asserted. A relay can still DROP or STRIP signatures — the
 * transition-safe rollout accepts that (see peer_channel.ts): peers that have
 * demonstrated signing support (ratchet flag in peers.json) get their
 * unsigned frames dropped.
 *
 * Domain separation: the signature covers `DOMAIN_PREFIX || ct` (UTF-8), so a
 * signature can never be confused with the relay challenge-response nonce
 * signature or a mesh-blob signature, all of which use the same key.
 */

import { ed25519Sign, ed25519Verify } from "../pairing/crypto.js";
import { decodeEd25519PublicKey } from "../mesh/encoding.js";

/** Domain prefix — MUST match `kInnerSigDomain` in the app (ws_transport.dart). */
export const DOMAIN_PREFIX = "piper/inner/v1\n";

/** Ed25519 signatures are always 64 bytes. */
export const ED25519_SIG_B64_LEN = 88; // base64(64) with padding

/** Builds the exact bytes covered by an inner-envelope signature. */
export function signedBytes(ct: string): Uint8Array {
  return Buffer.from(DOMAIN_PREFIX + ct, "utf8");
}

/**
 * Signs `ct` with the sender's Ed25519 secret key. Returns base64 (standard,
 * padded) — the wire form of `sig`.
 */
export function signInnerCt(secretKey: Uint8Array, ct: string): string {
  return Buffer.from(ed25519Sign(secretKey, signedBytes(ct))).toString("base64");
}

export type VerifyInnerResult =
  | { ok: true }
  | { ok: false; reason: "bad_pubkey" | "bad_sig_b64" | "mismatch" };

/**
 * Verifies `sigB64` over `ct` against the sender's Ed25519 public key
 * (standard or base64url, 32 bytes). Pure — no I/O, no throws.
 */
export function verifyInnerSig(
  senderPkB64: string,
  ct: string,
  sigB64: string,
): VerifyInnerResult {
  let pk: Uint8Array;
  try {
    pk = decodeEd25519PublicKey(senderPkB64, "inner-envelope sender key");
  } catch {
    return { ok: false, reason: "bad_pubkey" };
  }
  if (typeof sigB64 !== "string" || sigB64.length === 0) {
    return { ok: false, reason: "bad_sig_b64" };
  }
  const sig = Buffer.from(sigB64, "base64");
  if (sig.length !== 64) return { ok: false, reason: "bad_sig_b64" };
  return ed25519Verify(pk, signedBytes(ct), sig)
    ? { ok: true }
    : { ok: false, reason: "mismatch" };
}
