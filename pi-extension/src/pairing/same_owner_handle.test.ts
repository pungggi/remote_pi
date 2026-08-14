/**
 * PR #24 review follow-up (#3) — canonical Owner-handle matching.
 *
 * peers.json deliberately preserves RAW pubkey spellings (standard base64 or
 * base64url, padded or not) while the relay asserts standard base64 peer ids.
 * Every lookup crossing that boundary (ratchet warm-up, markPeerSigning) must
 * match canonically — string equality silently misses and the enforcement
 * ratchet is lost on restart.
 */
import { describe, expect, test } from "vitest";
import { generateEd25519Keypair } from "./crypto.js";
import { sameOwnerHandle } from "./storage.js";

const kp = generateEd25519Keypair();
const std = Buffer.from(kp.publicKey).toString("base64");
const url = Buffer.from(kp.publicKey).toString("base64url");
const stdPadded = std; // 32-byte b64 is always padded to 44 chars incl '='
const other = Buffer.from(generateEd25519Keypair().publicKey).toString("base64");

describe("sameOwnerHandle (PR #24 follow-up #3)", () => {
  test("identical spellings match", () => {
    expect(sameOwnerHandle(std, std)).toBe(true);
    expect(sameOwnerHandle(url, url)).toBe(true);
  });

  test("standard ↔ base64url cross-encode match", () => {
    expect(sameOwnerHandle(std, url)).toBe(true);
    expect(sameOwnerHandle(url, stdPadded)).toBe(true);
  });

  test("different keys never match", () => {
    expect(sameOwnerHandle(std, other)).toBe(false);
    expect(sameOwnerHandle(url, other)).toBe(false);
  });

  test("garbage inputs are rejected, never thrown", () => {
    expect(sameOwnerHandle("garbage!!", std)).toBe(false);
    expect(sameOwnerHandle("", "")).toBe(true); // trivially equal, both empty
  });
});
