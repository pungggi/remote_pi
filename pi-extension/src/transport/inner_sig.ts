/**
 * Inner-envelope Ed25519 signatures (security fix 2026-08, review finding H1;
 * v2 dest-binding + replay windows from PR #24 review follow-up).
 *
 * The outer envelope `{peer, room?, ct, sig?, ts?}` is routed by the relay,
 * which asserts the SENDER's WS-auth pubkey in `peer`. Post-rollback (plan 06)
 * the `ct` payload is plaintext base64 — no cipher, no MAC — so a malicious or
 * compromised relay can read every inner message AND forge one: rewriting
 * `peer` is enough to impersonate a paired Owner.
 *
 * `sig` closes the forgery half (not confidentiality). Two versions:
 *
 *  v1 (2026-08 initial): Ed25519("piper/inner/v1\n" + ct).
 *      Binds the SENDER only. Two gaps found in review: (a) the recipient is
 *      not bound — a relay can forward an owner-signed command intended for
 *      Pi A to Pi B of the same owner, where it verifies and executes; (b) no
 *      freshness — a captured signed frame replays forever.
 *
 *  v2 (this file's default): Ed25519("piper/inner/v2\n" + dest + "\n" + ts + "\n" + ct)
 *      where `dest` is the RECIPIENT's canonical standard-base64 pubkey and
 *      `ts` is the sender's epoch-ms, both carried on the outer envelope and
 *      inside the signature. A frame signed for Pi B fails verification on
 *      Pi A (dest mismatch) and vice versa; `ts` bounds replay to the
 *      freshness window below (belt-and-suspenders: recipients also dedupe
 *      inner message ids — see PlainPeerChannel).
 *
 * Transition policy ("accept both", PR #24 follow-up): v2 is preferred and
 * flips the recipient's enforcement ratchet; v1 frames are still ACCEPTED
 * (peers on app 1.3.0 speak only v1) but never treated as v2. Unsigned frames
 * are dropped once a peer's ratchet is on — a relay cannot strip its way back
 * to impersonation, and cannot "downgrade" a v2 peer either (a v2 frame
 * re-signed as v1 is cryptographically impossible; the sig bytes differ).
 *
 * Domain separation: both prefixes ensure a signature can never be confused
 * with the relay challenge-response nonce signature or a mesh-blob signature,
 * all of which use the same key.
 */

import { ed25519Sign, ed25519Verify } from "../pairing/crypto.js";
import { decodeEd25519PublicKey } from "../mesh/encoding.js";

/** v1 domain prefix — MUST match `kInnerSigDomain` in the app. @deprecated v2 */
export const DOMAIN_PREFIX = "piper/inner/v1\n";

/** v2 domain prefix — MUST match `kInnerSigDomainV2` in the app. */
export const DOMAIN_PREFIX_V2 = "piper/inner/v2\n";

/**
 * Replay freshness window. A v2 signature older than this (sender clock) is
 * rejected. Generous enough for clock skew between phone and PC; short
 * enough that a captured frame is not usefully replayable later.
 */
export const MAX_AGE_MS = 10 * 60 * 1000;

/** Ed25519 signatures are always 64 bytes. */
export const ED25519_SIG_B64_LEN = 88; // base64(64) with padding

/** Builds the exact bytes covered by a v1 inner-envelope signature. */
export function signedBytes(ct: string): Uint8Array {
  return Buffer.from(DOMAIN_PREFIX + ct, "utf8");
}

/** Builds the exact bytes covered by a v2 inner-envelope signature:
 *  domain || dest-pubkey(b64) || "\n" || epoch-ms || "\n" || ct. */
export function signedBytesV2(destB64: string, ts: number, ct: string): Uint8Array {
  return Buffer.from(
    DOMAIN_PREFIX_V2 + destB64 + "\n" + String(ts) + "\n" + ct,
    "utf8",
  );
}

/**
 * v1 sign — retained for tests and transition documentation. Production code
 * signs with [signInnerCtV2].
 */
export function signInnerCt(secretKey: Uint8Array, ct: string): string {
  return Buffer.from(ed25519Sign(secretKey, signedBytes(ct))).toString("base64");
}

/** v2 sign over dest || ts || ct with the sender's Ed25519 secret key. */
export function signInnerCtV2(
  secretKey: Uint8Array,
  destB64: string,
  ts: number,
  ct: string,
): string {
  return Buffer
    .from(ed25519Sign(secretKey, signedBytesV2(destB64, ts, ct)))
    .toString("base64");
}

export type VerifyInnerResult =
  | { ok: true; version: 1 | 2 }
  | { ok: false; reason: "bad_pubkey" | "bad_sig_b64" | "mismatch" | "stale" | "bad_ts" };

function decodePk(senderPkB64: string): Uint8Array | null {
  try {
    return decodeEd25519PublicKey(senderPkB64, "inner-envelope sender key");
  } catch {
    return null;
  }
}

function decodeSig(sigB64: string): Uint8Array | null {
  if (typeof sigB64 !== "string" || sigB64.length === 0) return null;
  const sig = Buffer.from(sigB64, "base64");
  return sig.length === 64 ? sig : null;
}

/**
 * Verifies a v2 `sig` over dest || ts || ct against the sender's public key
 * (standard or base64url, 32 bytes). `ownPkB64` is the RECIPIENT's own pubkey —
 * the dest binding: a frame signed for a different recipient fails here even
 * though the sender key matches. Pure — no I/O, no throws.
 */
export function verifyInnerSigV2(
  senderPkB64: string,
  ownPkB64: string,
  ts: number,
  ct: string,
  sigB64: string,
  nowMs: number,
): VerifyInnerResult {
  const pk = decodePk(senderPkB64);
  if (!pk) return { ok: false, reason: "bad_pubkey" };
  const sig = decodeSig(sigB64);
  if (!sig) return { ok: false, reason: "bad_sig_b64" };
  if (!Number.isFinite(ts)) return { ok: false, reason: "bad_ts" };
  if (Math.abs(nowMs - ts) > MAX_AGE_MS) return { ok: false, reason: "stale" };
  return ed25519Verify(pk, signedBytesV2(ownPkB64, ts, ct), sig)
    ? { ok: true, version: 2 }
    : { ok: false, reason: "mismatch" };
}

/**
 * Verifies a v1 `sig` over ct (legacy, sender-bound only). Pure.
 */
export function verifyInnerSig(
  senderPkB64: string,
  ct: string,
  sigB64: string,
): VerifyInnerResult {
  const pk = decodePk(senderPkB64);
  if (!pk) return { ok: false, reason: "bad_pubkey" };
  const sig = decodeSig(sigB64);
  if (!sig) return { ok: false, reason: "bad_sig_b64" };
  return ed25519Verify(pk, signedBytes(ct), sig)
    ? { ok: true, version: 1 }
    : { ok: false, reason: "mismatch" };
}

/**
 * Full inbound policy for one outer envelope. Tries v2 first (requires the
 * frame's `ts` and the recipient's own pubkey), falls back to v1. Callers use
 * the returned version to decide ratcheting (v2-only) and replay handling
 * (v2 already window-checked here).
 */
export function verifyInnerEnvelope(
  senderPkB64: string,
  ownPkB64: string,
  ct: string,
  sigB64: string,
  tsRaw: unknown,
  nowMs: number,
): VerifyInnerResult {
  // A frame carrying a numeric ts is v2 by construction (v1 senders never
  // emit one) — verify strictly as v2, including the freshness window. A
  // frame without ts is v1 (legacy transition).
  if (typeof tsRaw === "number" && Number.isFinite(tsRaw)) {
    return verifyInnerSigV2(senderPkB64, ownPkB64, tsRaw, ct, sigB64, nowMs);
  }
  return verifyInnerSig(senderPkB64, ct, sigB64);
}
