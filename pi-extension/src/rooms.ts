import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";
import { defaultAgentName } from "./session/local_config.js";

/**
 * Plan/120 — the fixed relay room for the supervisor's **device daemon**.
 *
 * The device daemon is a background `pi --mode rpc` the supervisor always
 * spawns (alongside per-project daemons). It connects in this room so the
 * phone can route offline terminal-open requests to it even when no project
 * session is live. Routing still includes the pubkey, so there is no
 * cross-machine collision.
 *
 * The matching constant lives in the app (`kDeviceRoom`) — both sides must
 * agree on the literal.
 */
export const DEVICE_ROOM = "device";

/**
 * Deterministic room id derived from a cwd. Two Pi processes in the same
 * directory produce the same id; different cwds produce different ids
 * (with cryptographic-strength collision resistance). Symlinks are resolved
 * via `realpath` so `/a` and `/symlink-to-a` map to the same room.
 *
 * Format: first 12 chars of base64url(sha256(realpath)).
 */
export function roomIdForCwd(cwd: string): string {
  let target: string;
  try {
    target = realpathSync(cwd);
  } catch {
    // cwd doesn't exist (unlikely in production) — fallback to raw path.
    target = cwd;
  }
  return createHash("sha256").update(target).digest("base64url").slice(0, 12);
}

/**
 * THE single derivation of the App↔Pi `room_id` (plan/41) — keyed by
 * `(cwd, name)` so several agents in the SAME folder get distinct rooms (the
 * app then renders one tile per agent instead of merging them into one).
 *
 * Default-preserving: when `name` is absent OR equals `defaultAgentName(cwd)`
 * (an agent with no custom `agent_name`), it returns the LEGACY `roomIdForCwd`
 * EXACTLY — so a single unnamed agent's existing conversation is NOT re-keyed
 * on upgrade. A custom or `#N`-suffixed name → a name-scoped id (same formula
 * the cwd-lock uses).
 *
 * Using the ASSIGNED leaf name (the broker's `#N` on collision) disambiguates
 * even two unnamed agents: the 1st stays `folder` (== default → legacy room),
 * the 2nd becomes `folder#2` (≠ default → name-scoped room).
 *
 * INVARIANT: every callsite that derives the App↔Pi room for the same agent
 * MUST go through this function — otherwise the app would pair on a room the
 * Pi never announces.
 */
export function roomIdFor(cwd: string, name?: string): string {
  if (!name || name === defaultAgentName(cwd)) return roomIdForCwd(cwd);
  let target: string;
  try {
    target = realpathSync(cwd);
  } catch {
    target = cwd;
  }
  // NUL separator (U+0000): impossible in a POSIX path and stripped from any
  // sanitized name, so the cwd/name boundary is unambiguous.
  const sep = String.fromCharCode(0);
  return createHash("sha256").update(target + sep + name).digest("base64url").slice(0, 12);
}
