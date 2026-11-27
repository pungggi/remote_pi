import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { writePairStub } from "../test-helpers.js";
import {
  RpcChild,
  busyTransition,
  parseCustomMessageEnd,
  parsePairCodeDetails,
  resolvePiBin, resolvePiSpawn, termuxPiScript, _npmShimTarget, rpcSpawnArgs, type RpcChildExitEvent } from "./rpc_child.js";

/**
 * Regression for the orphaned-daemon bug: a deliberate `stop()` kills the
 * child by signal (SIGTERM/SIGKILL), which used to look like a crash and trip
 * the supervisor's auto-restart — re-spawning a daemon the operator just
 * stopped/removed. `stop()` must report a clean exit instead.
 *
 * We use a tiny executable that ignores the `--mode rpc -e <path>` args and
 * just sleeps, so the child is genuinely alive when we stop it.
 */
describe("rpcSpawnArgs", () => {
  test("includes --continue so a restart resumes the latest session (not a new one)", () => {
    expect(rpcSpawnArgs("/path/to/dist/index.js")).toEqual([
      "--mode", "rpc", "--approve", "--continue", "-ne", "-e", "/path/to/dist/index.js",
    ]);
  });

  test("pins the session display name via --name when one is given", () => {
    expect(rpcSpawnArgs("/path/to/dist/index.js", "PC")).toEqual([
      "--mode", "rpc", "--approve", "--continue", "--name", "PC", "-ne", "-e", "/path/to/dist/index.js",
    ]);
  });

  test("can omit --continue for one daemon fresh-session restart", () => {
    expect(rpcSpawnArgs("/path/to/dist/index.js", "PC", false)).toEqual([
      "--mode", "rpc", "--approve", "--name", "PC", "-ne", "-e", "/path/to/dist/index.js",
    ]);
  });

  // Plan/167 — headless spawn: the model rides along as the standard CLI
  // flag so a transient worker can run a cheaper/different model than the
  // spawning agent.
  test("plan/167: appends --model provider/id when one is given", () => {
    expect(rpcSpawnArgs("/path/to/dist/index.js", "w", true, "anthropic/claude-opus-4-7")).toEqual([
      "--mode", "rpc", "--approve", "--continue", "--name", "w",
      "--model", "anthropic/claude-opus-4-7",
      "-ne", "-e", "/path/to/dist/index.js",
    ]);
  });

  test("plan/167: no --model flag when model is omitted", () => {
    const args = rpcSpawnArgs("/path/to/dist/index.js", "w");
    expect(args).not.toContain("--model");
  });

  test("always passes --approve (pi >=0.79 project trust; RPC is non-interactive)", () => {
    expect(rpcSpawnArgs("/path/to/dist/index.js")).toContain("--approve");
    expect(rpcSpawnArgs("/path/to/dist/index.js", "PC", false)).toContain("--approve");
  });

  // 2026-08 incident: a typo'd user-global extension (unterminated template
  // literal in vision-proxy.ts) is FATAL at pi boot and killed the whole
  // daemon fleet — the phone showed "Device unreachable" until the typo was
  // fixed. `-ne` isolates daemons from user extension discovery while the
  // explicit `-e` still loads remote-pi itself.
  test("isolates daemons from user extensions: -ne disables discovery, -e still loads remote-pi", () => {
    for (const args of [
      rpcSpawnArgs("/path/to/dist/index.js"),
      rpcSpawnArgs("/path/to/dist/index.js", "PC"),
      rpcSpawnArgs("/path/to/dist/index.js", "PC", false),
    ]) {
      expect(args).toContain("-ne");
      // discovery off must NOT mean our own extension is off
      expect(args[args.indexOf("-e") + 1]).toBe("/path/to/dist/index.js");
    }
  });
});

describe("RpcChild — deliberate stop is not a crash", () => {
  let dir: string;

  afterEach(() => {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort */ }
  });

  // POSIX-only: uses a `.sh` stub + SIGTERM/SIGKILL semantics. The RpcChild
  // stop() logic is cross-platform; only this stub/signal harness is POSIX.
  test.skipIf(process.platform === "win32")("stop() emits isCrash:false though the child dies by signal", async () => {
    dir = mkdtempSync(join(tmpdir(), "pi-rpcchild-"));
    const bin = join(dir, "staysalive.sh");
    writeFileSync(bin, "#!/bin/sh\nexec sleep 30\n");
    chmodSync(bin, 0o755);

    const child = new RpcChild({ piBin: bin, extensionPath: "/no/such.js", cwd: dir });
    const exited = new Promise<RpcChildExitEvent>((resolve) => child.once("exit", resolve));
    child.spawn();
    // Let the process actually exec before we signal it.
    await new Promise((r) => setTimeout(r, 50));
    await child.stop();

    const evt = await exited;
    expect(evt.isCrash).toBe(false);   // ← was `true` before the fix → spurious restart
    expect(child.state).toBe("stopped");
  });
});

/**
 * Plan/168 — ping(): event-loop liveness probe over the child's stdin
 * RPC. The stub "pi" ignores its args (like the stop test above) and either
 * answers every `get_state` with a canned reply (responsive) or reads stdin
 * and stays silent (wedged) — the 2026-11-22 zombie shape.
 *
 * Windows: an npm-style `pi.cmd` shim + a real `cli.js` stub node script
 * (resolvePiSpawn spawns `node cli.js --mode rpc …`). POSIX: a shell script.
 * Both stay alive reading stdin, so `state === "running"` holds.
 */
const STUB_CLI_JS = `
let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => {
  buf += c;
  let nl;
  while ((nl = buf.indexOf("\\n")) >= 0) {
    const line = buf.slice(0, nl);
    buf = buf.slice(nl + 1);
    if (process.env["STUB_SILENT"] === "1") continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg && msg.type === "get_state") {
      process.stdout.write(JSON.stringify({ id: msg.id, type: "response", command: "get_state", data: { isStreaming: false } }) + "\\n");
    }
  }
});
setInterval(() => {}, 60_000);
`;

function makeStubPi(dir: string): string {
  if (process.platform === "win32") {
    const rel = join("node_modules", "stub-pi", "cli.js");
    const target = join(dir, rel);
    mkdirSync(join(target, ".."), { recursive: true });
    writeFileSync(target, STUB_CLI_JS);
    const shim = join(dir, "pi.cmd");
    writeFileSync(shim, `@ECHO off\r\n"%_prog%"  "%dp0%\\${rel}" %*\r\n`);
    return shim;
  }
  const bin = join(dir, "stubsilent.sh");
  writeFileSync(bin, "#!/bin/sh\nwhile IFS= read -r line; do\n" +
    '  if [ "$STUB_SILENT" != "1" ]; then\n' +
    '    case "$line" in *get_state*)\n' +
    '      id=$(printf \'%s\' "$line" | sed -n \'s/.*"id":"\\([^"]*\\)".*/\\1/p\')\n' +
    '      printf \'{"id":"%s","type":"response","command":"get_state","data":{"isStreaming":false}}\\n\' "$id";;\n' +
    '    esac\n  fi\ndone\n');
  chmodSync(bin, 0o755);
  return bin;
}

describe("RpcChild — ping (plan/168 wedge detector)", () => {
  let dir: string;
  afterEach(() => {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort */ }
    delete process.env["STUB_SILENT"];
  });

  test("ping resolves false without a running child", async () => {
    dir = mkdtempSync(join(tmpdir(), "pi-ping-"));
    const child = new RpcChild({ piBin: makeStubPi(dir), extensionPath: "/no/such.js", cwd: dir });
    expect(child.state).toBe("stopped");
    await expect(child.ping(100)).resolves.toBe(false);
  });

  test("a responsive child answers ping (busy turns keep the loop alive)", async () => {
    dir = mkdtempSync(join(tmpdir(), "pi-ping-"));
    const child = new RpcChild({ piBin: makeStubPi(dir), extensionPath: "/no/such.js", cwd: dir });
    child.spawn();
    // Give the stub a moment to boot before pinging.
    await new Promise((r) => setTimeout(r, 300));
    await expect(child.ping(4_000)).resolves.toBe(true);
    await child.stop();
  });

  test("a silent (wedged) child misses the ping", async () => {
    dir = mkdtempSync(join(tmpdir(), "pi-ping-"));
    const child = new RpcChild({
      piBin: makeStubPi(dir),
      extensionPath: "/no/such.js",
      cwd: dir,
      env: { STUB_SILENT: "1" },
    });
    child.spawn();
    await new Promise((r) => setTimeout(r, 300));
    await expect(child.ping(300)).resolves.toBe(false);
    await child.stop();
  });
});

describe("resolvePiBin (plan/40 — Windows pi.cmd)", () => {
  test("POSIX → returns the bin name unchanged", () => {
    expect(resolvePiBin("pi", "darwin")).toBe("pi");
    expect(resolvePiBin("pi", "linux")).toBe("pi");
    expect(resolvePiBin("/opt/homebrew/bin/pi", "darwin")).toBe("/opt/homebrew/bin/pi");
  });
  test("Windows → an explicit path or suffixed name is used as-is (no lookup)", () => {
    expect(resolvePiBin("C:\\tools\\pi.cmd", "win32")).toBe("C:\\tools\\pi.cmd");
    expect(resolvePiBin("pi.cmd", "win32")).toBe("pi.cmd");
    expect(resolvePiBin("C:/tools/pi", "win32")).toBe("C:/tools/pi");
  });
  // The bare-`pi`-on-win32 lookup is exercised via the injectable `where`
  // stub (3rd arg of resolvePiBin) — deterministic on any host, no real
  // `where` needed and the host's own PATH/APPDATA can't leak in.
  test("Windows bare name → prefers a runnable .cmd/.exe over the extensionless first line (where order)", () => {
    // `where` PATH order on pi-node installs puts the unrunnable extensionless
    // `pi` first; picking it yields spawn ENOENT → "crashed".
    expect(resolvePiBin("pi", "win32", () => "C:\\npm\\pi\r\nC:\\npm\\pi.cmd")).toBe("C:\\npm\\pi.cmd");
    expect(resolvePiBin("pi", "win32", () => "C:\\npm\\pi\r\nC:\\npm\\pi.exe")).toBe("C:\\npm\\pi.exe");
    // Only the extensionless script found → first line (unchanged behavior).
    expect(resolvePiBin("pi", "win32", () => "C:\\npm\\pi")).toBe("C:\\npm\\pi");
  });

  test("Windows PATH-less env → falls back to %APPDATA%\\npm\\pi.cmd when `where` fails (2026-11-16)", () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-appdata-"));
    const origAppdata = process.env.APPDATA;
    try {
      const npmDir = join(tmp, "npm");
      mkdirSync(npmDir, { recursive: true });
      const shim = join(npmDir, "pi.cmd");
      writeFileSync(shim, "@echo off\r\n");
      process.env.APPDATA = tmp;
      const noWhere = () => { throw new Error("where failed"); };
      expect(resolvePiBin("pi", "win32", noWhere)).toBe(shim);
      // Shim missing on disk → bare name (spawn surfaces ENOENT honestly).
      rmSync(shim);
      expect(resolvePiBin("pi", "win32", noWhere)).toBe("pi");
      // APPDATA unset → bare name, never a bogus relative "npm\\pi.cmd".
      delete process.env.APPDATA;
      writeFileSync(shim, "@echo off\r\n");
      expect(resolvePiBin("pi", "win32", noWhere)).toBe("pi");
    } finally {
      if (origAppdata === undefined) delete process.env.APPDATA;
      else process.env.APPDATA = origAppdata;
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  test("Windows → a successful `where` still wins over the APPDATA fallback", () => {
    // Real PATH resolution is never second-guessed by the shim fallback.
    expect(resolvePiBin("pi", "win32", () => "C:\\opt\\pi.cmd")).toBe("C:\\opt\\pi.cmd");
  });
});

describe("_npmShimTarget (plan/40 — parse the .cmd shim)", () => {
  let tmp: string;
  afterEach(() => { if (tmp) rmSync(tmp, { recursive: true, force: true }); });

  test("recovers the cli.js the npm shim launches (relative to the shim dir)", () => {
    tmp = mkdtempSync(join(tmpdir(), "pi-shim-"));
    // Mimic the npm-generated shim layout: <dir>\pi.cmd + <dir>\node_modules\…\cli.js
    const rel = join("node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
    const target = join(tmp, rel);
    require("node:fs").mkdirSync(join(target, ".."), { recursive: true });
    writeFileSync(target, "// cli\n");
    const shim = join(tmp, "pi.cmd");
    // The relevant line of a real npm cmd shim (forward-slash dp0 segment varies;
    // the launcher always quotes "%dp0%\<relative>").
    writeFileSync(shim, `@ECHO off\r\n"%_prog%"  "%dp0%\\${rel}" %*\r\n`);
    expect(_npmShimTarget(shim)).toBe(target);
  });

  test("returns null when the shim doesn't match / target missing", () => {
    tmp = mkdtempSync(join(tmpdir(), "pi-shim-"));
    const shim = join(tmp, "weird.cmd");
    writeFileSync(shim, "@echo off\r\necho nope\r\n");
    expect(_npmShimTarget(shim)).toBeNull();
    // points at a non-existent target → null (don't hand spawn a bad path)
    const shim2 = join(tmp, "pi.cmd");
    writeFileSync(shim2, `"%_prog%" "%dp0%\\does-not-exist.js" %*\r\n`);
    expect(_npmShimTarget(shim2)).toBeNull();
  });
});

describe("resolvePiSpawn (plan/40 — directly-spawnable target)", () => {
  test("POSIX → command is pi, no prefix args", () => {
    expect(resolvePiSpawn("pi", "linux")).toEqual({ command: "pi", prefixArgs: [] });
    expect(resolvePiSpawn("/usr/bin/pi", "darwin")).toEqual({ command: "/usr/bin/pi", prefixArgs: [] });
  });

  // 2026-11-27: on the owner's phone every `spawn pi` from a Termux:Boot-started
  // supervisor ended in ENOENT (shebang `/usr/bin/env node`, no termux-exec).
  test("Termux → node plus the cli.js behind `pi`; nothing found → the POSIX answer", () => {
    const node = "/data/data/com.termux/files/usr/bin/node";
    const cli = "/data/data/com.termux/files/usr/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js";
    expect(resolvePiSpawn("pi", "android", node, cli)).toEqual({ command: node, prefixArgs: [cli] });
    expect(resolvePiSpawn("/usr/bin/pi", "android", node, cli)).toEqual({ command: node, prefixArgs: [cli] });
    // Null (not resolved, or not Termux): `spawn` reports the real error.
    expect(resolvePiSpawn("pi", "android", node, null)).toEqual({ command: "pi", prefixArgs: [] });
  });

  test("Windows .cmd shim → spawn node + parsed cli.js (no cmd.exe layer)", () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-spawn-"));
    try {
      const rel = join("node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
      const target = join(tmp, rel);
      require("node:fs").mkdirSync(join(target, ".."), { recursive: true });
      writeFileSync(target, "// cli\n");
      const shim = join(tmp, "pi.cmd");
      writeFileSync(shim, `"%_prog%" "%dp0%\\${rel}" %*\r\n`);
      const r = resolvePiSpawn(shim, "win32", "C:\\node\\node.exe");
      expect(r.command).toBe("C:\\node\\node.exe");
      expect(r.prefixArgs).toEqual([target]);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  test("Windows explicit .exe → used as-is, no prefix args", () => {
    expect(resolvePiSpawn("C:\\tools\\pi.exe", "win32")).toEqual({
      command: "C:\\tools\\pi.exe",
      prefixArgs: [],
    });
  });
});

// ── termuxPiScript: the cli.js behind `pi` (2026-11-27) ─────────────────────
//
// npm links `pi` to a `.js` file with the shebang `#!/usr/bin/env node`.
// Android has no `/usr/bin/env`; in a Termux shell libtermux-exec rewrites
// the shebang, a supervisor started by Termux:Boot has no such preload.
describe("termuxPiScript", () => {
  let tmp: string;
  let bin: string;
  let lib: string;
  const cli = (): string => join(lib, "node_modules", "@earendil-works", "pi-coding-agent", "dist", "bundle", "cli.js");

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "pi-termux-pi-"));
    bin = join(tmp, "usr", "bin");
    lib = join(tmp, "usr", "lib");
    mkdirSync(bin, { recursive: true });
    mkdirSync(dirname(cli()), { recursive: true });
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  test.skipIf(process.platform === "win32")("`pi` as a symlink to npm's cli.js: the real file, found on a `:`-separated PATH", () => {
    writeFileSync(cli(), "#!/usr/bin/env node\n");
    chmodSync(cli(), 0o755);
    symlinkSync(cli(), join(bin, "pi"));
    // Empty entries and a trailing slash are tolerated, as in a real PATH.
    const envPath = `${join(tmp, "nowhere")}/bin::${bin}/:`;
    expect(termuxPiScript("pi", envPath)).toBe(realpathSync(cli()));
    // An explicit path needs no PATH.
    expect(termuxPiScript(join(bin, "pi"), "")).toBe(realpathSync(cli()));
  });

  // The next two look `pi` up on a POSIX PATH: a Windows path carries a drive
  // colon, which the `:` separator would split.
  test.skipIf(process.platform === "win32")("a node shebang counts without an extension; other interpreters and binaries do not", () => {
    const pi = join(bin, "pi");
    writeFileSync(pi, "#!/usr/bin/env node\n// pi\n");
    chmodSync(pi, 0o755);
    expect(termuxPiScript("pi", bin)).toBe(realpathSync(pi));
    writeFileSync(pi, "#!/data/data/com.termux/files/usr/bin/env -S node --flag\n");
    expect(termuxPiScript("pi", bin)).toBe(realpathSync(pi));
    // A shell script with an absolute shebang starts by itself: leave it to spawn.
    writeFileSync(pi, "#!/data/data/com.termux/files/usr/bin/sh\nexit 0\n");
    expect(termuxPiScript("pi", bin)).toBeNull();
    // A native binary.
    writeFileSync(pi, Buffer.from([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
    expect(termuxPiScript("pi", bin)).toBeNull();
  });

  test("nothing found, an empty PATH, a non-executable and a missing explicit path answer null", () => {
    expect(termuxPiScript("pi", bin)).toBeNull();
    expect(termuxPiScript("pi", "")).toBeNull();
    // Not executable: a PATH lookup skips it, as a shell would.
    writeFileSync(join(bin, "pi"), "#!/usr/bin/env node\n");
    if (process.platform !== "win32") expect(termuxPiScript("pi", bin)).toBeNull();
    expect(termuxPiScript(join(bin, "missing"), "")).toBeNull();
  });

  test.skipIf(process.platform === "win32")("a dangling link answers null", () => {
    symlinkSync(join(bin, "nowhere.js"), join(bin, "pi"));
    expect(termuxPiScript("pi", bin)).toBeNull();
  });

  test.skipIf(process.platform === "win32")("the first PATH entry that holds `pi` wins; `.mjs` / `.cjs` count as scripts too", () => {
    const other = join(tmp, "other-bin");
    mkdirSync(other);
    for (const [dir, name] of [[other, "pi"], [bin, "pi"], [other, "pi.mjs"], [other, "pi.cjs"]] as const) {
      const file = join(dir, name);
      writeFileSync(file, "#!/usr/bin/env node\n");
      // For a PATH lookup the file must be executable; an explicit path with a
      // script extension needs neither the bit nor the shebang.
      chmodSync(file, name === "pi" ? 0o755 : 0o644);
    }
    expect(termuxPiScript("pi", `${other}:${bin}`)).toBe(realpathSync(join(other, "pi")));
    expect(termuxPiScript("pi", `${bin}:${other}`)).toBe(realpathSync(join(bin, "pi")));
    expect(termuxPiScript(join(other, "pi.mjs"), "")).toBe(realpathSync(join(other, "pi.mjs")));
    expect(termuxPiScript(join(other, "pi.cjs"), "")).toBe(realpathSync(join(other, "pi.cjs")));
  });
});

describe("busyTransition (stream markers)", () => {
  test("message_start → true, message_end → false", () => {
    expect(busyTransition('{"type":"message_start"}')).toBe(true);
    expect(busyTransition('{"type":"message_end"}')).toBe(false);
  });
  test("other events + garbage → null (no change)", () => {
    expect(busyTransition('{"type":"session_info_changed"}')).toBeNull();
    expect(busyTransition('{"type":"response","command":"prompt"}')).toBeNull();
    expect(busyTransition("not json")).toBeNull();
  });
});

describe("RpcChild — isBusy", () => {
  let dir: string;
  afterEach(() => {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort */ }
  });

  test("passive flag opens/closes on stream markers", () => {
    dir = mkdtempSync(join(tmpdir(), "pi-busy-"));
    const child = new RpcChild({ piBin: "/usr/bin/true", extensionPath: "/x", cwd: dir });
    expect(child.isBusy).toBe(false);
    child._ingestStdoutForTest('{"type":"message_start"}');
    expect(child.isBusy).toBe(true);
    child._ingestStdoutForTest('{"type":"message_end"}');
    expect(child.isBusy).toBe(false);
  });

  // POSIX-only harness: the stub is a `#!/usr/bin/env node` shebang script,
  // which Windows can't spawn directly. refreshBusy itself is cross-platform;
  // the get_state correlation logic is also covered by the unit pieces above.
  test.skipIf(process.platform === "win32")("refreshBusy syncs from get_state.isStreaming (authoritative)", async () => {
    dir = mkdtempSync(join(tmpdir(), "pi-busy-gs-"));
    // Stub that answers get_state with isStreaming:true (ignores rpc args).
    const stub = join(dir, "stub.mjs");
    writeFileSync(
      stub,
      "#!/usr/bin/env node\n" +
      "process.stdin.setEncoding('utf8');let b='';" +
      "process.stdin.on('data',c=>{b+=c;let n;while((n=b.indexOf('\\n'))>=0){const l=b.slice(0,n);b=b.slice(n+1);" +
      "try{const m=JSON.parse(l);if(m.type==='get_state')process.stdout.write(JSON.stringify({type:'response',command:'get_state',id:m.id,success:true,data:{isStreaming:true}})+'\\n');}catch{}}});" +
      "setInterval(()=>{},1e9);\n",
    );
    chmodSync(stub, 0o755);

    const child = new RpcChild({ piBin: stub, extensionPath: "/x", cwd: dir });
    child.spawn();
    await new Promise((r) => setTimeout(r, 80)); // let it exec
    const busy = await child.refreshBusy(1500);
    expect(busy).toBe(true);
    expect(child.isBusy).toBe(true);
    await child.stop();
  });

  test("refreshBusy returns the passive flag when the child isn't running", async () => {
    dir = mkdtempSync(join(tmpdir(), "pi-busy-off-"));
    const child = new RpcChild({ piBin: "/usr/bin/true", extensionPath: "/x", cwd: dir });
    // never spawned → not running → returns passive _busy (false)
    expect(await child.refreshBusy(200)).toBe(false);
  });
});

// ── Plan/173 — custom messages + the pairing link ───────────────────────────

describe("parseCustomMessageEnd", () => {
  const pair = {
    type: "message_end",
    message: {
      role: "custom", customType: "remote-pi:pair-code", content: "QR", display: true, timestamp: 1,
      details: { uri: "remotepi://pair?t=abc", token: "abc", expiresAt: 1900000000000, roomId: "device", name: "device" },
    },
  };

  test("recognises a custom message and returns its details object", () => {
    expect(parseCustomMessageEnd(JSON.stringify(pair))).toEqual({
      customType: "remote-pi:pair-code",
      details: pair.message.details,
    });
  });

  test("accepts details restored from the session file as a JSON string", () => {
    const line = JSON.stringify({ ...pair, message: { ...pair.message, details: JSON.stringify(pair.message.details) } });
    expect(parseCustomMessageEnd(line)?.details).toEqual(pair.message.details);
  });

  test("everything else is null: other roles, responses, malformed JSON, no role", () => {
    expect(parseCustomMessageEnd(JSON.stringify({ type: "message_end", message: { role: "assistant", content: [] } }))).toBeNull();
    expect(parseCustomMessageEnd(JSON.stringify({ type: "response", command: "prompt", success: true }))).toBeNull();
    expect(parseCustomMessageEnd("{not json")).toBeNull();
    expect(parseCustomMessageEnd(JSON.stringify({ type: "message_end", message: { role: "custom" } }))).toBeNull();
  });

  test("a custom message without usable details carries null details", () => {
    const line = JSON.stringify({ type: "message_end", message: { role: "custom", customType: "remote-pi:x", details: "[1,2]" } });
    expect(parseCustomMessageEnd(line)).toEqual({ customType: "remote-pi:x", details: null });
  });
});

describe("parsePairCodeDetails", () => {
  const good = { uri: "remotepi://pair?t=abc&epk=k&n=device&rm=device", token: "abc", expiresAt: 1900000000000, roomId: "device", name: "device" };

  test("returns the four fields the CLI prints / forwards", () => {
    expect(parsePairCodeDetails(good)).toEqual({
      uri: good.uri, expiresAt: good.expiresAt, roomId: "device", name: "device",
    });
  });

  test("refuses a foreign URI scheme, missing fields and mistyped numbers", () => {
    expect(parsePairCodeDetails(null)).toBeNull();
    expect(parsePairCodeDetails({ ...good, uri: "https://evil.example/pair?x" })).toBeNull();
    expect(parsePairCodeDetails({ ...good, expiresAt: "soon" })).toBeNull();
    expect(parsePairCodeDetails({ ...good, roomId: "" })).toBeNull();
    const { name: _n, ...noName } = good;
    expect(parsePairCodeDetails(noName)).toBeNull();
  });
});

describe("RpcChild.requestCustomMessage (plan/173)", () => {
  let dir: string;
  let log: string;

  afterEach(() => {
    delete process.env["STUB_LOG"];
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort */ }
  });

  test("sends the prompt and resolves with the custom message's details", async () => {
    dir = mkdtempSync(join(tmpdir(), "pi-pair-"));
    log = join(dir, "prompts.log");
    process.env["STUB_LOG"] = log;
    const stub = writePairStub(dir);
    const child = new RpcChild({ piBin: stub, extensionPath: "/x", cwd: dir });
    child.spawn();
    try {
      const details = await child.requestCustomMessage("remote-pi:pair-code", "/remote-pi pair --ttl 600", 5000);
      expect(details).toMatchObject({
        uri: "remotepi://pair?t=abc&epk=k&n=device&rm=device",
        expiresAt: 1900000000000,
        roomId: "device",
        name: "device",
      });
      // The slash command reached the child's stdin verbatim.
      expect(readFileSync(log, "utf8")).toBe("/remote-pi pair --ttl 600\n");
    } finally {
      await child.stop();
    }
  });

  test("a stopped child answers null instead of hanging", async () => {
    dir = mkdtempSync(join(tmpdir(), "pi-pair-off-"));
    log = join(dir, "prompts.log");
    process.env["STUB_LOG"] = log;
    const child = new RpcChild({ piBin: writePairStub(dir), extensionPath: "/x", cwd: dir });
    child.spawn();
    // The stub only pairs once, so a request for another type stays pending
    // until stop(). The same-type request made while the first is in flight
    // is refused, not queued (no I/O happens between the two sync calls).
    const first = child.requestCustomMessage("remote-pi:pair-code", "/remote-pi pair --ttl 60", 10_000);
    expect(await child.requestCustomMessage("remote-pi:pair-code", "/remote-pi pair --ttl 60", 10)).toBeNull();
    const never = child.requestCustomMessage("remote-pi:never", "x", 10_000);
    expect(await first).not.toBeNull();
    await child.stop();
    expect(await never).toBeNull();
  });

  test("not running → null without touching a pipe", async () => {
    dir = mkdtempSync(join(tmpdir(), "pi-pair-none-"));
    const child = new RpcChild({ piBin: "/usr/bin/true", extensionPath: "/x", cwd: dir });
    expect(await child.requestCustomMessage("remote-pi:x", "y", 100)).toBeNull();
  });
});
