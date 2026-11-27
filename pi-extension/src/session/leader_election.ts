import { Server, Socket, createConnection, createServer } from "node:net";
import { chmodSync, existsSync, lstatSync, unlinkSync } from "node:fs";
import type { Stats } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";
import { usesNamedPipe } from "./ipc.js";

const MAX_ATTEMPTS = 20;
const BASE_BACKOFF_MS = 30;
const JITTER_MS = 70;
const PROBE_TIMEOUT_MS = 500;

/**
 * What tells two socket files at one path apart (POSIX): the inode on its
 * device. A named pipe (Windows) has no file, so there is nothing to compare.
 */
export interface SocketIdentity {
  dev: number;
  ino: number;
}

export type ProbeResult =
  | { ok: true; socket: Socket }
  | { ok: false; reason: "refused" | "timeout" | "error"; code?: string };

/** The half of `ProbeResult` that says why nothing answered. */
export type ProbeFailure = Extract<ProbeResult, { ok: false }>;

export type ElectionResult =
  | { role: "leader"; server: Server; identity: SocketIdentity | null }
  | { role: "follower"; socket: Socket };

export interface JoinOrLeadOptions {
  /** Runs after every probe, before the election acts on its result. A test
   *  seam for interleavings that are otherwise a matter of microseconds. */
  afterProbe?: (probe: ProbeResult) => void;
}

/**
 * UDS-based leader election. Tries to connect to `sockPath`; on failure, tries
 * to bind. If both lose the race (EADDRINUSE on bind, ECONNREFUSED on connect),
 * retries with jittered backoff.
 *
 * Returns the role + the live handle (server for leader, socket for follower).
 *
 * Issue #140 — what a failed probe proves. A bind fails while a socket FILE
 * still occupies the path, which is also what a crashed leader leaves behind.
 * So a joiner that cannot connect removes the file, and that removal must not
 * hit a socket another joiner has just bound: the first leader would keep its
 * clients and its relay bridge while nothing can reach it at the path, and the
 * host would have two brokers answering for it. Two rules keep that from
 * happening:
 *
 * - Only ECONNREFUSED is read as "nobody listens there". A probe that timed
 *   out or failed otherwise says nothing about staleness, so the path is left
 *   alone and probed again.
 * - The removal names the socket it condemned. The file's identity is read
 *   before the probe, and only that same inode is ever unlinked.
 *
 * The leader's socket identity is returned with it, so the leader can notice
 * later when the path no longer leads to its own socket.
 */
export async function joinOrLead(
  sockPath: string,
  opts: JoinOrLeadOptions = {},
): Promise<ElectionResult> {
  const pipe = usesNamedPipe();
  // Windows named pipes have no file to `existsSync`; always connect-probe
  // first and never `unlink` (the pipe auto-disappears when its owner exits).
  // POSIX keeps the existsSync fast-path + stale-socket cleanup.
  let lastProbe: ProbeFailure["reason"] | null = null;
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    if (pipe || existsSync(sockPath)) {
      const questioned = pipe ? null : socketIdentity(sockPath);
      const probe = await probeSocket(sockPath);
      opts.afterProbe?.(probe);
      if (probe.ok) return { role: "follower", socket: probe.socket };
      lastProbe = probe.reason;
      // Nothing was read before the probe (the file vanished under us), so
      // there is no socket this probe could have condemned.
      if (!pipe && probe.reason === "refused" && questioned) {
        removeStaleSock(sockPath, questioned);
      }
    }

    const server = await _tryBind(sockPath);
    if (server) {
      return { role: "leader", server, identity: pipe ? null : socketIdentity(sockPath) };
    }

    await delay(BASE_BACKOFF_MS + Math.random() * JITTER_MS);
  }
  const detail = lastProbe === null
    ? ""
    : lastProbe === "refused"
      ? " (the path stayed taken after every refused probe)"
      : ` (a listener is there but its probe ended in ${lastProbe})`;
  throw new Error(`leader election failed after ${MAX_ATTEMPTS} attempts: ${sockPath}${detail}`);
}

/**
 * Probes a UDS path: if a live listener responds, returns the connected
 * socket; otherwise why it did not. Exported so the cwd-lock primitive can
 * reuse it without duplicating the OS dance.
 */
export function probe(sockPath: string): Promise<ProbeResult> {
  return probeSocket(sockPath);
}

/** `probe` for callers that only care whether something answered. */
export function tryConnect(sockPath: string): Promise<Socket | null> {
  return probeSocket(sockPath).then((result) => (result.ok ? result.socket : null));
}

/**
 * Attempts to bind a UDS server on `sockPath`. Returns the live server on
 * success, null when the path is already held (EADDRINUSE) or any other
 * bind error. Caller is responsible for `unlink`ing a stale sock file
 * before retrying.
 */
export function tryBind(sockPath: string): Promise<Server | null> {
  return _tryBind(sockPath);
}

/** Identity of the socket file at `sockPath`, or null when the path holds no
 *  socket (missing, or some other kind of file). POSIX only. */
export function socketIdentity(sockPath: string): SocketIdentity | null {
  try {
    const stat = lstatSync(sockPath);
    return stat.isSocket() ? { dev: stat.dev, ino: stat.ino } : null;
  } catch {
    return null;
  }
}

/** Whether `stat` describes the socket file `identity` was read from. */
function isSocketIdentity(identity: SocketIdentity, stat: Stats): boolean {
  return stat.isSocket() && stat.dev === identity.dev && stat.ino === identity.ino;
}

/**
 * Unlinks the sock file at `sockPath` when it is actually a socket. With
 * `identity`, only when it is still THAT socket: a file another process has
 * bound in the meantime belongs to that process. Returns whether a file was
 * removed. No-op on Windows, where the pipe has no file.
 */
export function removeStaleSock(sockPath: string, identity?: SocketIdentity): boolean {
  if (usesNamedPipe()) return false;
  return _removeStaleSock(sockPath, identity);
}

function probeSocket(sockPath: string): Promise<ProbeResult> {
  return new Promise((resolve) => {
    const sock = createConnection({ path: sockPath });
    let settled = false;
    const settle = (result: ProbeResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (!result.ok) sock.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => settle({ ok: false, reason: "timeout" }), PROBE_TIMEOUT_MS);
    sock.once("connect", () => settle({ ok: true, socket: sock }));
    sock.once("error", (err: NodeJS.ErrnoException) => {
      // ECONNREFUSED is the kernel's own "nothing listens on this socket".
      // Every other failure (a full backlog's EAGAIN, a vanished path, a
      // permission problem) leaves the question open.
      settle({
        ok: false,
        reason: err.code === "ECONNREFUSED" ? "refused" : "error",
        ...(err.code !== undefined ? { code: err.code } : {}),
      });
    });
  });
}

function _tryBind(sockPath: string): Promise<Server | null> {
  return new Promise((resolve) => {
    const server = createServer();
    let settled = false;
    const settle = (val: Server | null) => {
      if (settled) return;
      settled = true;
      if (!val) {
        try { server.close(); } catch { /* ignored */ }
      }
      resolve(val);
    };
    server.once("error", () => settle(null));
    server.listen(sockPath, () => {
      // Security fix 2026-08 — tighten the socket file to owner-only. Node
      // creates it with default perms (0777 & ~umask — group/other-writable
      // under umask 0), which lets ANY local user connect to the broker and
      // inject envelopes into agent sessions. Windows named pipes take the
      // default libuv DACL (current user + admins + SYSTEM) instead.
      if (!usesNamedPipe()) {
        try { chmodSync(sockPath, 0o600); } catch { /* best-effort */ }
      }
      settle(server);
    });
  });
}

function _removeStaleSock(sockPath: string, identity?: SocketIdentity): boolean {
  try {
    const stat = lstatSync(sockPath);
    if (identity && !isSocketIdentity(identity, stat)) return false;
    if (!stat.isSocket()) return false;
    unlinkSync(sockPath);
    return true;
  } catch {
    // ENOENT or not a socket — nothing to clean up.
    return false;
  }
}
