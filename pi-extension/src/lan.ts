import { networkInterfaces } from "node:os";

/**
 * LAN address discovery for the default single-WLAN setup.
 *
 * Piper's default topology is a relay running on this machine, reached by the
 * phone over the local network. The extension itself talks to that relay over
 * loopback, but loopback is meaningless to the phone — the pairing QR has to
 * carry an address that is reachable from the other side of the WLAN. That is
 * what this module resolves.
 */

/** Hosts that only ever resolve to this machine. */
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "::1", "[::1]"]);

/**
 * True for the IPv4 ranges reserved for private networks (RFC 1918).
 * Link-local (169.254/16, RFC 3927) is deliberately excluded: those addresses
 * appear when DHCP failed, and a QR pointing at one would not be routable.
 */
export function isPrivateIPv4(addr: string): boolean {
  const parts = addr.split(".").map((p) => Number.parseInt(p, 10));
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) {
    return false;
  }
  const [a, b] = parts as [number, number, number, number];
  if (a === 10) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  return false;
}

/**
 * Picks this machine's LAN IPv4, or null when there is none.
 *
 * Interface order is whatever the OS reports, which is not stable enough to
 * rely on when a machine is on Wi-Fi *and* Ethernet *and* has a VPN or Docker
 * bridge up. So the choice is narrowed rather than guessed:
 *
 *   - internal (loopback) interfaces are skipped
 *   - only RFC 1918 IPv4 qualifies (see `isPrivateIPv4`)
 *   - 192.168/16 wins over the other two, because a home/office WLAN is the
 *     target setup and 10/8 + 172.16/12 are what Docker, VPNs and corporate
 *     overlays typically hand out
 *
 * Ties inside a class are broken by interface order. When the pick is wrong
 * for a given machine, `REMOTE_PI_RELAY` overrides everything.
 */
export function detectLanIPv4(): string | null {
  const candidates: string[] = [];
  for (const addrs of Object.values(networkInterfaces())) {
    for (const addr of addrs ?? []) {
      if (addr.internal) continue;
      if (addr.family !== "IPv4") continue;
      if (!isPrivateIPv4(addr.address)) continue;
      candidates.push(addr.address);
    }
  }
  if (candidates.length === 0) return null;
  return candidates.find((a) => a.startsWith("192.168.")) ?? candidates[0]!;
}

/** True when the URL's host only resolves to this machine. */
export function isLoopbackUrl(url: string): boolean {
  try {
    return LOOPBACK_HOSTS.has(new URL(url).hostname.toLowerCase());
  } catch {
    return false;
  }
}

/**
 * Rewrites a loopback relay URL into one the phone can reach, preserving port
 * and scheme. Non-loopback URLs pass through untouched — if the user pointed
 * the extension at a real relay (public or a box elsewhere on the LAN), that
 * address is already the right one to advertise.
 *
 * Returns null when the URL is loopback and no LAN address exists (offline
 * machine, Wi-Fi down): there is nothing honest to put in the QR, and the
 * caller must say so rather than emit an unreachable address.
 */
export function toPhoneReachableUrl(
  url: string,
  lanIp: string | null = detectLanIPv4(),
): string | null {
  if (!isLoopbackUrl(url)) return url;
  if (lanIp === null) return null;
  try {
    const parsed = new URL(url);
    parsed.hostname = lanIp;
    return parsed.toString().replace(/\/$/, "");
  } catch {
    return null;
  }
}
