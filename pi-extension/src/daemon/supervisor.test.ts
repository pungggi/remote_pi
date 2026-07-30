import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { createConnection } from "node:net";
import { join } from "node:path";
import { Supervisor, decideFireAction, getSupervisorSockPath } from "./supervisor.js";
import { addDaemon } from "./registry.js";
import { readCronLog } from "./cron_log.js";
import {
  encodeRequest,
  parseReply,
  type ControlReply,
  type ControlRequest,
  type DaemonInfo,
} from "./control_protocol.js";

/**
 * Supervisor integration tests. We spin up a real `Supervisor` against a
 * scratch `REMOTE_PI_HOME`, connect to its UDS, send requests, and
 * inspect replies.
 *
 * `extensionPath` points at a non-existent path so the children's spawn
 * fails fast — sufficient to exercise the supervisor's request/reply
 * surface without actually booting Pi. We test child lifecycle proper
 * in `rpc_child.test.ts` separately (where applicable).
 */

let testHome: string;
let supervisor: Supervisor | null = null;

async function ask<R = ControlReply<unknown>>(req: ControlRequest): Promise<R> {
  return new Promise((resolve, reject) => {
    const sock = createConnection({ path: getSupervisorSockPath() });
    let buf = "";
    sock.setEncoding("utf8");
    sock.on("data", (chunk: string) => {
      buf += chunk;
      const nl = buf.indexOf("\n");
      if (nl >= 0) {
        sock.destroy();
        try { resolve(parseReply(buf.slice(0, nl)) as R); }
        catch (e) { reject(e); }
      }
    });
    sock.on("error", reject);
    sock.write(encodeRequest(req));
  });
}

beforeEach(async () => {
  testHome = mkdtempSync(join(tmpdir(), "pi-sv-"));
  process.env["REMOTE_PI_HOME"] = testHome;
  supervisor = new Supervisor({
    // Point at a non-existent extension. The supervisor will try to
    // spawn `<piBin> --mode rpc -e <path>` and the child exits immediately —
    // fine for testing the control surface (we assert on op replies, not on
    // the child's exit code).
    extensionPath: "/no/such/extension.js",
    // Cross-platform stub: `process.execPath` (node) exists on every OS, so
    // spawn never ENOENTs (a POSIX-only path like `/usr/bin/true` failed on
    // Windows CI). Node rejects the `--mode` arg and exits non-zero right away,
    // which is harmless here — the spawning tests only check `started/restarted`
    // booleans, returned synchronously at spawn time.
    piBin: process.execPath,
  });
  await supervisor.start();
});

afterEach(async () => {
  if (supervisor) {
    await supervisor.stop();
    supervisor = null;
  }
  delete process.env["REMOTE_PI_HOME"];
  try { rmSync(testHome, { recursive: true, force: true }); } catch { /* best-effort */ }
});

describe("Supervisor — control UDS surface", () => {
  test("list returns only the device daemon when registry is empty", async () => {
    const r = await ask({ op: "list" });
    // Plan/120 — the supervisor always spawns a device daemon; with an empty
    // registry it's the only entry.
    expect(r).toMatchObject({ ok: true });
    if (r.ok) {
      const daemons = (r.data as { daemons: DaemonInfo[] }).daemons;
      expect(daemons.length).toBe(1);
      expect(daemons[0].id).toBe("device");
    }
  });

  test("register adds an entry and returns the derived id", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-cwd-"));
    const r = await ask({ op: "register", cwd: tmp }) as ControlReply<{ id: string; cwd: string }>;
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.data!.id).toMatch(/^[0-9a-f]{8}$/);
      expect(r.data!.cwd.length).toBeGreaterThan(0);
    }
  });

  test("register twice rejects with `already registered`", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-dup-"));
    await ask({ op: "register", cwd: tmp });
    const r = await ask({ op: "register", cwd: tmp });
    expect(r).toMatchObject({ ok: false });
    if (!r.ok) expect(r.error).toMatch(/already registered/i);
  });

  test("start spawns a single registered daemon by id", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-start-"));
    const reg = await ask({ op: "register", cwd: tmp }) as ControlReply<{ id: string }>;
    expect(reg.ok).toBe(true);
    const id = reg.ok ? reg.data!.id : "";
    const r = await ask({ op: "start", id }) as ControlReply<{ id: string; started: boolean }>;
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.data!.id).toBe(id);
      expect(r.data!.started).toBe(true);
    }
  });

  test("start of unknown id returns ok:false", async () => {
    const r = await ask({ op: "start", id: "ffffffff" });
    expect(r).toMatchObject({ ok: false });
    if (!r.ok) expect(r.error).toMatch(/no daemon/i);
  });

  test("stop of unknown id returns ok:false", async () => {
    const r = await ask({ op: "stop", id: "ffffffff" });
    expect(r).toMatchObject({ ok: false });
    if (!r.ok) expect(r.error).toMatch(/no daemon/i);
  });

  test("restart of unknown id returns ok:false", async () => {
    const r = await ask({ op: "restart", id: "ffffffff" });
    expect(r).toMatchObject({ ok: false });
    if (!r.ok) expect(r.error).toMatch(/no daemon/i);
  });

  test("stop of a registered-but-not-running daemon → ok:true, stopped:false", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-stop-"));
    const reg = await ask({ op: "register", cwd: tmp }) as ControlReply<{ id: string }>;
    const id = reg.ok ? reg.data!.id : "";
    const r = await ask({ op: "stop", id }) as ControlReply<{ id: string; stopped: boolean }>;
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.data!.id).toBe(id);
      expect(r.data!.stopped).toBe(false);
    }
  });

  test("restart spawns a single registered daemon by id", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-restart-"));
    const reg = await ask({ op: "register", cwd: tmp }) as ControlReply<{ id: string }>;
    const id = reg.ok ? reg.data!.id : "";
    const r = await ask({ op: "restart", id }) as ControlReply<{ id: string; restarted: boolean }>;
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.data!.id).toBe(id);
      expect(r.data!.restarted).toBe(true);
    }
  });

  test("send to unknown daemon returns ok:false with clear error", async () => {
    const r = await ask({ op: "send", id: "ffffffff", text: "hi" });
    expect(r).toMatchObject({ ok: false });
    if (!r.ok) expect(r.error).toMatch(/not running/i);
  });

  test("unregister of unknown id returns removed:false (not an error)", async () => {
    const r = await ask({ op: "unregister", id: "ffffffff" });
    // Unregister is idempotent at the supervisor — it always returns ok:true
    // with `removed: false` when nothing matched, so a CLI script can
    // call it repeatedly without failing.
    expect(r).toMatchObject({ ok: true, data: { removed: false } });
  });

  test("malformed request returns ok:false with parser error", async () => {
    const reply = await new Promise<ControlReply<unknown>>((resolve, reject) => {
      const sock = createConnection({ path: getSupervisorSockPath() });
      let buf = "";
      sock.setEncoding("utf8");
      sock.on("data", (c: string) => {
        buf += c;
        const nl = buf.indexOf("\n");
        if (nl >= 0) { sock.destroy(); try { resolve(parseReply(buf.slice(0, nl))); } catch (e) { reject(e); } }
      });
      sock.on("error", reject);
      sock.write("{not-json}\n");
    });
    expect(reply).toMatchObject({ ok: false });
    if (!reply.ok) expect(reply.error).toMatch(/malformed/i);
  });

  test("unknown op returns ok:false", async () => {
    // Bypass the typed encoder so we can send an op the type system
    // doesn't know about.
    const reply = await new Promise<ControlReply<unknown>>((resolve, reject) => {
      const sock = createConnection({ path: getSupervisorSockPath() });
      let buf = "";
      sock.setEncoding("utf8");
      sock.on("data", (c: string) => {
        buf += c;
        const nl = buf.indexOf("\n");
        if (nl >= 0) { sock.destroy(); try { resolve(parseReply(buf.slice(0, nl))); } catch (e) { reject(e); } }
      });
      sock.on("error", reject);
      sock.write('{"op":"frobnicate"}\n');
    });
    expect(reply).toMatchObject({ ok: false });
    if (!reply.ok) expect(reply.error).toMatch(/unknown op/i);
  });

  test("list reflects a daemon added directly via registry (not just register op)", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-direct-"));
    addDaemon(tmp);
    const r = await ask({ op: "list" }) as ControlReply<{ daemons: Array<{ cwd: string; state: string }> }>;
    expect(r.ok).toBe(true);
    if (r.ok) {
      const found = r.data!.daemons.find((d) => d.cwd.endsWith(tmp.split("/").pop()!));
      expect(found).toBeDefined();
      // State is "stopped" — the children were spawned at supervisor.start()
      // before our addDaemon call, so this entry isn't in the children map.
      expect(found?.state).toBe("stopped");
    }
  });
});

describe("decideFireAction (cron — 4 ramos)", () => {
  test("running + idle → send", () => {
    expect(decideFireAction({ running: true, busy: false, wake: false, skipIfBusy: true })).toBe("send");
  });
  test("running + busy + skip_if_busy → skip_busy", () => {
    expect(decideFireAction({ running: true, busy: true, wake: false, skipIfBusy: true })).toBe("skip_busy");
  });
  test("running + busy + no skip_if_busy → send", () => {
    expect(decideFireAction({ running: true, busy: true, wake: false, skipIfBusy: false })).toBe("send");
  });
  test("down + no wake → skip_down", () => {
    expect(decideFireAction({ running: false, busy: false, wake: false, skipIfBusy: true })).toBe("skip_down");
  });
  test("down + wake → wake_and_send", () => {
    expect(decideFireAction({ running: false, busy: false, wake: true, skipIfBusy: true })).toBe("wake_and_send");
  });
});

describe("Supervisor — cron ops", () => {
  async function registerDaemon(): Promise<string> {
    const tmp = mkdtempSync(join(tmpdir(), "pi-cron-d-"));
    const r = await ask({ op: "register", cwd: tmp }) as ControlReply<{ id: string }>;
    return r.ok ? r.data!.id : "";
  }

  test("cron_add validates: invalid expr + <60s rejected, valid accepted", async () => {
    const daemon_id = await registerDaemon();
    const bad = await ask({ op: "cron_add", daemon_id, schedule: "nope", prompt: "p" });
    expect(bad.ok).toBe(false);
    const tooFreq = await ask({ op: "cron_add", daemon_id, schedule: "* * * * * *", prompt: "p" });
    expect(tooFreq).toMatchObject({ ok: false });
    if (!tooFreq.ok) expect(tooFreq.error).toMatch(/60s|too frequent/i);
    const good = await ask({ op: "cron_add", daemon_id, schedule: "0 9 * * *", prompt: "p" }) as ControlReply<{ job: { id: string } }>;
    expect(good.ok).toBe(true);
    expect(good.ok && good.data!.job.id).toMatch(/^j_/);
  });

  test("cron list/enable/remove round-trip", async () => {
    const daemon_id = await registerDaemon();
    const add = await ask({ op: "cron_add", daemon_id, schedule: "0 9 * * *", prompt: "p" }) as ControlReply<{ job: { id: string } }>;
    const jobId = add.ok ? add.data!.job.id : "";

    const list = await ask({ op: "cron_list" }) as ControlReply<{ jobs: Array<{ id: string; next_run?: string | null }> }>;
    expect(list.ok && list.data!.jobs.some((j) => j.id === jobId && !!j.next_run)).toBe(true);

    const dis = await ask({ op: "cron_enable", job_id: jobId, enabled: false }) as ControlReply<{ updated: boolean }>;
    expect(dis.ok && dis.data!.updated).toBe(true);

    const rm = await ask({ op: "cron_remove", job_id: jobId }) as ControlReply<{ removed: boolean }>;
    expect(rm.ok && rm.data!.removed).toBe(true);
    const list2 = await ask({ op: "cron_list" }) as ControlReply<{ jobs: unknown[] }>;
    expect(list2.ok && list2.data!.jobs.length).toBe(0);
  });

  test("cron_run on a down daemon → skipped_down, recorded + logged", async () => {
    const daemon_id = await registerDaemon(); // registered, not started → not running
    const add = await ask({ op: "cron_add", daemon_id, schedule: "0 9 * * *", prompt: "ping" }) as ControlReply<{ job: { id: string } }>;
    const jobId = add.ok ? add.data!.job.id : "";

    const run = await ask({ op: "cron_run", job_id: jobId }) as ControlReply<{ result: string }>;
    expect(run.ok && run.data!.result).toBe("skipped_down");

    // logged to cron.jsonl
    const log = readCronLog({ jobId });
    expect(log.at(-1)).toMatchObject({ result: "skipped_down", fired: false });

    // last_status reflected in cron list
    const list = await ask({ op: "cron_list" }) as ControlReply<{ jobs: Array<{ id: string; last_status?: string }> }>;
    const job = list.ok ? list.data!.jobs.find((j) => j.id === jobId) : undefined;
    expect(job?.last_status).toBe("skipped_down");
  });

  test("cron_run on an unknown job → ok:false", async () => {
    const r = await ask({ op: "cron_run", job_id: "j_unknown" });
    expect(r).toMatchObject({ ok: false });
  });
});
