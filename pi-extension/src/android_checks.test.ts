/**
 * Plan/173 — the Android host checks that `remote-pi doctor` appends inside
 * Termux and `remote-pi phone-setup` prints as its report. Every probe is
 * injected, so this is a pure table test.
 */
import { describe, expect, test } from "vitest";
import { androidChecks, callingAndroidUserId, classifyPackageQuery, defaultAndroidCheckDeps, type AndroidCheckDeps } from "./android_checks.js";
import { runDoctor } from "./doctor.js";
import { MOVE_LEGACY_BOOT_BACKUPS } from "./termux.js";

const SCRIPT = "/data/data/com.termux/files/home/.termux/boot/start-piper.sh";

function healthy(overrides: Partial<AndroidCheckDeps> = {}): AndroidCheckDeps {
  return {
    bootScriptPath: SCRIPT,
    bootScriptExists: () => true,
    bootScriptExecutable: () => true,
    termuxBootApp: () => "installed",
    allowExternalApps: () => false,
    wakeLockAvailable: () => true,
    tmuxVersion: () => "tmux next-3.5",
    guardRunning: () => 4321,
    ...overrides,
  };
}

const names = (deps: AndroidCheckDeps): Array<[string, string]> =>
  androidChecks(deps).map((c) => [c.name, c.status]);

describe("classifyPackageQuery / callingAndroidUserId", () => {
  test("a listing that names the package answers 'installed', one without it 'missing'", () => {
    expect(classifyPackageQuery({ status: 0, stdout: "package:com.termux.boot\n", stderr: "" })).toBe("installed");
    expect(classifyPackageQuery({ status: 0, stdout: "package:other.app\n", stderr: "" })).toBe("missing");
  });

  test("a refused or failed query is 'unknown', never 'missing'", () => {
    expect(classifyPackageQuery({ status: 1, stdout: "", stderr: "Error: Could not access the Package Manager." })).toBe("unknown");
    expect(classifyPackageQuery({ status: null, stdout: "", stderr: "" })).toBe("unknown");
    expect(classifyPackageQuery({ status: 0, stdout: "package:x", stderr: "", error: new Error("timeout") })).toBe("unknown");
    // Nothing listed at all is not a trustworthy "no" either.
    expect(classifyPackageQuery({ status: 0, stdout: "\n", stderr: "" })).toBe("unknown");
  });

  test("the Android user id is the high part of the uid", () => {
    expect(callingAndroidUserId(10123)).toBe(0);
    expect(callingAndroidUserId(110123)).toBe(1);
    expect(callingAndroidUserId()).toBe(0);
  });
});

describe("androidChecks", () => {
  test("a fully set-up phone: six ok rows in print order", () => {
    const checks = androidChecks(healthy());
    expect(names(healthy())).toEqual([
      ["termux boot script", "ok"],
      ["termux:boot app", "ok"],
      ["termux wake lock", "ok"],
      ["allow-external-apps", "ok"],
      ["tmux", "ok"],
      ["guard", "ok"],
    ]);
    expect(checks[0]!.detail).toContain(SCRIPT);
    expect(checks[4]!.detail).toBe("tmux next-3.5");
    expect(checks[5]!.detail).toContain("pid 4321");
  });

  test("a missing boot script fails and names the fix", () => {
    const c = androidChecks(healthy({ bootScriptExists: () => false }))[0]!;
    expect(c.status).toBe("fail");
    expect(c.detail).toContain("remote-pi phone-setup");
  });

  test("a present script without the executable bit fails with chmod +x", () => {
    const c = androidChecks(healthy({ bootScriptExecutable: () => false }))[0]!;
    expect(c.status).toBe("fail");
    expect(c.detail).toContain(`chmod +x "${SCRIPT}"`);
  });

  // 2026-11-27, reboot test: Termux:Boot also ran the dated copies that older
  // installs left in the boot directory. They must be moved, and doctor says so.
  test("old copies in the boot directory turn the script row into a warning with the move command", () => {
    const boot = "/data/data/com.termux/files/home/.termux/boot";
    expect(androidChecks(healthy())[0]!.status).toBe("ok");

    const one = androidChecks(healthy({ legacyBootBackups: () => [`${boot}/start-piper.sh.bak-20261127-124819`] }))[0]!;
    expect(one.status).toBe("warn");
    expect(one.detail).toContain(
      "so do 1 old copy in its directory (start-piper.sh.bak-20261127-124819): Termux:Boot runs every file there");
    expect(one.detail).toContain(`Move them: ${MOVE_LEGACY_BOOT_BACKUPS}`);

    const two = androidChecks(
      healthy({ legacyBootBackups: () => [`${boot}/start-piper.sh.bak-20261127-124819`, `${boot}/start-piper.sh.bak-20261126-191759`] }),
    )[0]!;
    expect(two.status).toBe("warn");
    expect(two.detail).toContain(
      "so do 2 old copies in its directory (start-piper.sh.bak-20261127-124819, start-piper.sh.bak-20261126-191759)",
    );

    // A missing script keeps its own failure; the row does not bend.
    const gone = androidChecks(healthy({ bootScriptExists: () => false, legacyBootBackups: () => ["x"] }))[0]!;
    expect(gone.status).toBe("fail");
    expect(gone.detail).not.toContain("old cop");

    // The production wiring reads the real boot directory.
    expect(typeof defaultAndroidCheckDeps().legacyBootBackups).toBe("function");
  });

  test("Termux:Boot missing fails with the install instruction; unknown only warns", () => {
    const missing = androidChecks(healthy({ termuxBootApp: () => "missing" }))[1]!;
    expect(missing.status).toBe("fail");
    expect(missing.detail).toContain("F-Droid");
    expect(androidChecks(healthy({ termuxBootApp: () => "unknown" }))[1]!.status).toBe("warn");
  });

  test("no wake-lock helper and allow-external-apps=on are warnings with the why", () => {
    const noWake = androidChecks(healthy({ wakeLockAvailable: () => false }))[2]!;
    expect(noWake.status).toBe("warn");
    expect(noWake.detail).toContain("dozes");
    const open = androidChecks(healthy({ allowExternalApps: () => true }))[3]!;
    expect(open.status).toBe("warn");
    expect(open.detail).toContain("does not need it");
  });

  test("tmux absent or broken fails; the two cases get different fixes", () => {
    const absent = androidChecks(healthy({ tmuxVersion: () => null }))[4]!;
    expect(absent.status).toBe("fail");
    expect(absent.detail).toContain("pkg install tmux");
    const broken = androidChecks(healthy({ tmuxVersion: () => "" }))[4]!;
    expect(broken.status).toBe("fail");
    expect(broken.detail).toContain("pkg reinstall tmux");
  });

  test("a stopped guard warns: nothing would restart the supervisor", () => {
    const c = androidChecks(healthy({ guardRunning: () => null }))[5]!;
    expect(c.status).toBe("warn");
    expect(c.detail).toContain("remote-pi guard start");
  });
});

describe("runDoctor — Android checks", () => {
  /** The PC probes, fully healthy (same shape as doctor.test.ts). */
  const pcDeps = {
    fetchText: async () => "OK",
    supervisorProbe: async () => true,
    supervisorStatus: async () => ({ daemons: [] as never[] }),
    readSettingsPackages: () => ["npm:pi-schedule"],
    versionCheck: () => ({ ok: true, detail: "node pi 1.0" }),
  };

  test("injected Android checks come first and a failure there fails the run", async () => {
    const result = await runDoctor({ ...pcDeps, android: healthy({ bootScriptExists: () => false }) });
    expect(result.checks[0]!.name).toBe("termux boot script");
    expect(result.checks[0]!.status).toBe("fail");
    expect(result.healthy).toBe(false);
    expect(result.checks).toHaveLength(12);
  });

  test("without Android deps a non-Termux host keeps exactly its six checks", async () => {
    const result = await runDoctor({ ...pcDeps });
    expect(result.checks.map((c) => c.name)).toEqual([
      "registry", "home conflict", "supervisor", "relay", "pi binary", "pi settings",
    ]);
    expect(await runDoctor({ ...pcDeps, android: null })).toMatchObject({ healthy: true });
  });
});
