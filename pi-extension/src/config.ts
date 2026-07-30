import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const CONFIG_DIR = path.join(os.homedir(), ".pi", "piper");
const CONFIG_FILE = path.join(CONFIG_DIR, "config.json");

/**
 * Default relay: one running on this machine, reached over loopback.
 *
 * Piper's default topology is phone and Pi on the same WLAN with the relay
 * next to the Pi, so no traffic and no pairing metadata leaves the network.
 * The extension connects over loopback because that is the most robust route
 * to a process on the same host — it survives the machine changing IP,
 * roaming between networks, or having no LAN at all.
 *
 * The phone cannot use this address. The pairing QR advertises the LAN form
 * instead (see `lan.ts` / `toPhoneReachableUrl`).
 *
 * **There is no public relay constant.** Piper operates none, and the one the
 * upstream project runs used to sit here as an "escape hatch" — which meant the
 * documented answer to "reach my Pi from outside the WLAN" was a third party's
 * server, seeing every envelope in plaintext. Outside access is solved by
 * putting both ends on the same overlay network (Tailscale, WireGuard) and
 * pointing this at the overlay address, so the relay stays yours.
 *
 * Stored in canonical http(s):// form — conversion to ws(s):// happens at the
 * transport layer (see `toWebSocketUrl`).
 */
export const kDefaultRelayUrl = "http://127.0.0.1:3000";

export type RemotePiConfig = {
  relay?: string;
  /** See `resolveAdvertisedRelayUrl` — the address the pairing QR carries. */
  advertise?: string;
  /** Plan/121 — roots scanned for project discovery (phone's Projects list).
   *  `~/source` by default. */
  projects?: { roots?: string[] };
};

export function loadConfig(): RemotePiConfig {
  try {
    const raw = fs.readFileSync(CONFIG_FILE, "utf8");
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== "object") return {};
    return parsed as RemotePiConfig;
  } catch {
    return {};
  }
}

export function saveConfig(patch: Partial<RemotePiConfig>): void {
  fs.mkdirSync(CONFIG_DIR, { recursive: true });
  const current = loadConfig();
  const next = { ...current, ...patch };
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(next, null, 2));
}

export type RelayResolution = { url: string; source: "env" | "config" | "default" };

/**
 * Resolves the effective relay URL in **canonical http(s):// form**.
 *
 * Precedence:
 *   1. `REMOTE_PI_RELAY` env var (ops/CI escape hatch)
 *   2. `~/.pi/piper/config.json` `relay` field (set via /remote-pi set-relay)
 *   3. `kDefaultRelayUrl` (community default)
 *
 * Any ws(s):// values found (legacy configs or env overrides) are coerced
 * to http(s):// defensively — the canonical form across the codebase is
 * http(s)://, and the transport layer converts to ws(s):// at WS-open time.
 */
export function resolveRelayUrl(): RelayResolution {
  const env = process.env["REMOTE_PI_RELAY"];
  if (env && env.length > 0) return { url: toHttpUrl(env), source: "env" };
  const cfg = loadConfig();
  if (cfg.relay && cfg.relay.length > 0) return { url: toHttpUrl(cfg.relay), source: "config" };
  return { url: toHttpUrl(kDefaultRelayUrl), source: "default" };
}

/**
 * Resolves the address the pairing QR should advertise, or null when there is
 * none to advertise honestly.
 *
 * This is deliberately **separate from the relay URL the extension connects
 * to**. Those two answer different questions:
 *
 *   - `resolveRelayUrl` — how does *this process* reach the relay? Loopback is
 *     the best answer whenever the relay runs here: it survives the machine
 *     changing IP, roaming between networks, and having no LAN at all.
 *   - this function — what address does the *phone* dial? Loopback is
 *     meaningless there, so it needs a routable one.
 *
 * Collapsing them costs robustness. Reaching the relay from outside the WLAN
 * means advertising an overlay address (Tailscale, WireGuard), and without
 * this split the only way to get that into the QR was to point the extension
 * itself at the overlay — so a stopped VPN daemon took the local connection
 * down with it, over an interface it never needed.
 *
 * Precedence:
 *   1. `REMOTE_PI_ADVERTISE` env var (ops/CI escape hatch)
 *   2. `~/.pi/piper/config.json` `advertise` field (`/remote-pi set-advertise`)
 *   3. the relay URL, rewritten from loopback to this machine's LAN address
 *      (see `lan.ts` / `toPhoneReachableUrl`) — the plan/102 default
 *
 * Returns null only in case 3, when the relay URL is loopback and no LAN
 * address exists (Wi-Fi down, only virtual interfaces). The caller then emits
 * a QR without `r` rather than one pointing at an unreachable address.
 */
/**
 * Plan/121 — roots scanned by `discoverProjects` to build the phone's
 * Projects list. Precedence:
 *   1. `REMOTE_PI_PROJECTS_ROOTS` env (split on the platform path delimiter —
 *      `;` on Windows so drive-prefixed paths like `C:\dev` stay intact);
 *   2. `~/.pi/piper/config.json` `projects.roots`;
 *   3. `kDefaultProjectsRoots` (`["~/source"]`).
 * `~` is expanded to the user home. Empty/garbage entries are dropped.
 */
export const kDefaultProjectsRoots = ["~/source"];

function expandTilde(p: string): string {
  if (p === "~") return os.homedir();
  if (p.startsWith("~/") || p.startsWith("~\\")) return path.join(os.homedir(), p.slice(2));
  return p;
}

export function projectsRoots(): string[] {
  const env = process.env["REMOTE_PI_PROJECTS_ROOTS"];
  if (env && env.trim().length > 0) {
    return env
      .split(path.delimiter)
      .map((s) => expandTilde(s.trim()))
      .filter((s) => s.length > 0);
  }
  const cfg = loadConfig();
  const roots = cfg.projects?.roots;
  if (Array.isArray(roots) && roots.length > 0) {
    return roots
      .filter((r): r is string => typeof r === "string" && r.length > 0)
      .map(expandTilde);
  }
  return kDefaultProjectsRoots.map(expandTilde);
}

export function resolveAdvertisedRelayUrl(
  rewriteForPhone: (url: string) => string | null,
): string | null {
  const env = process.env["REMOTE_PI_ADVERTISE"];
  if (env && env.length > 0) return toHttpUrl(env);
  const cfg = loadConfig();
  if (cfg.advertise && cfg.advertise.length > 0) return toHttpUrl(cfg.advertise);
  return rewriteForPhone(resolveRelayUrl().url);
}

/**
 * Strict validator for **user-provided** relay URLs (via `/remote-pi
 * set-relay` or `/remote-pi relay url`).
 *
 * Only accepts `http://` and `https://`. `ws://`/`wss://` are deliberately
 * **rejected** — the canonical form stored in config is http(s):// and the
 * extension converts to ws(s):// internally when opening the WebSocket.
 * Forcing a single scheme at the user boundary avoids two-form drift.
 */
export function isValidRelayUrl(url: string): boolean {
  if (!url) return false;
  const lower = url.toLowerCase();
  if (!lower.startsWith("http://") && !lower.startsWith("https://")) return false;
  try { new URL(url); return true; } catch { return false; }
}

/**
 * Returns true if the URL uses ws:// or wss:// scheme — for emitting a
 * targeted error message when the user pastes a WebSocket URL by mistake.
 */
export function isWebSocketScheme(url: string): boolean {
  const lower = url.toLowerCase();
  return lower.startsWith("ws://") || lower.startsWith("wss://");
}

/**
 * Converts an http(s):// URL to the corresponding ws(s):// form. Used by
 * the transport layer right before opening the WebSocket — config storage
 * and the mesh HTTP client both stay on http(s)://.
 *
 *   https://host  → wss://host
 *   http://host   → ws://host
 *   ws(s)://host  → pass-through (defensive — env overrides or legacy
 *                   configs may still carry ws(s)://)
 */
export function toWebSocketUrl(url: string): string {
  const lower = url.toLowerCase();
  if (lower.startsWith("https://")) return "wss://" + url.slice("https://".length);
  if (lower.startsWith("http://"))  return "ws://"  + url.slice("http://".length);
  return url;
}

/**
 * Inverse of `toWebSocketUrl`. Used by `resolveRelayUrl` to coerce any
 * ws(s):// values back to canonical http(s):// before returning them to
 * the rest of the codebase.
 */
export function toHttpUrl(url: string): string {
  const lower = url.toLowerCase();
  if (lower.startsWith("wss://")) return "https://" + url.slice("wss://".length);
  if (lower.startsWith("ws://"))  return "http://"  + url.slice("ws://".length);
  return url;
}
