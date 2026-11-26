import { ChildProcess, execFileSync, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { DaemonState } from "./control_protocol.js";
import { defaultAgentName, loadLocalConfig, type LocalConfig } from "../session/local_config.js";

/**
 * Wrapper around a `pi --mode rpc -e <extension>` child process for the
 * supervisor.
 *
 * Lifecycle:
 *   - `spawn()` boots the child with the daemon's cwd + `REMOTE_PI_DAEMON=1`
 *     env so the extension knows to skip the interactive wizard.
 *   - `sendPrompt(text)` writes a Pi RPC `prompt` command to stdin.
 *   - The child's stdout (Pi RPC events) is currently consumed line-by-line
 *     and ignored — wave 2 only needs fire-and-forget. Later waves can
 *     surface the events back through the supervisor's status op.
 *   - Exit/crash fires `exit` event with `{code, signal, isCrash}` so the
 *     supervisor can decide whether to auto-restart.
 *
 * Each `RpcChild` instance maps 1:1 to a registry entry (single cwd).
 * The supervisor owns the map of these and addresses them by `id`.
 */

export interface RpcChildOptions {
  /** Path to the `pi` binary. Defaults to "pi" (must be on PATH). */
  piBin?: string;
  /** Absolute path to the remote-pi `dist/index.js` to load as -e. */
  extensionPath: string;
  /** Working directory for the spawned process. Determines which local
   *  config the extension reads. */
  cwd: string;
  /** Additional env vars merged on top of `process.env` + the mandatory
   *  `REMOTE_PI_DAEMON=1`. */
  env?: NodeJS.ProcessEnv;
  /** Plan/167 — pre-joined `provider/id` appended as `--model` to the
   *  child's args. Lives in opts so auto-restarts keep the model. Validated
   *  by the caller (SAFE_MODEL_TOKEN); the pipe is user-local. */
  model?: string;
  /**
   * Daemon config injected into the child via `REMOTE_PI_DIRECT_CONFIG`
   * (JSON inline) instead of a per-cwd `.pi/remote-pi/config.json` file. The
   * supervisor builds this from the registry. When set, the child reads it
   * env-first (see `loadLocalConfig`) and no config file is needed. Also the
   * source of the `--name` for the session. Falls back to the on-disk config
   * when omitted.
   */
  config?: LocalConfig;
}

export interface RpcChildExitEvent {
  code: number | null;
  signal: NodeJS.Signals | null;
  /** True when exit was not clean (non-zero or signal). */
  isCrash: boolean;
}

export const EXIT_DAEMON_FRESH_SESSION = 42;

/** Windows extensions `spawn` (without `shell`) can actually launch, in
 *  preference order: native `.exe` first, then the `.cmd`/`.bat` shims (run via
 *  cmd.exe). An extensionless `pi` is a Unix shell script Node CANNOT spawn on
 *  Windows — picking it yields `spawn … ENOENT` and the daemon shows "crashed". */
const WIN_EXECUTABLE_EXTS = [".exe", ".cmd", ".bat", ".com"];

/**
 * PATH lookup for a bare bin name. Injectable in `resolvePiBin` so the win32
 * branch is deterministic under tests on any host (no real `where` needed).
 */
type WhereLookup = (bin: string) => string;

function whereLookup(bin: string): string {
  return execFileSync("where", [bin], { encoding: "utf8" });
}

/**
 * Resolve the `pi` executable for `spawn` (plan/40, decision C). On Windows a
 * bare `pi` is actually `pi.cmd`/`pi.ps1`, and `spawn` won't find it without an
 * extension → resolve the real path via `where` (rather than `shell:true`,
 * which risks shell injection). An explicit path or an already-suffixed name is
 * used as-is. POSIX returns the name unchanged.
 *
 * `where` lists every match in PATH order, which on pi-node installs puts the
 * extensionless `pi` (a shell script) BEFORE `pi.cmd`. Naively taking the first
 * line spawns the unrunnable script → ENOENT → "crashed". So we prefer a result
 * with a real Windows executable extension and only fall back to the first line.
 *
 * PATH-less fallback (2026-11-16 incident): when the lookup fails or finds
 * nothing — e.g. a watchdog-relaunched supervisor whose Task Scheduler env
 * lacks `%APPDATA%\npm` on PATH, so EVERY respawn died with `spawn pi ENOENT`
 * and the device daemon stayed down overnight — try npm's default global-shim
 * location `%APPDATA%\npm\<bin>.cmd` before returning the bare name (which
 * spawn can only surface as ENOENT on Windows).
 */
export function resolvePiBin(
  piBin: string,
  plat: NodeJS.Platform = process.platform,
  whereFn: WhereLookup = whereLookup,
): string {
  if (plat !== "win32") return piBin;
  if (piBin.includes("\\") || piBin.includes("/") || /\.[a-z0-9]+$/i.test(piBin)) return piBin;
  let lines: string[] = [];
  try {
    lines = whereFn(piBin).split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  } catch {
    /* `where` unavailable or the name not found — try the default shim dir */
  }
  const runnable = lines.find((l) =>
    WIN_EXECUTABLE_EXTS.some((ext) => l.toLowerCase().endsWith(ext)),
  );
  const chosen = runnable ?? lines[0];
  if (chosen) return chosen;
  const appdata = process.env.APPDATA;
  if (appdata) {
    const shim = join(appdata, "npm", `${piBin}.cmd`);
    if (existsSync(shim)) return shim;
  }
  return piBin;
}

/** What to pass to `spawn`: the executable and any args to prepend before the
 *  caller's args. On POSIX (and for `.exe`) `prefixArgs` is empty. */
export interface PiSpawnTarget { command: string; prefixArgs: string[] }

/**
 * Resolve `pi` to a directly-spawnable target (plan/40). On Windows `pi` is an
 * npm `.cmd` shim, which modern Node refuses to `spawn` without `shell:true`
 * (EINVAL, post CVE-2024-27980). Wrapping it in `cmd.exe` would (a) add a layer
 * that orphans the real `node` on kill and (b) complicate stdio — both fatal for
 * a long-lived RPC daemon the supervisor must stop/restart cleanly. Instead we
 * parse the shim to recover the underlying `node <cli.js>` and spawn that
 * directly: one process, clean signals, clean stdio.
 *
 * Falls back to the bare resolved path when not a parseable shim (e.g. a real
 * `pi.exe`, or POSIX) so `spawn` surfaces any real error honestly.
 */
export function resolvePiSpawn(
  piBin: string,
  plat: NodeJS.Platform = process.platform,
  nodeExe: string = process.execPath,
): PiSpawnTarget {
  const resolved = resolvePiBin(piBin, plat);
  if (plat !== "win32") return { command: resolved, prefixArgs: [] };
  if (/\.(cmd|bat)$/i.test(resolved)) {
    const target = _npmShimTarget(resolved);
    if (target) return { command: nodeExe, prefixArgs: [target] };
  }
  return { command: resolved, prefixArgs: [] };
}

/**
 * Extract the JS entry an npm `.cmd` shim launches. npm shims invoke
 * `"%_prog%"  "%dp0%\<relative>\entry.js" %*`; we recover `<dir>\<relative>\entry.js`
 * (dir = the shim's own folder, i.e. `%dp0%`). Returns null when the shim
 * doesn't match the expected shape or the target is missing.
 */
export function _npmShimTarget(cmdPath: string): string | null {
  let content: string;
  try { content = readFileSync(cmdPath, "utf8"); } catch { return null; }
  const m = content.match(/"%dp0%\\([^"]+\.[cm]?js)"/i);
  if (!m) return null;
  const target = join(dirname(cmdPath), m[1]);
  return existsSync(target) ? target : null;
}

/**
 * Maps an RPC stdout line to a busy-state transition: `message_start` → true
 * (a message is streaming), `message_end` → false. Other lines → null (no
 * change). Pure + exported for tests.
 *
 * NOTE (plan/39 detail 1): the Pi RPC stream has NO turn-level event — only
 * per-message start/end (and `response{command:"prompt"}` is emitted at
 * PREFLIGHT, i.e. turn START, not end). So this passive flag reflects
 * "a message is being produced right now"; the authoritative turn-busy signal
 * is `get_state.isStreaming` (see `RpcChild.refreshBusy`).
 */
export function busyTransition(line: string): boolean | null {
  let obj: unknown;
  try { obj = JSON.parse(line); } catch { return null; }
  const t = (obj as { type?: unknown } | null)?.type;
  if (t === "message_start") return true;
  if (t === "message_end") return false;
  return null;
}

/** Parses a `get_state` RPC response line, returning its id + isStreaming. */
function parseGetStateResponse(line: string): { id?: string; isStreaming?: boolean } | null {
  let obj: unknown;
  try { obj = JSON.parse(line); } catch { return null; }
  const o = obj as { type?: unknown; command?: unknown; id?: unknown; data?: unknown };
  if (o.type !== "response" || o.command !== "get_state") return null;
  const data = o.data as { isStreaming?: unknown } | undefined;
  return {
    id: typeof o.id === "string" ? o.id : undefined,
    isStreaming: typeof data?.isStreaming === "boolean" ? data.isStreaming : undefined,
  };
}

/** A custom message an extension posted with `pi.sendMessage`, as the RPC
 *  stream emits it: `message_end` with `role: "custom"`. */
export interface CustomMessageWire {
  customType: string;
  /** The extension's structured payload. The live stream carries it as an
   *  object; a value restored from the session file arrives as a JSON string,
   *  so both are accepted. Null when absent or not an object. */
  details: Record<string, unknown> | null;
}

function detailsObject(v: unknown): Record<string, unknown> | null {
  let value: unknown = v;
  if (typeof value === "string") {
    try { value = JSON.parse(value); } catch { return null; }
  }
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

/** Plan/173 — recognise one `message_end` line that carries a custom message.
 *  Every other line (responses, assistant messages, tool calls) answers null. */
export function parseCustomMessageEnd(line: string): CustomMessageWire | null {
  let obj: unknown;
  try { obj = JSON.parse(line); } catch { return null; }
  if (!obj || typeof obj !== "object") return null;
  const o = obj as { type?: unknown; message?: { role?: unknown; customType?: unknown; details?: unknown } | null };
  if (o.type !== "message_end" || !o.message || typeof o.message !== "object") return null;
  if (o.message.role !== "custom" || typeof o.message.customType !== "string") return null;
  return { customType: o.message.customType, details: detailsObject(o.message.details) };
}

/** The `details` of a `remote-pi:pair-code` message (see `_cmdPair`), or null
 *  when a field is missing or mistyped — the caller then refuses instead of
 *  printing a link that cannot work. */
export interface PairCodeDetails {
  uri: string;
  expiresAt: number;
  roomId: string;
  name: string;
}

export function parsePairCodeDetails(details: Record<string, unknown> | null): PairCodeDetails | null {
  if (!details) return null;
  const uri = details["uri"];
  const expiresAt = details["expiresAt"];
  const roomId = details["roomId"];
  const name = details["name"];
  if (typeof uri !== "string" || !uri.startsWith("remotepi://pair?")) return null;
  if (typeof expiresAt !== "number" || !Number.isFinite(expiresAt)) return null;
  if (typeof roomId !== "string" || roomId.length === 0) return null;
  if (typeof name !== "string") return null;
  return { uri, expiresAt, roomId, name };
}

/**
 * CLI args for the daemon's `pi --mode rpc` child.
 *
 * `--continue` is the key bit: it resumes the **most recent** session for the
 * cwd (`SessionManager.continueRecent`, non-interactive — unlike `--resume`
 * which opens a picker). Without it every supervisor restart spun up a brand
 * new session file, piling up thousands of JSONLs per folder. With it, a
 * restart REUSES the one session; the app's `/new` (session_new) still rolls
 * it over to a fresh one, which the next restart then continues. First boot
 * (no prior session) just creates the first one.
 *
 * `--name <sessionName>`, when given, pins the session's display name to the
 * daemon's identity (its `agent_name`) so every restart shows up under the
 * same stable name in the picker/app instead of an auto-generated one. The
 * daemon's name is set at registration (`remote-pi create <cwd> --name "…"`).
 * Omitted when no name resolves, so the arg list stays minimal.
 *
 * `--approve` is mandatory for a daemon (pi ≥0.79 project trust): RPC mode is
 * non-interactive, so without an override Pi resolves an untrusted project
 * folder (any folder with `.pi/` or CLAUDE.md/AGENTS.md) to NOT trusted and
 * silently skips its `.pi/settings.json` (model/provider/keys), instructions,
 * resources and project extensions — the daemon then comes up with no model
 * and fails on the first turn. The operator already authorized this folder by
 * registering/launching a daemon in it, so `--approve` (trust-for-this-run) is
 * the correct non-interactive stance. (Settings/instructions/resources are
 * still honored with `-ne` below — only extension discovery is disabled.)
 *
 * `-ne` (extension isolation, 2026-08 incident): disables pi's extension
 * DISCOVERY — settings.json packages, ~/.pi/agent/extensions, and the cwd's
 * .pi/extensions — while explicit `-e` paths (ours) still load. Rationale: a
 * user-global extension that fails to parse is FATAL at pi boot (verified: an
 * unterminated template literal in a global extension kills every `pi`
 * process), so ONE typo'd global extension took down the whole daemon fleet
 * → phone "Device unreachable". Daemons are infrastructure: they must
 * survive the user's interactive-setup breakage. Bonus: this also ends the
 * "extension loaded twice" conflict (remote-pi installed globally AND via
 * `-e`) and stops cwd-local .pi/extensions auto-loading into daemons
 * (defense-in-depth next to `remoteCwdAllowed`, security fix M3).
 * Trade-off: daemon agents no longer see user extension tools (MCP adapters
 * etc.) — if ever needed, pass them as additional explicit `-e` paths.
 */
export function rpcSpawnArgs(
  extensionPath: string,
  sessionName?: string,
  useContinue = true,
  model?: string,
): string[] {
  return [
    "--mode", "rpc",
    "--approve",
    ...(useContinue ? ["--continue"] : []),
    ...(sessionName ? ["--name", sessionName] : []),
    ...(model ? ["--model", model] : []),
    "-ne",
    "-e", extensionPath,
  ];
}

export class RpcChild extends EventEmitter {
  private child: ChildProcess | null = null;
  private _state: DaemonState = "stopped";
  private _startedAt: number | null = null;
  private _restartCount = 0;
  /** True while a deliberate `stop()` is in flight. The process dies by
   *  signal (SIGTERM/SIGKILL), which would otherwise look like a crash and
   *  trip the supervisor's auto-restart — re-spawning a daemon the operator
   *  just stopped/removed. Gating `isCrash` on this makes a deliberate stop a
   *  clean exit (no restart). Reset on every `spawn()`. */
  private _stopping = false;
  /** Next spawn should create a fresh session instead of --continue. */
  private forceFreshSessionOnNextSpawn = false;
  /** Accumulates partial stdout lines while waiting for `\n`. */
  private stdoutBuf = "";
  /** Passive busy flag derived from the RPC stream (message_start/end). Hint
   *  only; `refreshBusy` syncs it authoritatively via get_state.isStreaming. */
  private _busy = false;
  /** In-flight `get_state` requests, keyed by request id. */
  private readonly _statePending = new Map<string, { resolve: (b: boolean) => void; timer: ReturnType<typeof setTimeout> }>();
  /** Plan/168 — in-flight liveness pings, keyed by request id. Distinct from
   *  `_statePending`: a ping resolves on RESPONSE PRESENCE (any answer means
   *  the child's event loop is alive), not on the busy payload. */
  private readonly _pongPending = new Map<string, { resolve: (ok: boolean) => void; timer: ReturnType<typeof setTimeout> }>();
  /** Plan/173 — at most one in-flight waiter per custom message type. */
  private readonly _customPending = new Map<string, {
    resolve: (details: Record<string, unknown> | null) => void;
    timer: ReturnType<typeof setTimeout>;
  }>();

  constructor(private readonly opts: RpcChildOptions) {
    super();
  }

  get state(): DaemonState { return this._state; }
  /** Passive busy hint from the stream. Prefer `refreshBusy()` for an
   *  authoritative check before acting on it (cron skip_if_busy). */
  get isBusy(): boolean { return this._busy; }
  get pid(): number | undefined { return this.child?.pid; }
  get restartCount(): number { return this._restartCount; }
  get uptimeMs(): number | undefined {
    return this._startedAt !== null ? Date.now() - this._startedAt : undefined;
  }

  /**
   * Spawn the child process. Idempotent for the same instance: a second
   * call while already running is a no-op.
   */
  spawn(): void {
    if (this.child) return;
    this._stopping = false;  // fresh start — a later signal IS a real crash
    this._busy = false;
    this._state = "starting";

    const piTarget = resolvePiSpawn(this.opts.piBin ?? "pi");
    // Name the (single) daemon session after the daemon's configured identity,
    // so it shows up stably instead of an auto-generated name on each restart.
    // Prefer the supervisor-injected config; fall back to the on-disk file.
    const cfg = this.opts.config ?? loadLocalConfig(this.opts.cwd);
    const sessionName = cfg.agent_name ?? defaultAgentName(this.opts.cwd);
    const useContinue = !this.forceFreshSessionOnNextSpawn;
    this.forceFreshSessionOnNextSpawn = false;
    // On Windows `prefixArgs` carries pi's cli.js (we spawn node directly); on
    // POSIX it's empty and `command` is `pi` itself.
    const args = [...piTarget.prefixArgs, ...rpcSpawnArgs(this.opts.extensionPath, sessionName, useContinue, this.opts.model)];
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      ...this.opts.env,
      // Mandatory daemon marker — `_cmdRoot` in index.ts can use this to
      // bail early if local config is missing (no wizard in RPC mode).
      REMOTE_PI_DAEMON: "1",
      // Inject the daemon config inline so the child needs no config file.
      ...(this.opts.config ? { REMOTE_PI_DIRECT_CONFIG: JSON.stringify(this.opts.config) } : {}),
    };

    const child = spawn(piTarget.command, args, {
      cwd: this.opts.cwd,
      env,
      stdio: ["pipe", "pipe", "pipe"],
      // Windows: suppress any console window the child might allocate. With the
      // node+cli.js path (resolvePiSpawn) there's no cmd.exe layer, but keep this
      // as belt-and-suspenders alongside the supervisor's hidden wscript launcher
      // (service-templates/task-launcher.vbs.template). No-op on POSIX.
      windowsHide: process.platform === "win32",
    });
    this.child = child;
    this._startedAt = Date.now();
    this._state = "running";

    child.stdout?.on("data", (chunk: Buffer) => this._onStdout(chunk));
    // A child that died between our liveness check and a stdin write makes
    // that write fail asynchronously (EPIPE). Without a listener the error is
    // an uncaught exception and takes the whole supervisor down.
    child.stdin?.on("error", (err) => {
      process.stderr.write(
        `[remote-pi-supervisord] stdin write to ${this.opts.cwd} failed: ${String(err)}\n`,
      );
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      const text = chunk.toString();
      // Forward stderr to our own stderr so `journalctl --user -u remote-pi-supervisord`
      // sees daemon logs (with cwd prefix for disambiguation)…
      process.stderr.write(`[${this.opts.cwd}] ${text}`);
      // …and emit for plan/159: the supervisor persists it to the per-daemon
      // log (`~/.pi/piper/daemons/<id>.log`) so crash forensics survive a
      // supervisor launched WITHOUT output redirection (2026-11-07 incident:
      // a hidden-start watchdog supervisor discarded stderr entirely).
      this.emit("stderr", text);
    });
    child.on("exit", (code, signal) => this._onExit(code, signal));
    child.on("error", (err) => {
      // spawn() itself failed (e.g. `pi` binary not found).
      this._state = "crashed";
      process.stderr.write(
        `[remote-pi-supervisord] spawn failed for ${this.opts.cwd}: ${String(err)}\n`,
      );
      this.emit("exit", { code: null, signal: null, isCrash: true });
    });

    this.emit("spawn", { pid: child.pid });
  }

  /**
   * Sends a Pi RPC `prompt` command to the child's stdin. Fire-and-forget
   * — we don't wait for the response (response would be the success ack;
   * the actual agent output streams via the relay/UDS, not back through
   * stdout).
   *
   * Returns false if the child isn't running (caller decides how to report).
   */
  sendPrompt(text: string, requestId?: string): boolean {
    if (!this.child || !this.child.stdin || this._state !== "running") return false;
    const cmd = { id: requestId ?? `sv-${Date.now()}`, type: "prompt", message: text };
    try {
      this.child.stdin.write(JSON.stringify(cmd) + "\n");
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Asks the child to exit gracefully. Sends SIGTERM; if the child doesn't
   * exit within `timeoutMs`, escalates to SIGKILL. Resolves when the
   * `exit` event fires.
   */
  async stop(timeoutMs = 5000): Promise<void> {
    if (!this.child) return;
    this._stopping = true;  // deliberate — the upcoming signal-exit is NOT a crash
    const child = this.child;
    return new Promise<void>((resolve) => {
      const onExit = () => { resolve(); };
      this.once("exit", onExit);
      try { child.kill("SIGTERM"); } catch { /* already dead */ }
      const t = setTimeout(() => {
        try { child.kill("SIGKILL"); } catch { /* race — already dead */ }
      }, timeoutMs);
      this.once("exit", () => clearTimeout(t));
    });
  }

  private _onStdout(chunk: Buffer): void {
    this.stdoutBuf += chunk.toString();
    let nl: number;
    while ((nl = this.stdoutBuf.indexOf("\n")) >= 0) {
      const line = this.stdoutBuf.slice(0, nl);
      this.stdoutBuf = this.stdoutBuf.slice(nl + 1);
      if (!line.trim()) continue;
      this._handleStdoutLine(line);
    }
  }

  private _handleStdoutLine(line: string): void {
    const t = busyTransition(line);
    if (t !== null) this._busy = t;
    // Plan/173 — resolve a waiter for the next custom message of this type.
    const custom = this._customPending.size > 0 ? parseCustomMessageEnd(line) : null;
    if (custom) {
      const waiter = this._customPending.get(custom.customType);
      if (waiter) {
        clearTimeout(waiter.timer);
        this._customPending.delete(custom.customType);
        waiter.resolve(custom.details);
      }
    }
    const gs = parseGetStateResponse(line);
    if (gs && gs.id) {
      const pong = this._pongPending.get(gs.id);
      if (pong) {
        clearTimeout(pong.timer);
        this._pongPending.delete(gs.id);
        pong.resolve(true);
      }
      const pending = this._statePending.get(gs.id);
      if (pending) {
        clearTimeout(pending.timer);
        this._statePending.delete(gs.id);
        if (typeof gs.isStreaming === "boolean") this._busy = gs.isStreaming;
        pending.resolve(this._busy);
      }
    }
    this.emit("stdout", line);
  }

  /**
   * Plan/168 — event-loop liveness probe: sends `get_state` and resolves
   * TRUE on any response for our id, false on timeout / not running.
   *
   * The pi RPC dispatcher handles each stdin line concurrently
   * (`void handleInputLine(line)` — rpc-mode.js), so a BUSY turn still
   * answers while streaming; only a wedged loop (the 2026-11-22 zombie:
   * socket half-open, process alive, nothing processed) stays silent.
   * That makes a missed ping a safe wedge signal — no busy false-positives.
   */
  ping(timeoutMs = 5000): Promise<boolean> {
    if (this._state !== "running" || !this.child?.stdin) {
      // Not running: the supervisor's ping loop skips non-running slots, so
      // this only matters for direct callers — report not-alive, not a miss.
      return Promise.resolve(false);
    }
    const id = `ping-${Date.now()}-${Math.round(Math.random() * 1e6)}`;
    return new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        this._pongPending.delete(id);
        resolve(false);
      }, timeoutMs);
      this._pongPending.set(id, { resolve, timer });
      try {
        this.child!.stdin!.write(JSON.stringify({ id, type: "get_state" }) + "\n");
      } catch {
        clearTimeout(timer);
        this._pongPending.delete(id);
        resolve(false);
      }
    });
  }

  /**
   * Plan/173 — ask the child's extension for ONE custom message. `text` goes
   * out as an RPC prompt: a slash command runs the extension's command handler
   * without a model turn, and the handler reports through
   * `pi.sendMessage({ customType })`, which the RPC stream emits as a
   * `message_end` with `role: "custom"`. Resolves with that message's
   * `details`, or null on timeout, when the child is not running, or when
   * another request for the same type is still in flight.
   *
   * The canonical use is `/remote-pi pair`: the pairing token only exists in
   * the process that will consume the app's `pair_request`, so the link must
   * be minted INSIDE the daemon, never by whoever prints it.
   */
  requestCustomMessage(
    customType: string,
    text: string,
    timeoutMs = 15_000,
  ): Promise<Record<string, unknown> | null> {
    if (this._state !== "running" || !this.child?.stdin) return Promise.resolve(null);
    if (this._customPending.has(customType)) return Promise.resolve(null);
    const id = `req-${Date.now()}-${Math.round(Math.random() * 1e6)}`;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this._customPending.delete(customType);
        resolve(null);
      }, timeoutMs);
      this._customPending.set(customType, { resolve, timer });
      if (!this.sendPrompt(text, id)) {
        clearTimeout(timer);
        this._customPending.delete(customType);
        resolve(null);
      }
    });
  }

  /**
   * Authoritative busy check: queries the child's `get_state` and syncs
   * `_busy` to `isStreaming`. Resolves the passive flag on timeout (no
   * response) or when the child isn't running. Used by the cron `skip_if_busy`
   * gate, where a false "not busy" would pile a prompt onto a live turn.
   */
  async refreshBusy(timeoutMs = 1500): Promise<boolean> {
    if (this._state !== "running" || !this.child?.stdin) return this._busy;
    const id = `gs-${Date.now()}-${Math.round(Math.random() * 1e6)}`;
    return new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        this._statePending.delete(id);
        resolve(this._busy);
      }, timeoutMs);
      this._statePending.set(id, { resolve, timer });
      try {
        this.child!.stdin!.write(JSON.stringify({ id, type: "get_state" }) + "\n");
      } catch {
        clearTimeout(timer);
        this._statePending.delete(id);
        resolve(this._busy);
      }
    });
  }

  /** Test-only: feed a raw stdout line through the same handler. */
  _ingestStdoutForTest(line: string): void {
    this._handleStdoutLine(line);
  }

  private _onExit(code: number | null, signal: NodeJS.Signals | null): void {
    // Daemon app-action `/new`: child exits with a private code, supervisor
    // restarts it, and the next spawn omits --continue once to create a fresh
    // session. Later restarts go back to --continue.
    if (code === EXIT_DAEMON_FRESH_SESSION) this.forceFreshSessionOnNextSpawn = true;
    // A deliberate stop() kills by signal — not a crash, so the supervisor
    // must NOT auto-restart it. Only an UNexpected exit counts as a crash.
    const isCrash = !this._stopping && (code !== 0 || signal !== null);
    this._state = isCrash ? "crashed" : "stopped";
    this.child = null;
    this._startedAt = null;
    this._busy = false;
    for (const p of this._statePending.values()) {
      clearTimeout(p.timer);
      p.resolve(false);
    }
    this._statePending.clear();
    for (const p of this._pongPending.values()) {
      clearTimeout(p.timer);
      p.resolve(false);
    }
    this._pongPending.clear();
    for (const p of this._customPending.values()) {
      clearTimeout(p.timer);
      p.resolve(null);
    }
    this._customPending.clear();
    this.emit("exit", { code, signal, isCrash } satisfies RpcChildExitEvent);
  }

  /** Bumps the restart counter — called by the supervisor when it
   *  decides to re-spawn after a crash. Exposed so tests can drive it. */
  noteRestart(): void {
    this._restartCount += 1;
  }
}
