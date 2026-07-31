/**
 * Fleet-ops commands — daemon registry, supervisor control, cron scheduling,
 * and service install/uninstall.
 *
 * Extracted from src/index.ts (god-file split). Fully self-contained: it
 * reaches shared state via 'ext' (extension-state.ts) and the supervisor /
 * install / registry modules directly. It has NO host dependencies, so (unlike
 * the image pipeline) it needs no injected deps interface.
 *
 * Named without the historical '_' prefix — module API, not private helpers.
 */

import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { ext } from "../extension-state.js";
import { addDaemon, listDaemons, removeDaemon } from "../daemon/registry.js";
import { callSupervisor, supervisorOnline, SupervisorOfflineError } from "../daemon/client.js";
import type { ControlRequest, DaemonInfo } from "../daemon/control_protocol.js";
import { installService, uninstallService, linkCliBinaries, unlinkCliBinaries } from "../daemon/install.js";
import { defaultAgentName, loadLocalConfig } from "../session/local_config.js";

export async function cmdCreate(arg: string, ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  // Parse `[cwd] [--name "value with spaces" | --name word]` in any order.
  // The first non-flag token is the cwd; the rest of the line after
  // `--name` (quoted or unquoted) is the display name.
  const nameMatch = arg.match(/--name\s+"([^"]+)"|--name\s+(\S+)/);
  const name = nameMatch ? (nameMatch[1] ?? nameMatch[2]) : undefined;
  const cwdRaw = arg.replace(/--name\s+"[^"]+"|--name\s+\S+/, "").trim();
  if (!cwdRaw) {
    ctx.ui.notify(
      "[remote-pi] Usage: /remote-pi create <absolute-or-relative-cwd> [--name \"Display name\"]",
      "warning",
    );
    return;
  }

  let result: { id: string; cwd: string; name: string };
  try {
    result = addDaemon(cwdRaw, name);
  } catch (err) {
    ctx.ui.notify(`[remote-pi] create failed: ${String(err)}`, "error");
    return;
  }

  // No local `.pi/remote-pi/config.json` is written anymore — the name lives
  // in the registry and the supervisor injects the full config (agent_name,
  // auto_start_relay true) via REMOTE_PI_DIRECT_CONFIG when it spawns the
  // daemon. The cwd needs no init folder.

  ctx.ui.notify(
    `[remote-pi] Daemon registered: id=${result.id} name="${result.name}" cwd=${result.cwd}`,
    "info",
  );

  // Auto-start: register alone used to leave the daemon idle until the next
  // supervisor restart (the reported bug — `create` didn't run anything). Ask
  // the supervisor to spawn THIS daemon now; it reads the name from the
  // registry and injects the config via env. When the supervisor is offline we
  // keep the
  // registration and tell the user it'll boot on the next supervisor start.
  try {
    await callSupervisor({ op: "start", id: result.id });
    ctx.ui.notify(`[remote-pi] Daemon started: id=${result.id}`, "info");
  } catch (err) {
    if (err instanceof SupervisorOfflineError) {
      ctx.ui.notify(
        `[remote-pi] Registered, but the supervisor is offline — not running yet. ` +
        `Run \`remote-pi install\` (or start \`pi-supervisord\`); it auto-starts on the next supervisor boot.`,
        "warning",
      );
      return;
    }
    ctx.ui.notify(`[remote-pi] Registered, but auto-start failed: ${String(err)}`, "error");
  }
}

/**
 * `/remote-pi remove <id>`
 *
 * Unregisters a daemon by its 8-hex-char id (the same id printed by
 * `/remote-pi create` and `/remote-pi daemons`). The cwd's local config
 * stays on disk — re-creating later with the same cwd is a no-op
 * because the existing config wins.
 */
export async function cmdRemove(arg: string, ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  const id = arg.trim();
  if (!id) {
    ctx.ui.notify(
      "[remote-pi] Usage: /remote-pi remove <id>. Run /remote-pi daemons to see ids.",
      "warning",
    );
    return;
  }

  // Prefer the supervisor's `unregister`: it STOPS the running child (SIGTERM →
  // SIGKILL) BEFORE deleting the registry entry. Removing only the registry
  // (the old behaviour) left an orphaned `pi --mode rpc` process running with
  // nothing left to manage it — the reported bug. Fall back to a registry-only
  // removal when the supervisor is offline (no managed process to stop anyway).
  try {
    const data = await callSupervisor({ op: "unregister", id });
    if (!data.removed) {
      const known = listDaemons().map((d) => d.id).join(", ") || "(none)";
      ctx.ui.notify(`[remote-pi] No daemon with id "${id}". Known ids: ${known}`, "warning");
      return;
    }
    ctx.ui.notify(
      `[remote-pi] Daemon removed + process stopped: id=${id} cwd=${data.cwd}. ` +
      `Local config at ${data.cwd}/.pi/remote-pi/config.json was kept.`,
      "info",
    );
    return;
  } catch (err) {
    if (!(err instanceof SupervisorOfflineError)) {
      ctx.ui.notify(`[remote-pi] remove failed: ${String(err)}`, "error");
      return;
    }
    // Supervisor offline — fall through to registry-only removal below.
  }

  let result: { removed: boolean; cwd?: string };
  try {
    result = removeDaemon(id);
  } catch (err) {
    ctx.ui.notify(`[remote-pi] remove failed: ${String(err)}`, "error");
    return;
  }

  if (!result.removed) {
    const known = listDaemons().map((d) => d.id).join(", ") || "(none)";
    ctx.ui.notify(`[remote-pi] No daemon with id "${id}". Known ids: ${known}`, "warning");
    return;
  }

  ctx.ui.notify(
    `[remote-pi] Daemon removed from registry: id=${id} cwd=${result.cwd}. ` +
    `Supervisor was offline, so any running process was NOT stopped. Local config kept.`,
    "warning",
  );
}

// ── Fleet-ops commands (plan/26 W2) — talk to the supervisor over UDS ─────────
//
// Every command here is a thin wrapper around `callSupervisor(...)`. When
// the supervisor isn't running we fall back to a friendly hint instead of
// the raw error, so the user can't get stuck on "what's wrong?".

function notifyOffline(ctx: Pick<ExtensionContext, "ui">, err: SupervisorOfflineError): void {
  ctx.ui.notify(`[remote-pi] ${err.message}`, "warning");
}

function formatDaemonTable(daemons: DaemonInfo[]): string {
  if (daemons.length === 0) return "(no daemons registered)";
  const rows = daemons.map((d) => {
    const uptime = d.uptime_s !== undefined ? `${d.uptime_s}s` : "—";
    const pid = d.pid !== undefined ? String(d.pid) : "—";
    const restarts = d.restart_count ?? 0;
    return `  ${d.id}  ${d.state.padEnd(8)}  pid=${pid}  up=${uptime}  restarts=${restarts}  ${d.name}  ${d.cwd}`;
  });
  return rows.join("\n");
}

/**
 * `/remote-pi daemons` — registry + runtime state in one view. When the
 * supervisor is offline we still show registry-only output (state =
 * "stopped" everywhere), so the user can see what's configured even
 * before `install`.
 */
export async function cmdDaemonsList(ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  if (!(await supervisorOnline())) {
    const registry = listDaemons();
    if (registry.length === 0) {
      ctx.ui.notify("[remote-pi] No daemons registered. Run /remote-pi create <cwd>.", "info");
      return;
    }
    const rows = registry.map((d) => {
      const cfg = loadLocalConfig(d.cwd);
      const name = cfg.agent_name ?? defaultAgentName(d.cwd);
      return `  ${d.id}  ${name}  ${d.cwd}  (supervisor offline)`;
    }).join("\n");
    ctx.ui.notify(`[remote-pi] Daemons (registry only — run install to bring supervisor up):\n${rows}`, "info");
    return;
  }
  try {
    const data = await callSupervisor({ op: "list" });
    ctx.ui.notify(`[remote-pi] Daemons:\n${formatDaemonTable(data.daemons)}`, "info");
  } catch (err) {
    if (err instanceof SupervisorOfflineError) { notifyOffline(ctx, err); return; }
    ctx.ui.notify(`[remote-pi] daemons failed: ${String(err)}`, "error");
  }
}

export async function cmdDaemonStatus(ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  try {
    const data = await callSupervisor({ op: "status" });
    ctx.ui.notify(`[remote-pi] Fleet status:\n${formatDaemonTable(data.daemons)}`, "info");
  } catch (err) {
    if (err instanceof SupervisorOfflineError) { notifyOffline(ctx, err); return; }
    ctx.ui.notify(`[remote-pi] status failed: ${String(err)}`, "error");
  }
}

export async function cmdDaemonStart(ctx: Pick<ExtensionContext, "ui">, id?: string): Promise<void> {
  try {
    if (id) {
      const data = await callSupervisor({ op: "start", id });
      ctx.ui.notify(
        data.started
          ? `[remote-pi] Started daemon ${id} (${data.state}).`
          : `[remote-pi] Daemon ${id} already ${data.state}.`,
        "info",
      );
      return;
    }
    const data = await callSupervisor({ op: "start_all" });
    ctx.ui.notify(
      `[remote-pi] Started ${data.started.length} daemon(s), ` +
      `${data.already_running.length} already running.`,
      "info",
    );
  } catch (err) {
    if (err instanceof SupervisorOfflineError) { notifyOffline(ctx, err); return; }
    ctx.ui.notify(`[remote-pi] start failed: ${String(err)}`, "error");
  }
}

export async function cmdDaemonStop(ctx: Pick<ExtensionContext, "ui">, id?: string): Promise<void> {
  try {
    if (id) {
      const data = await callSupervisor({ op: "stop", id });
      ctx.ui.notify(
        data.stopped
          ? `[remote-pi] Stopped daemon ${id}.`
          : `[remote-pi] Daemon ${id} already ${data.state}.`,
        "info",
      );
      return;
    }
    const data = await callSupervisor({ op: "stop_all" });
    ctx.ui.notify(
      `[remote-pi] Stopped ${data.stopped.length} daemon(s), ` +
      `${data.already_stopped.length} already stopped.`,
      "info",
    );
  } catch (err) {
    if (err instanceof SupervisorOfflineError) { notifyOffline(ctx, err); return; }
    ctx.ui.notify(`[remote-pi] stop failed: ${String(err)}`, "error");
  }
}

export async function cmdDaemonRestart(ctx: Pick<ExtensionContext, "ui">, id?: string): Promise<void> {
  try {
    if (id) {
      const data = await callSupervisor({ op: "restart", id });
      ctx.ui.notify(`[remote-pi] Restarted daemon ${id} (${data.state}).`, "info");
      return;
    }
    const data = await callSupervisor({ op: "restart_all" });
    ctx.ui.notify(`[remote-pi] Restarted ${data.restarted.length} daemon(s).`, "info");
  } catch (err) {
    if (err instanceof SupervisorOfflineError) { notifyOffline(ctx, err); return; }
    ctx.ui.notify(`[remote-pi] restart failed: ${String(err)}`, "error");
  }
}

/**
 * `/remote-pi daemon send <id> "<text>"` — injects a prompt into a
 * running daemon via its RPC stdin. The agent processes the prompt as
 * if a user typed it; output flows back via the relay/mesh, not here.
 *
 * Fire-and-forget at this layer — the CLI just confirms delivery.
 */
export async function cmdDaemonSend(arg: string, ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  // Parse `<id> <text...>` — id is the first token, rest is the prompt.
  // The text may be quoted; if so, strip the outer quotes. Otherwise
  // take the entire remainder verbatim.
  const m = arg.match(/^(\S+)\s+(?:"([^"]*)"|(.*))$/);
  if (!m) {
    ctx.ui.notify(
      "[remote-pi] Usage: /remote-pi daemon send <id> \"<prompt text>\"",
      "warning",
    );
    return;
  }
  const id = m[1]!;
  const text = (m[2] ?? m[3] ?? "").trim();
  if (!text) {
    ctx.ui.notify("[remote-pi] daemon send: prompt text is empty.", "warning");
    return;
  }
  try {
    const data = await callSupervisor({ op: "send", id, text });
    if (data.delivered) {
      ctx.ui.notify(`[remote-pi] Sent to ${id}: ${text.slice(0, 60)}${text.length > 60 ? "…" : ""}`, "info");
    } else {
      ctx.ui.notify(`[remote-pi] daemon ${id} did not accept the prompt (not running?)`, "warning");
    }
  } catch (err) {
    if (err instanceof SupervisorOfflineError) { notifyOffline(ctx, err); return; }
    ctx.ui.notify(`[remote-pi] daemon send failed: ${String(err)}`, "error");
  }
}

// ── Cron — scheduled prompts for daemons (plan/39) ──────────────────────────

/** Splits an arg string into tokens, honoring double-quoted groups. */
function tokenizeArgs(s: string): string[] {
  const out: string[] = [];
  const re = /"([^"]*)"|(\S+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(s)) !== null) out.push(m[1] !== undefined ? m[1] : m[2]!);
  return out;
}

/**
 * `/remote-pi cron <add|list|remove|enable|disable|run|log>` — schedules
 * recurring prompts to daemons via the supervisor. All subcommands require the
 * supervisor running (offline → friendly notice, not a crash).
 */
export async function cmdCron(arg: string, ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  const trimmed = arg.trim();
  const sp = trimmed.indexOf(" ");
  const sub = (sp === -1 ? trimmed : trimmed.slice(0, sp)).toLowerCase();
  const rest = sp === -1 ? "" : trimmed.slice(sp + 1).trim();
  try {
    switch (sub) {
      case "":
      case "list":    return await cronList(ctx);
      case "add":     return await cronAdd(rest, ctx);
      case "remove":
      case "rm":      return await cronMutate({ op: "cron_remove", job_id: rest.trim() }, rest.trim(), ctx);
      case "enable":  return await cronMutate({ op: "cron_enable", job_id: rest.trim(), enabled: true }, rest.trim(), ctx);
      case "disable": return await cronMutate({ op: "cron_enable", job_id: rest.trim(), enabled: false }, rest.trim(), ctx);
      case "run":     return await cronRun(rest.trim(), ctx);
      case "log":     return await cronLog(rest, ctx);
      default:
        ctx.ui.notify("[remote-pi] Usage: /remote-pi cron <add|list|remove|enable|disable|run|log>", "warning");
    }
  } catch (err) {
    if (err instanceof SupervisorOfflineError) {
      ctx.ui.notify(
        "[remote-pi] Cron needs the supervisor running. Run `remote-pi install` " +
        "(or start `pi-supervisord`).",
        "warning",
      );
      return;
    }
    ctx.ui.notify(`[remote-pi] cron ${sub || "list"} failed: ${String(err)}`, "error");
  }
}

async function cronAdd(rest: string, ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  const toks = tokenizeArgs(rest);
  let tz: string | undefined;
  let wake = false;
  let skipBusy = true;
  let catchup = false;
  const pos: string[] = [];
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i]!;
    if (t === "--wake") wake = true;
    else if (t === "--no-skip-busy") skipBusy = false;
    else if (t === "--catchup") catchup = true;
    else if (t === "--tz") tz = toks[++i];
    else pos.push(t);
  }
  const [daemonId, schedule, prompt] = pos;
  if (!daemonId || !schedule || !prompt) {
    ctx.ui.notify(
      '[remote-pi] Usage: /remote-pi cron add <daemonId> "<cron-expr>" "<prompt>" ' +
      "[--tz Area/City] [--wake] [--no-skip-busy] [--catchup]",
      "warning",
    );
    return;
  }
  const req: Extract<ControlRequest, { op: "cron_add" }> = {
    op: "cron_add", daemon_id: daemonId, schedule, prompt,
  };
  if (tz) req.tz = tz;
  if (wake) req.wake = true;
  if (!skipBusy) req.skip_if_busy = false;
  if (catchup) req.catchup = true;
  const data = await callSupervisor(req);
  ctx.ui.notify(
    `[remote-pi] Cron ${data.job.id} added → daemon ${daemonId}: "${schedule}"` +
    `${tz ? ` (${tz})` : ""}. Next run: ${data.job.next_run ?? "?"}`,
    "info",
  );
}

async function cronList(ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  const data = await callSupervisor({ op: "cron_list" });
  if (data.jobs.length === 0) {
    ctx.ui.notify("[remote-pi] No cron jobs.", "info");
    return;
  }
  const lines = data.jobs.map((j) =>
    `${j.enabled ? "✓" : "✗"} ${j.id}  "${j.schedule}"${j.tz ? ` (${j.tz})` : ""}  → ${j.daemon_id}  ` +
    `next:${j.next_run ?? "?"}  last:${j.last_status ?? "—"}${j.last_run ? `@${j.last_run}` : ""}`,
  );
  ctx.ui.notify(`[remote-pi] Cron jobs (${data.jobs.length}):\n${lines.join("\n")}`, "info");
}

async function cronMutate(
  req: Extract<ControlRequest, { op: "cron_remove" | "cron_enable" }>,
  jobId: string,
  ctx: Pick<ExtensionContext, "ui">,
): Promise<void> {
  if (!jobId) {
    ctx.ui.notify(`[remote-pi] Usage: /remote-pi cron ${req.op === "cron_remove" ? "remove" : "enable|disable"} <jobId>`, "warning");
    return;
  }
  if (req.op === "cron_remove") {
    const data = await callSupervisor(req);
    ctx.ui.notify(data.removed ? `[remote-pi] Cron ${jobId} removed.` : `[remote-pi] No cron job ${jobId}.`, data.removed ? "info" : "warning");
  } else {
    const data = await callSupervisor(req);
    ctx.ui.notify(
      data.updated ? `[remote-pi] Cron ${jobId} ${data.enabled ? "enabled" : "disabled"}.` : `[remote-pi] No cron job ${jobId}.`,
      data.updated ? "info" : "warning",
    );
  }
}

async function cronRun(jobId: string, ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  if (!jobId) {
    ctx.ui.notify("[remote-pi] Usage: /remote-pi cron run <jobId>", "warning");
    return;
  }
  const data = await callSupervisor({ op: "cron_run", job_id: jobId });
  ctx.ui.notify(`[remote-pi] Cron ${jobId} fired now → ${data.result}`, "info");
}

async function cronLog(rest: string, ctx: Pick<ExtensionContext, "ui">): Promise<void> {
  const toks = tokenizeArgs(rest);
  let jobId: string | undefined;
  let tail = 20;
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i]!;
    if (t === "--tail") { const n = Number(toks[++i]); if (Number.isFinite(n)) tail = n; }
    else if (!t.startsWith("--")) jobId = t;
  }
  const req: Extract<ControlRequest, { op: "cron_log" }> = { op: "cron_log", tail };
  if (jobId) req.job_id = jobId;
  const data = await callSupervisor(req);
  if (data.entries.length === 0) {
    ctx.ui.notify("[remote-pi] No cron log entries.", "info");
    return;
  }
  const lines = data.entries.map((e) =>
    `${new Date(e.ts).toISOString()}  ${e.fired ? "▶" : "∅"} ${e.result}  ${e.job_id} → ${e.daemon_id}  ${e.prompt_preview}`,
  );
  ctx.ui.notify(`[remote-pi] Cron log (last ${data.entries.length}):\n${lines.join("\n")}`, "info");
}

// ── Install/uninstall the supervisor service (plan/26 W3) ────────────────────
//
// Installs `pi-supervisord` as a user-level system service (systemd
// `--user` unit on Linux, launchd LaunchAgent on macOS). Once installed:
//   - Supervisor starts at login + survives reboots.
//   - `remote-pi daemon start/stop/send/...` work without manually
//     spawning the supervisor.
// Uninstall is the inverse — leaves the registry (`daemons.json`) intact,
// so re-installing later picks up where you left off.

/**
 * `linkCli` controls whether we symlink `remote-pi` + `pi-supervisord`
 * into `~/.local/bin/`. The slash-command path passes `true` (user is
 * inside Pi's TUI — they installed via `pi install npm:remote-pi` and
 * need us to expose the CLI for them). The standalone-CLI path passes
 * `false` because the user is already running our binary from PATH (they
 * did `npm install -g remote-pi`), so re-linking would point their
 * `remote-pi` at the Pi-extension copy and diverge on upgrades.
 */
/** Returns true on success, false when install failed (so the standalone CLI
 *  can exit non-zero — e.g. the Cockpit / CI detect failure by exit code).
 *  We do NOT process.exit here: this also runs inside the Pi TUI, where exiting
 *  would kill the session. */
export function cmdInstall(ctx: Pick<ExtensionContext, "ui">, opts: { linkCli?: boolean } = {}): boolean {
  const linkCli = opts.linkCli ?? false;
  try {
    const result = installService();
    const sections = [
      `[remote-pi] Supervisor service installed (${result.platform}).`,
      `  Unit: ${result.unitPath}`,
      `  Steps:\n${result.log.map((l) => "    " + l).join("\n")}`,
    ];
    if (linkCli) {
      const link = linkCliBinaries();
      sections.push(
        `  CLI bins linked into ${link.binDir}:`,
        link.links.map((l) => `    ${l.name} → ${l.target}`).join("\n"),
        `  Steps:\n${link.log.map((l) => "    " + l).join("\n")}`,
      );
      if (!link.onPath) {
        if (process.platform === "win32") {
          sections.push(
            `  ⚠ ${link.binDir} was just added to your user PATH (it wasn't there yet).`,
            `    Open a NEW terminal and run \`remote-pi daemons\` to verify.`,
          );
        } else {
          sections.push(
            `  ⚠ ${link.binDir} is not on $PATH yet. Add this line to ~/.zshrc / ~/.bashrc:`,
            `      export PATH="$HOME/.local/bin:$PATH"`,
            `    Then open a new terminal and run \`remote-pi daemons\` to verify.`,
          );
        }
      }
    }
    ctx.ui.notify(sections.join("\n"), "info");
    return true;
  } catch (err) {
    ctx.ui.notify(`[remote-pi] install failed: ${String(err)}`, "error");
    return false;
  }
}

export function cmdUninstall(ctx: Pick<ExtensionContext, "ui">, opts: { linkCli?: boolean } = {}): void {
  const linkCli = opts.linkCli ?? false;
  try {
    const result = uninstallService();
    const sections = [
      `[remote-pi] Supervisor service uninstalled (${result.platform}).`,
      `  Unit: ${result.unitPath} (${result.removed ? "removed" : "not present"})`,
      `  Steps:\n${result.log.map((l) => "    " + l).join("\n")}`,
      `  Note: daemons registry (~/.pi/piper/daemons.json) kept — re-install restores everything.`,
    ];
    if (linkCli) {
      const unlink = unlinkCliBinaries();
      sections.push(
        `  CLI bins cleanup (${unlink.binDir}):`,
        unlink.removed
          .map((r) => `    ${r.name} (${r.existed ? "removed" : "not present"})`)
          .join("\n"),
      );
    }
    ctx.ui.notify(sections.join("\n"), "info");
  } catch (err) {
    ctx.ui.notify(`[remote-pi] uninstall failed: ${String(err)}`, "error");
  }
}

// ── Agent-network commands (plano 19) ─────────────────────────────────────────
