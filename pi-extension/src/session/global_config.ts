import { chmodSync, existsSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { ipcAddress, usesNamedPipe } from "./ipc.js";

const HOME_PI_PIPER = join((process.env["REMOTE_PI_HOME"] || homedir()), ".pi", "piper");
const SESSIONS_DIR = join(HOME_PI_PIPER, "sessions");
const SKILLS_DIR = join(HOME_PI_PIPER, "skills");
/**
 * Fixed UDS session name. The local mesh is single per machine — every Pi
 * process on the host shares this broker. Previous versions exposed
 * multi-session support (named sessions, leave/rename/sessions commands);
 * those were removed in the 2026-05-23 simplification because in practice
 * every install converged on one session anyway and multi-session UX added
 * friction without value.
 */
export const LOCAL_SESSION_NAME = "local";

/** Ensures the new subdirs exist inside the existing ~/.pi/piper/.
 *
 *  Security fix 2026-08: everything under `~/.pi/piper` is created 0700 and
 *  re-chmodded best-effort even when it pre-existed — the broker + supervisor
 *  sockets live under `sessions/` and any local user able to traverse the dir
 *  can otherwise connect and inject envelopes into agent sessions. `mkdir`
 *  `mode` only applies to dirs it CREATES and is subject to umask, so the
 *  explicit chmod is what actually guarantees the mode. POSIX only — on
 *  Windows these calls are harmless no-ops for the permission bits and the
 *  named-pipe ACL (libuv default: current user + administrators + SYSTEM)
 *  governs access instead.
 */
export function ensureGlobalDirs(): void {
  for (const dir of [HOME_PI_PIPER, SESSIONS_DIR, SKILLS_DIR]) {
    try {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      // Best-effort tighten when the dir pre-existed with looser perms.
      try { chmodSync(dir, 0o700); } catch { /* Windows / exotic FS — ignore */ }
    } catch {
      // Pre-existing path with a FILE at it, etc. — leave to the caller's
      // own failure when it touches the dir.
    }
  }
}

/**
 * Local-IPC address for a session's broker. POSIX → a `.sock` file under the
 * session dir; Windows → a per-user named pipe (plan/40). The `net` API treats
 * both the same; only the address string differs.
 */
export function sessionSockPath(name: string): string {
  return ipcAddress(`broker-${name}`, join(SESSIONS_DIR, name, "broker.sock"));
}

/** Path to the audit log for a named session. */
export function sessionAuditPath(name: string): string {
  return join(SESSIONS_DIR, name, "audit.jsonl");
}

/** Path to the session metadata JSON. */
export function sessionMetaPath(name: string): string {
  return join(SESSIONS_DIR, name, "session.json");
}

export function sessionsDir(): string {
  return SESSIONS_DIR;
}

export function skillsDir(): string {
  return SKILLS_DIR;
}

/** Lists discovered session names from disk. */
export function listSessions(): string[] {
  ensureGlobalDirs();
  try {
    return readdirSync(SESSIONS_DIR).filter((entry) => {
      try {
        return statSync(join(SESSIONS_DIR, entry)).isDirectory();
      } catch { return false; }
    });
  } catch {
    return [];
  }
}

/**
 * Heuristic: a session has an existing broker socket FILE (POSIX only). On
 * Windows the broker is a named pipe with no file to stat, so this returns
 * false — the authoritative liveness check there is a connect-probe
 * (`leader_election.tryConnect` / `client.supervisorOnline`), not this. Only
 * legacy `session/wizard.ts` consumes this.
 */
export function sessionHasSock(name: string): boolean {
  if (usesNamedPipe()) return false;
  return existsSync(sessionSockPath(name));
}
