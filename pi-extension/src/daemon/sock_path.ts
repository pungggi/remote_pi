import { homedir } from "node:os";
import { join } from "node:path";
import { ipcAddress } from "../session/ipc.js";

/**
 * Address of the supervisor's control socket — `~/.pi/piper/supervisor.sock`
 * on POSIX, a per-user named pipe on Windows (plan/40).
 *
 * Lives in its own module so the lightest consumers (the CLI client in
 * `daemon/client.ts` and the Termux guard in `daemon/guard.ts`) can find the
 * socket without importing the supervisor and its whole dependency tree
 * (keeper, cron, relay). The supervisor itself imports it from here.
 */
export function supervisorSockPath(): string {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  return ipcAddress("supervisor", join(root, ".pi", "piper", "supervisor.sock"));
}
