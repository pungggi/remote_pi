import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { spawnSync } from "node:child_process";
import { existsSync, lstatSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join } from "node:path";

/** POSIX-only describes: features the Bloco C (plan/40) intentionally skips on
 *  Windows (symlinks/`~/.local/bin`, systemd, launchd). */
const posixOnly = process.platform === "win32";
import {
  buildCmdShim,
  buildElevatedCmd,
  defaultRenderVars,
  detectPlatform,
  findNodeBinary,
  findSupervisorScript,
  findRemotePiScript,
  findTemplate,
  installService,
  isGeneratedBootScript,
  isOnPath,
  launchdPlistPath,
  lineDiff,
  linkCliBinaries,
  normalizeUnitText,
  previewTermuxBootScript,
  renderLineDiff,
  renderTemplate,
  systemdUnitPath,
  toLf,
  uninstallService,
  unlinkCliBinaries,
  userLocalBinDir,
  vbsLauncherPath,
} from "./install.js";
import { termuxBootBackupDir } from "../termux.js";

/**
 * Pure-function tests for the install module. We do NOT exercise the
 * actual `launchctl`/`systemctl` calls — those are platform-specific +
 * change real OS state. The smoke test for activation is documented in
 * the README and run manually.
 */

/** Template text with the checkout's line endings removed. On a Windows
 *  checkout with core.autocrlf the file arrives with CRLF; `.gitattributes`
 *  pins only FUTURE checkouts, so the test must not depend on either. */
function templateText(p: string): string {
  return readFileSync(p, "utf8").replace(/\r\n/g, "\n");
}

describe("detectPlatform", () => {
  test("returns a known platform", () => {
    const p = detectPlatform();
    expect(["macos", "linux", "windows", "android", "unsupported"]).toContain(p);
  });

  // Plan/173 — Termux reports as linux; the Android branch is chosen by the
  // environment, so both are injected here and the suite runs on any host.
  test("android inside Termux, whatever the host OS reports", () => {
    expect(detectPlatform({ TERMUX_VERSION: "119" }, "linux")).toBe("android");
    expect(detectPlatform({ PREFIX: "/data/data/com.termux/files/usr" }, "linux")).toBe("android");
  });

  test("a plain linux box and the other desktops are unchanged", () => {
    expect(detectPlatform({}, "linux")).toBe("linux");
    expect(detectPlatform({}, "darwin")).toBe("macos");
    expect(detectPlatform({}, "win32")).toBe("windows");
    expect(detectPlatform({ TERMUX_VERSION: "119" }, "darwin")).toBe("macos");
    expect(detectPlatform({}, "freebsd")).toBe("unsupported");
  });
});

describe("findNodeBinary", () => {
  test("returns process.execPath (absolute)", () => {
    expect(findNodeBinary()).toBe(process.execPath);
    expect(isAbsolute(findNodeBinary())).toBe(true); // `/...` POSIX, `C:\...` win32
  });
});

describe("findSupervisorScript", () => {
  test("ends with bin/supervisord.js (whatever distRoot is)", () => {
    // `join` yields the platform separator (`/` POSIX, `\` win32).
    expect(findSupervisorScript().endsWith(join("bin", "supervisord.js"))).toBe(true);
  });
});

describe("findTemplate", () => {
  test("systemd template file exists on disk", () => {
    const p = findTemplate("systemd");
    expect(p.endsWith("systemd.service.template")).toBe(true);
    // The file should be readable from this project's checkout (tests
    // run from pi-extension/, and templates live next to dist/).
    const content = readFileSync(p, "utf8");
    expect(content).toContain("[Service]");
    expect(content).toContain("{NODE}");
    expect(content).toContain("{SUPERVISOR}");
  });

  test("launchd template file exists on disk", () => {
    const p = findTemplate("launchd");
    expect(p.endsWith("launchd.plist.template")).toBe(true);
    const content = readFileSync(p, "utf8");
    expect(content).toContain("<key>Label</key>");
    expect(content).toContain("ch.pungitore.piper.supervisord");
    expect(content).toContain("{NODE}");
    expect(content).toContain("{SUPERVISOR}");
  });

  test("task-scheduler (Windows) template file exists on disk (plan/40)", () => {
    const p = findTemplate("taskscheduler");
    expect(p.endsWith("task-scheduler.xml.template")).toBe(true);
    const content = readFileSync(p, "utf8");
    expect(content).toContain("<Task ");
    expect(content).toContain("<LogonTrigger>");
    expect(content).toContain("<RestartOnFailure>");
    // {NODE}/{SUPERVISOR} now live in the VBS launcher, not the XML — the XML's
    // action invokes wscript.exe with {VBS} (asserted below).
    // Must declare UTF-16 to match the UTF-16LE+BOM bytes install.ts writes —
    // schtasks /Create /XML rejects a mismatch ("unable to switch the encoding").
    expect(content).toContain('encoding="UTF-16"');
    // The action runs the hidden VBScript launcher (plan/40), not node directly,
    // so the supervisor starts with no console window.
    expect(content).toContain("wscript.exe");
    expect(content).toContain("{VBS}");
    expect(content).toContain("<Hidden>true</Hidden>");
  });

  test("vbs-launcher (Windows) template file exists on disk (plan/40)", () => {
    const p = findTemplate("vbs-launcher");
    expect(p.endsWith("task-launcher.vbs.template")).toBe(true);
    const content = readFileSync(p, "utf8");
    // Hidden window (style 0), wait=True, propagate exit code, tee to {LOG}.
    expect(content).toContain(".Run(");
    expect(content).toContain("WScript.Quit");
    expect(content).toContain("cmd /c");
    expect(content).toContain("{NODE}");
    expect(content).toContain("{SUPERVISOR}");
    expect(content).toContain("{LOG}");
  });

  // Plan/173 — Android has no service manager; Termux:Boot runs a shell
  // script instead of a unit/plist/XML.
  test("termux-boot template file exists on disk (plan/173)", () => {
    const p = findTemplate("termux-boot");
    expect(p.endsWith("termux-boot.template")).toBe(true);
    const content = templateText(p);
    // Termux:Boot requires the absolute interpreter path.
    expect(content.startsWith("#!/data/data/com.termux/files/usr/bin/sh\n")).toBe(true);
    expect(content).toContain("termux-wake-lock");
    expect(content).toContain("{NODE}");
    expect(content).toContain("{SUPERVISOR}");
    expect(content).toContain("{REMOTE_PI}");
    expect(content).toContain("{PREFIX}");
    expect(content).toContain("guard run");
    expect(content).toContain("$PIPER/supervisord.log");
    // 2026-11-27: Termux:Boot starts without the termux-exec preload. Without
    // the export the supervisor's `spawn pi` fails with ENOENT after each boot.
    expect(content).toContain('if [ -z "$LD_PRELOAD" ] && [ -e "{PREFIX}/lib/libtermux-exec.so" ]; then');
    expect(content).toContain('export LD_PRELOAD="{PREFIX}/lib/libtermux-exec.so"');
  });
});

describe("renderTemplate", () => {
  const vars = {
    node: "/usr/local/bin/node",
    supervisor: "/Users/x/dist/bin/supervisord.js",
    home: "/Users/x",
    user: "jacob",
    path: "/usr/local/bin:/usr/bin:/bin",
    vbs: "/Users/x/.pi/remote/RemotePiSupervisorLauncher.vbs",
    logPath: "/Users/x/.pi/remote/supervisord.log",
    remotePi: "/Users/x/dist/index.js",
    prefix: "/data/data/com.termux/files/usr",
  };

  test("substitutes every placeholder in systemd template", () => {
    const tpl = readFileSync(findTemplate("systemd"), "utf8");
    const out = renderTemplate(tpl, vars);
    expect(out).not.toContain("{NODE}");
    expect(out).not.toContain("{SUPERVISOR}");
    expect(out).not.toContain("{HOME}");
    expect(out).not.toContain("{PATH}");
    expect(out).not.toContain("{USER}");
    expect(out).toContain(vars.node);
    expect(out).toContain(vars.supervisor);
    expect(out).toContain(vars.home);
    expect(out).toContain(vars.path);
  });

  test("substitutes every placeholder in launchd template", () => {
    const tpl = readFileSync(findTemplate("launchd"), "utf8");
    const out = renderTemplate(tpl, vars);
    expect(out).not.toContain("{NODE}");
    expect(out).not.toContain("{SUPERVISOR}");
    expect(out).not.toContain("{HOME}");
    expect(out).not.toContain("{PATH}");
    expect(out).toContain(`<string>${vars.node}</string>`);
    expect(out).toContain(`<string>${vars.supervisor}</string>`);
    expect(out).toContain(`<string>${vars.home}/.pi/remote/supervisord.log</string>`);
  });

  test("global replacement (multiple occurrences of same placeholder)", () => {
    // HOME appears in multiple keys of the launchd plist.
    const tpl = readFileSync(findTemplate("launchd"), "utf8");
    const out = renderTemplate(tpl, vars);
    // No unsubstituted {HOME} anywhere.
    expect(out.match(/\{HOME\}/g)).toBeNull();
    // And the value appears more than once (logs + EnvironmentVariables).
    const matches = out.match(new RegExp(vars.home.replace(/[/.]/g, "\\$&"), "g"));
    expect(matches && matches.length > 1).toBe(true);
  });

  test("substitutes {VBS} in the task-scheduler template, action calls wscript", () => {
    const tpl = readFileSync(findTemplate("taskscheduler"), "utf8");
    const out = renderTemplate(tpl, vars);
    expect(out).not.toContain("{VBS}");
    expect(out).toContain(vars.vbs);
    // {NODE}/{SUPERVISOR} no longer appear in the XML — they moved to the VBS.
    expect(out).not.toContain("{NODE}");
    expect(out).not.toContain("{SUPERVISOR}");
  });

  test("substitutes {NODE}/{SUPERVISOR}/{LOG} in the vbs-launcher template", () => {
    const tpl = readFileSync(findTemplate("vbs-launcher"), "utf8");
    const out = renderTemplate(tpl, vars);
    expect(out).not.toContain("{NODE}");
    expect(out).not.toContain("{SUPERVISOR}");
    expect(out).not.toContain("{LOG}");
    expect(out).toContain(vars.node);
    expect(out).toContain(vars.supervisor);
    expect(out).toContain(vars.logPath);
  });

  test("substitutes {REMOTE_PI} / {PREFIX} in the termux-boot template and nothing else", () => {
    const tpl = readFileSync(findTemplate("termux-boot"), "utf8");
    const out = renderTemplate(tpl, vars);
    expect(out).not.toMatch(/\{[A-Z_]+\}/);
    expect(out).toContain(`nohup "${vars.node}" "${vars.supervisor}"`);
    expect(out).toContain(`nohup "${vars.node}" "${vars.remotePi}" guard run`);
    expect(out).toContain(`export PATH="${vars.prefix}/bin:${vars.path}"`);
    expect(out).toContain(`export HOME="${vars.home}"`);
    expect(out).toContain(`[ -e "${vars.prefix}/lib/libtermux-exec.so" ]`);
    expect(out).toContain(`export LD_PRELOAD="${vars.prefix}/lib/libtermux-exec.so"`);
    // The desktop templates never contain these placeholders, so their output
    // is byte-for-byte what it was.
    for (const name of ["systemd", "launchd", "taskscheduler", "vbs-launcher"] as const) {
      const desktop = readFileSync(findTemplate(name), "utf8");
      expect(desktop).not.toContain("{REMOTE_PI}");
      expect(desktop).not.toContain("{PREFIX}");
    }
  });

  test("toLf turns CRLF into LF (Android's sh must not see CR)", () => {
    expect(toLf("a\r\nb\r\n")).toBe("a\nb\n");
    expect(toLf("a\nb\n")).toBe("a\nb\n");
  });
});

describe("vbsLauncherPath", () => {
  test("is absolute and ends with the launcher .vbs under ~/.pi/remote", () => {
    const p = vbsLauncherPath();
    expect(isAbsolute(p)).toBe(true);
    expect(p.endsWith("RemotePiSupervisorLauncher.vbs")).toBe(true);
    expect(p.endsWith(join(".pi", "piper", "RemotePiSupervisorLauncher.vbs"))).toBe(true);
  });
});

describe("buildCmdShim", () => {
  test("forwards all args to node with quoted node + target", () => {
    const shim = buildCmdShim("C:\\node\\node.exe", "C:\\ext\\dist\\index.js");
    expect(shim).toContain('@echo off');
    expect(shim).toContain('"C:\\node\\node.exe" "C:\\ext\\dist\\index.js" %*');
    expect(shim.endsWith("\r\n")).toBe(true);
  });
});

describe("buildElevatedCmd", () => {
  test("redirects schtasks lines to the log but leaves control-flow bare", () => {
    const out = buildElevatedCmd(
      [
        "schtasks /End /TN RemotePiSupervisor",
        "schtasks /Create /XML \"x.xml\" /TN RemotePiSupervisor /F",
        "if errorlevel 1 exit /b 1",
        "schtasks /Run /TN RemotePiSupervisor",
      ],
      "C:\\Temp\\out.log",
    );
    expect(out.startsWith("@echo off\r\n")).toBe(true);
    // schtasks lines get the redirect…
    expect(out).toContain('schtasks /End /TN RemotePiSupervisor >> "C:\\Temp\\out.log" 2>&1');
    expect(out).toContain('schtasks /Run /TN RemotePiSupervisor >> "C:\\Temp\\out.log" 2>&1');
    // …control flow does NOT (redirecting it would swallow the exit code).
    expect(out).toContain("if errorlevel 1 exit /b 1\r\n");
    expect(out).not.toContain('exit /b 1 >> ');
  });
});

// systemd/launchd paths are POSIX-only (Windows uses Task Scheduler — plan/40).
describe.skipIf(posixOnly)("paths", () => {
  test("systemdUnitPath lives under ~/.config/systemd/user/", () => {
    expect(systemdUnitPath()).toMatch(/\.config\/systemd\/user\/remote-pi-supervisord\.service$/);
  });

  test("launchdPlistPath lives under ~/Library/LaunchAgents/", () => {
    expect(launchdPlistPath()).toMatch(/Library\/LaunchAgents\/ch\.pungitore\.piper\.supervisord\.plist$/);
  });
});

describe("defaultRenderVars", () => {
  test("populates all required fields", () => {
    const vars = defaultRenderVars();
    expect(vars.node).toBe(process.execPath);
    expect(vars.supervisor.endsWith(join("bin", "supervisord.js"))).toBe(true);
    expect(isAbsolute(vars.home)).toBe(true);
    expect(vars.user.length).toBeGreaterThan(0);
    expect(vars.path.length).toBeGreaterThan(0);
    // Plan/173 — the Android placeholders resolve to the real CLI entry.
    expect(vars.remotePi).toBe(findRemotePiScript());
    expect(vars.prefix).toBe("/data/data/com.termux/files/usr");
  });
});

// ── CLI bin linking (plan/27) ────────────────────────────────────────────────

describe("findRemotePiScript", () => {
  test("resolves to dist/index.js sibling of supervisord", () => {
    const p = findRemotePiScript();
    expect(basename(p)).toBe("index.js");
    // Same dist root as supervisord: dirname(index.js) === dirname(dist/bin).
    expect(dirname(p)).toBe(dirname(dirname(findSupervisorScript())));
  });
});

// `~/.local/bin` + `:`-delimited PATH are POSIX-only (Windows skips CLI symlinks).
describe.skipIf(posixOnly)("userLocalBinDir + isOnPath", () => {
  test("userLocalBinDir composes ~/.local/bin from given homedir", () => {
    expect(userLocalBinDir("/tmp/fakehome")).toBe("/tmp/fakehome/.local/bin");
  });

  test("isOnPath matches dirs with and without trailing slash", () => {
    expect(isOnPath("/x/.local/bin", "/usr/bin:/x/.local/bin:/opt/bin")).toBe(true);
    expect(isOnPath("/x/.local/bin", "/usr/bin:/x/.local/bin/:/opt/bin")).toBe(true);
    expect(isOnPath("/x/.local/bin/", "/usr/bin:/x/.local/bin")).toBe(true);
    expect(isOnPath("/x/.local/bin", "/usr/bin:/opt/bin")).toBe(false);
    expect(isOnPath("/x/.local/bin", "")).toBe(false);
  });
});

// CLI symlinks are POSIX-only — linkCliBinaries returns early on Windows
// (npm-global provides the `.cmd` shims there), so these don't apply.
describe.skipIf(posixOnly)("linkCliBinaries / unlinkCliBinaries", () => {
  let tmpHome: string;
  let fakePaths: { remotePi: string; supervisord: string };

  beforeEach(() => {
    tmpHome = mkdtempSync(join(tmpdir(), "pi-link-"));
    // Stand-ins for the real extension files so the test doesn't depend
    // on `pnpm build` having run.
    const stub = join(tmpHome, "fake-ext");
    mkdirSync(join(stub, "bin"), { recursive: true });
    fakePaths = {
      remotePi: join(stub, "index.js"),
      supervisord: join(stub, "bin", "supervisord.js"),
    };
    writeFileSync(fakePaths.remotePi, "#!/usr/bin/env node\n");
    writeFileSync(fakePaths.supervisord, "#!/usr/bin/env node\n");
  });

  afterEach(() => {
    rmSync(tmpHome, { recursive: true, force: true });
  });

  test("link creates two symlinks pointing at the real extension files", () => {
    const result = linkCliBinaries(tmpHome, fakePaths);
    expect(result.binDir).toBe(join(tmpHome, ".local", "bin"));
    expect(result.links).toHaveLength(2);

    const names = result.links.map((l) => l.name).sort();
    expect(names).toEqual(["pi-supervisord", "remote-pi"]);

    for (const link of result.links) {
      expect(lstatSync(link.path).isSymbolicLink()).toBe(true);
      expect(readlinkSync(link.path)).toBe(link.target);
    }
  });

  test("link is idempotent (re-running yields same symlinks, no error)", () => {
    linkCliBinaries(tmpHome, fakePaths);
    const second = linkCliBinaries(tmpHome, fakePaths);
    for (const link of second.links) {
      expect(readlinkSync(link.path)).toBe(link.target);
    }
    // The "unchanged" branch should have fired the second time.
    expect(second.log.some((l) => l.includes("(unchanged)"))).toBe(true);
  });

  test("link replaces a stale symlink pointing elsewhere", () => {
    const binDir = join(tmpHome, ".local", "bin");
    mkdirSync(binDir, { recursive: true });
    // Write a fake stale symlink first
    const stale = join(binDir, "remote-pi");
    writeFileSync(join(tmpHome, "fake-old.js"), "// old\n");
    require("node:fs").symlinkSync(join(tmpHome, "fake-old.js"), stale);
    expect(readlinkSync(stale)).toBe(join(tmpHome, "fake-old.js"));

    const result = linkCliBinaries(tmpHome, fakePaths);
    const pi = result.links.find((l) => l.name === "remote-pi")!;
    expect(readlinkSync(pi.path)).toBe(pi.target);
    expect(readlinkSync(pi.path)).not.toBe(join(tmpHome, "fake-old.js"));
  });

  test("link signals onPath=false when binDir is absent from PATH (typical CI)", () => {
    const originalPath = process.env["PATH"];
    process.env["PATH"] = "/usr/bin:/bin";
    try {
      const result = linkCliBinaries(tmpHome, fakePaths);
      expect(result.onPath).toBe(false);
      expect(result.log.some((l) => l.includes("not on $PATH"))).toBe(true);
    } finally {
      process.env["PATH"] = originalPath;
    }
  });

  test("unlink removes both symlinks, idempotent on second call", () => {
    linkCliBinaries(tmpHome, fakePaths);
    const first = unlinkCliBinaries(tmpHome);
    expect(first.removed.map((r) => r.existed)).toEqual([true, true]);
    for (const r of first.removed) {
      expect(existsSync(r.path)).toBe(false);
    }
    // Second call is a no-op
    const second = unlinkCliBinaries(tmpHome);
    expect(second.removed.map((r) => r.existed)).toEqual([false, false]);
  });

  test("unlink does NOT delete the extension files (link targets are preserved)", () => {
    const linkResult = linkCliBinaries(tmpHome, fakePaths);
    unlinkCliBinaries(tmpHome);
    for (const link of linkResult.links) {
      // The target file (the actual dist/index.js etc) still exists.
      expect(existsSync(link.target)).toBe(true);
    }
  });
});

// Windows variant (plan/40): real `.cmd` shims, not symlinks. `mutatePath:false`
// keeps the test from touching the real user PATH; `node` is injected so the
// shim contents are deterministic.
describe.skipIf(!posixOnly)("linkCliBinaries / unlinkCliBinaries (Windows .cmd shims)", () => {
  let tmpHome: string;
  let fakePaths: { remotePi: string; supervisord: string };
  const node = "C:\\Program Files\\nodejs\\node.exe";

  beforeEach(() => {
    tmpHome = mkdtempSync(join(tmpdir(), "pi-link-win-"));
    const stub = join(tmpHome, "fake-ext");
    mkdirSync(join(stub, "bin"), { recursive: true });
    fakePaths = {
      remotePi: join(stub, "index.js"),
      supervisord: join(stub, "bin", "supervisord.js"),
    };
    writeFileSync(fakePaths.remotePi, "// stub\n");
    writeFileSync(fakePaths.supervisord, "// stub\n");
  });

  afterEach(() => {
    rmSync(tmpHome, { recursive: true, force: true });
  });

  test("link writes remote-pi.cmd + pi-supervisord.cmd pointing at node + targets", () => {
    const result = linkCliBinaries(tmpHome, fakePaths, { node, mutatePath: false });
    expect(result.binDir).toBe(join(tmpHome, ".local", "bin"));
    const names = result.links.map((l) => l.name).sort();
    expect(names).toEqual(["pi-supervisord.cmd", "remote-pi.cmd"]);
    for (const link of result.links) {
      expect(existsSync(link.path)).toBe(true);
      const content = readFileSync(link.path, "utf8");
      expect(content).toContain(`"${node}"`);
      expect(content).toContain(`"${link.target}"`);
      expect(content).toContain("%*");
    }
  });

  test("link is idempotent (re-running overwrites the same .cmd files)", () => {
    linkCliBinaries(tmpHome, fakePaths, { node, mutatePath: false });
    const second = linkCliBinaries(tmpHome, fakePaths, { node, mutatePath: false });
    for (const link of second.links) {
      expect(readFileSync(link.path, "utf8")).toBe(buildCmdShim(node, link.target));
    }
  });

  test("unlink removes both .cmd shims, idempotent on second call", () => {
    linkCliBinaries(tmpHome, fakePaths, { node, mutatePath: false });
    const first = unlinkCliBinaries(tmpHome);
    expect(first.removed.map((r) => r.existed)).toEqual([true, true]);
    for (const r of first.removed) expect(existsSync(r.path)).toBe(false);
    const second = unlinkCliBinaries(tmpHome);
    expect(second.removed.map((r) => r.existed)).toEqual([false, false]);
  });
});

// ── Android / Termux boot script (plan/173) ────────────────────────────────
//
// The platform is injected, so the branch runs on any host. Only file
// writes happen: Android has no activation command (Termux:Boot runs the
// script at boot, `remote-pi phone-setup` runs it once), and uninstall's
// signals go to an injected sender — never to a real process.
describe("installService / uninstallService (android)", () => {
  let tmpHome: string;
  let ext: string;
  let vars: ReturnType<typeof defaultRenderVars>;
  const script = (): string => join(tmpHome, ".termux", "boot", "start-piper.sh");
  /** Where install keeps the dated copy of a replaced script: outside the
   *  boot directory, because Termux:Boot runs every file of it (2026-11-27). */
  const backupDir = (home: string): string => termuxBootBackupDir(home);

  beforeEach(() => {
    tmpHome = mkdtempSync(join(tmpdir(), "pi-boot-"));
    ext = join(tmpHome, "ext");
    mkdirSync(join(ext, "bin"), { recursive: true });
    writeFileSync(join(ext, "index.js"), "#!/usr/bin/env node\n");
    writeFileSync(join(ext, "bin", "supervisord.js"), "// stub\n");
    vars = {
      ...defaultRenderVars(),
      home: tmpHome,
      supervisor: join(ext, "bin", "supervisord.js"),
      remotePi: join(ext, "index.js"),
      path: "/data/data/com.termux/files/usr/bin:/system/bin",
    };
  });

  afterEach(() => {
    rmSync(tmpHome, { recursive: true, force: true });
  });

  test("writes an executable LF boot script with absolute paths, idempotently", () => {
    const first = installService(vars, { platform: "android", home: tmpHome });
    expect(first.platform).toBe("android");
    expect(first.unitPath).toBe(script());
    expect(first.log.some((l) => l.includes("Termux:Boot"))).toBe(true);
    expect(first.log.some((l) => l.includes("phone-setup"))).toBe(true);
    // No activation command was attempted (nothing starting with `$ `).
    expect(first.log.some((l) => l.startsWith("$ "))).toBe(false);

    const raw = readFileSync(script(), "utf8");
    expect(raw.includes("\r")).toBe(false);
    expect(raw.startsWith("#!/data/data/com.termux/files/usr/bin/sh\n")).toBe(true);
    expect(raw).toContain(`nohup "${vars.node}" "${vars.supervisor}"`);
    expect(raw).toContain(`nohup "${vars.node}" "${vars.remotePi}" guard run`);
    expect(raw).toContain(`export PATH="/data/data/com.termux/files/usr/bin:${vars.path}"`);
    expect(raw).toContain("termux-wake-lock");
    // termux-exec for the shebang of `pi` (2026-11-27): guarded, never forced.
    expect(raw).toContain('[ -e "/data/data/com.termux/files/usr/lib/libtermux-exec.so" ]');
    expect(raw).not.toMatch(/\{[A-Z_]+\}/);
    if (process.platform !== "win32") {
      // Termux:Boot executes only scripts with the executable bit.
      expect(lstatSync(script()).mode & 0o111).not.toBe(0);
    }

    // Re-running install rewrites the same file and reports the same path.
    const second = installService(vars, { platform: "android", home: tmpHome });
    expect(second.unitPath).toBe(script());
    expect(readFileSync(script(), "utf8")).toBe(raw);
  });

  test("a missing CLI entry is refused before anything is written", () => {
    expect(() => installService(
      { ...vars, remotePi: join(ext, "missing.js") },
      { platform: "android", home: tmpHome },
    )).toThrow(/remote-pi script not found/);
    expect(existsSync(script())).toBe(false);
  });

  test("the unsupported-platform message names Android as supported", () => {
    expect(() => installService(vars, { platform: "unsupported" })).toThrow(/Android \(Termux\)/);
  });

  test("uninstall signals guard then supervisor and removes the script", () => {
    installService(vars, { platform: "android", home: tmpHome });
    const signalled: Array<[number, string]> = [];
    const result = uninstallService({
      platform: "android",
      home: tmpHome,
      findGuards: () => [4242],
      findSupervisors: () => [4243, 4244],
      signal: (pid, sig) => { signalled.push([pid, sig]); return true; },
    });
    expect(result.platform).toBe("android");
    expect(result.removed).toBe(true);
    expect(existsSync(script())).toBe(false);
    // The guard goes first so it cannot restart the supervisor stopped next.
    expect(signalled).toEqual([[4242, "SIGTERM"], [4243, "SIGTERM"], [4244, "SIGTERM"]]);
    expect(result.log.filter((l) => l.startsWith("guard: SIGTERM"))).toHaveLength(1);
    expect(result.log.filter((l) => l.startsWith("supervisor: SIGTERM"))).toHaveLength(2);
  });

  test("uninstall is idempotent: nothing to signal, script already gone", () => {
    const signalled: number[] = [];
    const result = uninstallService({
      platform: "android",
      home: tmpHome,
      findGuards: () => [],
      findSupervisors: () => [],
      signal: (pid) => { signalled.push(pid); return false; },
    });
    expect(result.removed).toBe(false);
    expect(signalled).toEqual([]);
    expect(result.log.some((l) => l.startsWith("guard: SIGTERM"))).toBe(false);
  });

  // Plan/173 review — the phone already had an interim boot script when this
  // release arrived. It is never silently clobbered: dated copy + diff.
  test("an existing boot script that differs is kept as a dated copy, with its diff in the log", () => {
    mkdirSync(dirname(script()), { recursive: true });
    const interim = [
      "#!/data/data/com.termux/files/usr/bin/sh",
      "# interim script written by hand on 2026-11-26",
      "termux-wake-lock",
      "nohup pi-supervisord >> ~/.pi/piper/boot.log 2>&1 &",
      "",
    ].join("\n");
    writeFileSync(script(), interim);

    const at = new Date(2026, 10, 26, 14, 30, 15).getTime();
    // Without `force` a script remote-pi did not write is left alone: no
    // write, no copy, a clear error (the docs promise "never clobbered").
    expect(() => installService(vars, { platform: "android", home: tmpHome, now: () => at })).toThrow(
      new RegExp(`${script().replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} was not written by remote-pi, so it is left alone`),
    );
    expect(readFileSync(script(), "utf8")).toBe(interim);
    expect(existsSync(backupDir(tmpHome))).toBe(false);

    const result = installService(vars, { platform: "android", home: tmpHome, now: () => at, force: true });

    // 2026-11-27: the copy is NOT made next to the script. Termux:Boot runs
    // every file of ~/.termux/boot at boot (and sets the executable bit
    // itself), so an old copy there would run at every boot.
    const backup = join(backupDir(tmpHome), "start-piper.sh.bak-20261126-143015");
    expect(result.backup).toBe(backup);
    expect(readFileSync(backup, "utf8")).toBe(interim);          // byte-for-byte copy
    expect(readFileSync(script(), "utf8")).toBe(previewTermuxBootScript(vars)); // and ours is in place
    expect(readdirSync(dirname(script())).sort()).toEqual(["start-piper.sh"]); // nothing else in the boot directory
    expect(existsSync(`${script()}.bak-20261126-143015`)).toBe(false);
    expect(result.log).toContain(`existing ${script()} differs: kept a copy at ${backup}`);
    expect(result.diff).toBeDefined();
    // Log order: the notice, the diff, then the "wrote" line.
    expect(result.log[0]).toBe(`existing ${script()} differs: kept a copy at ${backup}`);
    expect(result.log.slice(1, 1 + result.diff!.length)).toEqual(result.diff);
    expect(result.log[1 + result.diff!.length]).toBe(`wrote ${script()}`);

    // The diff reads like a diff: the shebang is shared, the interim's own
    // lines carry `-`, ours carry `+`, and no CR survives.
    expect(result.diff![0]).toBe("    … (1 unchanged line)");
    expect(result.diff).toContain("    - # interim script written by hand on 2026-11-26");
    expect(result.diff).toContain("    - nohup pi-supervisord >> ~/.pi/piper/boot.log 2>&1 &");
    expect(result.diff!.some((l) => l.startsWith("    + # start-piper.sh"))).toBe(true);
    expect(result.diff!.some((l) => l.includes("+ nohup ") && l.includes("guard run"))).toBe(true);
    expect(result.diff!.every((l) => !l.startsWith("    - # start-piper"))).toBe(true);
    expect(result.diff!.join("\n")).not.toContain("\r");
  });

  test("our own earlier script is refreshed with a copy too; an identical one leaves no copy", () => {
    installService(vars, { platform: "android", home: tmpHome, now: () => 1 });
    // Identical: nothing to back up, no diff.
    const same = installService(vars, { platform: "android", home: tmpHome, now: () => 2 });
    expect(same.backup).toBeUndefined();
    expect(same.diff).toBeUndefined();
    // An older generated version (one line removed) is still ours: replaced,
    // with a dated copy, and recognised as generated.
    const ours = readFileSync(script(), "utf8");
    const older = ours.split("\n").filter((l) => !l.includes("Guard:")) .join("\n");
    writeFileSync(script(), older);
    expect(isGeneratedBootScript(older)).toBe(true);
    const refreshed = installService(vars, { platform: "android", home: tmpHome, now: () => new Date(2026, 10, 26, 15, 0, 0).getTime() });
    expect(refreshed.backup).toBe(join(backupDir(tmpHome), "start-piper.sh.bak-20261126-150000"));
    expect(readFileSync(refreshed.backup!, "utf8")).toBe(older);
    expect(readFileSync(script(), "utf8")).toBe(ours);
    expect(isGeneratedBootScript(readFileSync(script(), "utf8"))).toBe(true);
    expect(isGeneratedBootScript("#!/bin/sh\necho hi\n")).toBe(false);
  });

  // Review finding (MEDIUM): install used `vars.home`, uninstall `homedir()`,
  // and neither looked at REMOTE_PI_HOME — install could write under one home
  // and uninstall delete from another. Both now use the daemon's resolution.
  test("install and uninstall resolve the boot script under ONE home, REMOTE_PI_HOME included", () => {
    const other = mkdtempSync(join(tmpdir(), "pi-boot-home-"));
    const previous = process.env["REMOTE_PI_HOME"];
    process.env["REMOTE_PI_HOME"] = other;
    try {
      // `vars.home` points somewhere else on purpose: the Android path must
      // not follow it.
      const result = installService({ ...vars, home: tmpHome }, { platform: "android" });
      expect(result.unitPath).toBe(join(other, ".termux", "boot", "start-piper.sh"));
      expect(result.unitPath).not.toBe(script());
      expect(readFileSync(result.unitPath, "utf8")).toContain(`export HOME="${other}"`);
      expect(existsSync(script())).toBe(false);

      const un = uninstallService({ platform: "android", findGuards: () => [], findSupervisors: () => [], signal: () => false });
      expect(un.unitPath).toBe(result.unitPath);
      expect(un.removed).toBe(true);
      expect(existsSync(result.unitPath)).toBe(false);
    } finally {
      if (previous === undefined) delete process.env["REMOTE_PI_HOME"];
      else process.env["REMOTE_PI_HOME"] = previous;
      rmSync(other, { recursive: true, force: true });
    }
  });
});

describe("lineDiff / renderLineDiff (plan/173)", () => {
  test("keeps the common lines, marks removed and added ones, trailing newlines do not count", () => {
    expect(lineDiff("a\nb\nc\n", "a\nB\nc\nd\n")).toEqual([
      { type: "same", text: "a" },
      { type: "minus", text: "b" },
      { type: "plus", text: "B" },
      { type: "same", text: "c" },
      { type: "plus", text: "d" },
    ]);
    expect(lineDiff("", "x")).toEqual([{ type: "plus", text: "x" }]);
    expect(lineDiff("x", "x")).toEqual([{ type: "same", text: "x" }]);
    expect(lineDiff("a\nb", "a\nb")).toEqual([
      { type: "same", text: "a" },
      { type: "same", text: "b" },
    ]);
  });

  test("rendering folds unchanged runs into one marker and prefixes - and +", () => {
    const out = renderLineDiff([
      { type: "same", text: "shebang" },
      { type: "same", text: "comment" },
      { type: "same", text: "other" },
      { type: "minus", text: "old" },
      { type: "plus", text: "new" },
      { type: "same", text: "tail" },
    ]);
    expect(out).toEqual(["    … (3 unchanged lines)", "    - old", "    + new", "    … (1 unchanged line)"]);
    expect(renderLineDiff([])).toEqual([]);
  });
});

// ── Line endings of rendered units (review of the 0.10.0 tarball) ──────────

/** The root of the git checkout the tests run in (a `.git` directory or, in
 *  a worktree, the `.git` link file), or null outside a checkout. */
function gitCheckoutRoot(): string | null {
  let dir = process.cwd();
  for (let i = 0; i < 10; i++) {
    if (existsSync(join(dir, ".git"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
  return null;
}

describe("normalizeUnitText", () => {
  test("every POSIX platform gets LF; Windows keeps its bytes", () => {
    for (const plat of ["linux", "macos", "android"] as const) {
      expect(normalizeUnitText("a\r\nb\r\n", plat), plat).toBe("a\nb\n");
    }
    expect(normalizeUnitText("a\r\nb\r\n", "windows")).toBe("a\r\nb\r\n");
    expect(normalizeUnitText("a\r\nb\r\n", "unsupported")).toBe("a\r\nb\r\n");
  });

  test("a CRLF checkout of the templates still renders LF systemd and launchd units", () => {
    // What core.autocrlf hands over on Windows, whatever this working tree has.
    const crlfTemplate = (name: "systemd" | "launchd" | "termux-boot"): string =>
      templateText(findTemplate(name)).replace(/\n/g, "\r\n");
    const vars = {
      ...defaultRenderVars(),
      node: "/usr/local/bin/node",
      supervisor: "/opt/remote-pi/dist/bin/supervisord.js",
    };
    const systemd = normalizeUnitText(renderTemplate(crlfTemplate("systemd"), vars), "linux");
    expect(systemd).not.toContain("\r");
    expect(systemd).toContain(`\nExecStart=${vars.node} ${vars.supervisor}\n`);
    const plist = normalizeUnitText(renderTemplate(crlfTemplate("launchd"), vars), "macos");
    expect(plist).not.toContain("\r");
    expect(plist).toContain(`<string>${vars.supervisor}</string>`);
    const boot = normalizeUnitText(renderTemplate(crlfTemplate("termux-boot"), vars), "android");
    expect(boot.startsWith("#!/data/data/com.termux/files/usr/bin/sh\n")).toBe(true);
    expect(boot).not.toContain("\r");
    // The Windows unit is written as UTF-16 by installService; its template
    // line endings are the template's own.
    expect(normalizeUnitText(renderTemplate(crlfTemplate("systemd"), vars), "windows")).toContain("\r\n");
  });

  test(".gitattributes pins the POSIX templates and every *.sh to LF", (ctx) => {
    // Tests run from the repository (vitest over src/). Inside an installed
    // package there is no checkout to pin, so the test has nothing to say.
    const root = gitCheckoutRoot();
    if (root === null) {
      ctx.skip();
      return;
    }
    const rules = readFileSync(join(root, ".gitattributes"), "utf8");
    for (const rule of [
      "*.sh text eol=lf",
      "pi-extension/service-templates/systemd.service.template text eol=lf",
      "pi-extension/service-templates/launchd.plist.template text eol=lf",
      "pi-extension/service-templates/termux-boot.template text eol=lf",
    ]) {
      expect(rules.split(/\r?\n/), rule).toContain(rule);
    }
  });
});

// ── The boot script under sh, with a simulated Termux prefix (2026-11-27) ───
//
// The LD_PRELOAD export is the line whose absence left the owner's phone
// without a device daemon after every Termux:Boot start: the supervisor came
// up, and every `spawn pi` ended in ENOENT. So the line is not only read in
// the template. The rendered script runs under `sh` with a stand-in for node
// that records the environment it inherited, wherever a POSIX `sh` is on
// PATH (the ubuntu and macos runners; the Windows runner has no `sh` for a
// POSIX PATH, so the block is skipped there).
describe.skipIf(process.platform === "win32")("the Termux boot script under sh", () => {
  let tmp: string;
  let home: string;
  let prefix: string;
  /** The installed package's `dist/`, inside the simulated prefix. */
  let supervisor: string;
  let remotePi: string;
  let node: string;
  let seen: string;
  const termuxExec = (): string => join(prefix, "lib", "libtermux-exec.so");

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "pi-boot-sh-"));
    home = join(tmp, "home");
    prefix = join(tmp, "usr");
    mkdirSync(join(home, ".termux", "boot"), { recursive: true });
    mkdirSync(join(prefix, "bin"), { recursive: true });
    mkdirSync(join(prefix, "lib"), { recursive: true });
    // install refuses paths that do not exist, as it would on the phone.
    const dist = join(prefix, "lib", "node_modules", "remote-pi", "dist");
    mkdirSync(join(dist, "bin"), { recursive: true });
    supervisor = join(dist, "bin", "supervisord.js");
    remotePi = join(dist, "index.js");
    writeFileSync(supervisor, "// stub\n");
    writeFileSync(remotePi, "#!/usr/bin/env node\n");
    // The stand-in for node records its first argument and what it inherited.
    node = join(prefix, "bin", "node");
    writeFileSync(
      node,
      '#!/bin/sh\nprintf "%s|%s|%s\\n" "$1" "${LD_PRELOAD:-}" "${LD_LIBRARY_PATH:-}" >> "$FAKE_NODE_OUT"\n',
      { mode: 0o755 },
    );
    seen = join(tmp, "seen.txt");
    writeFileSync(seen, "");
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  /** Installs the script for this prefix, runs it once as Termux:Boot would
   *  (`caller` is that process's extra environment) and returns the script. */
  function installAndRun(caller: NodeJS.ProcessEnv = {}): string {
    const script = join(home, ".termux", "boot", "start-piper.sh");
    installService(
      { ...defaultRenderVars(), node, supervisor, home, path: "/usr/bin:/bin", remotePi, prefix },
      { platform: "android", home },
    );
    const res = spawnSync("sh", [script], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      env: { HOME: home, PATH: "/usr/bin:/bin", FAKE_NODE_OUT: seen, ...caller },
    });
    expect(res.error).toBeUndefined();
    expect(res.status, res.stderr).toBe(0);
    return readFileSync(script, "utf8");
  }

  /** `<argument>|<LD_PRELOAD>|<LD_LIBRARY_PATH>` as the supervisor's and the
   *  guard's stand-ins wrote it, once both have (they run in the background,
   *  in no defined order). */
  async function inherited(): Promise<string[]> {
    const deadline = Date.now() + 10_000;
    for (;;) {
      const lines = readFileSync(seen, "utf8").split("\n").filter(Boolean);
      if (lines.length >= 2 || Date.now() > deadline) return lines;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }

  test("with termux-exec in the prefix, the supervisor and the guard inherit LD_PRELOAD from the script", async () => {
    writeFileSync(termuxExec(), "a stand-in for the shared library\n");
    // Termux:Boot: nothing is preloaded in the environment that runs the script.
    const script = installAndRun();
    expect(script).toContain(`[ -e "${prefix}/lib/libtermux-exec.so" ]`);
    const lines = await inherited();
    const preloaded = `${termuxExec()}|${join(prefix, "lib")}`;
    // Two background jobs: which stand-in writes first is not defined, so the
    // lines are told apart by the argument each was started with.
    const byArgument = new Map(lines.map((line) => [line.split("|")[0], line.split("|").slice(1).join("|")]));
    expect([...byArgument.keys()].sort()).toEqual([supervisor, remotePi].sort());
    expect(byArgument.get(supervisor)).toBe(preloaded);
    expect(byArgument.get(remotePi)).toBe(preloaded);
  }, 20_000);

  test("a value the caller already has is kept", async () => {
    writeFileSync(termuxExec(), "x\n");
    installAndRun({ LD_PRELOAD: "/data/data/com.termux/files/usr/lib/libtermux-exec-ld-preload.so" });
    for (const line of await inherited()) {
      expect(line.split("|")[1]).toBe("/data/data/com.termux/files/usr/lib/libtermux-exec-ld-preload.so");
    }
  }, 20_000);

  test("without termux-exec nothing is preloaded; the rest of the script is unchanged", async () => {
    installAndRun();
    const lines = await inherited();
    expect(lines).toHaveLength(2);
    for (const line of lines) {
      expect(line.split("|")[1]).toBe("");
      expect(line.split("|")[2]).toBe(join(prefix, "lib"));
    }
  }, 20_000);
});
