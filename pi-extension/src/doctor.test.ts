import { beforeEach, afterEach, describe, expect, test } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runDoctor, printDoctor, conflictingWorktreePackages } from "./doctor.js";
import { saveRegistry } from "./daemon/registry.js";
import { daemonIdForCwd } from "./daemon/id.js";

/**
 * Plan/159 doctor tests — all probes are injected, so nothing here touches
 * the network, the real supervisor, or the real ~/.pi. The registry lives
 * under a scratch REMOTE_PI_HOME.
 */

let testHome: string;
let projectCwd: string;

beforeEach(() => {
  testHome = mkdtempSync(join(tmpdir(), "pi-doc-"));
  process.env["REMOTE_PI_HOME"] = testHome;
  projectCwd = mkdtempSync(join(tmpdir(), "pi-doc-cwd-"));
});

afterEach(() => {
  delete process.env["REMOTE_PI_HOME"];
  try { rmSync(testHome, { recursive: true, force: true }); } catch { /* best-effort */ }
  try { rmSync(projectCwd, { recursive: true, force: true }); } catch { /* best-effort */ }
});

/** Fully-injected healthy deps (registry contents vary per test). */
function healthyDeps() {
  return {
    fetchText: async () => "OK",
    supervisorProbe: async () => true,
    supervisorStatus: async () => ({
      daemons: [{ id: daemonIdForCwd(projectCwd), cwd: projectCwd, name: "proj", state: "running" as const }],
    }),
    readSettingsPackages: () => ["npm:pi-schedule", "npm:pi-powershell"],
    versionCheck: () => ({ ok: true, detail: "node pi 1.0" }),
  };
}

describe("doctor — checks", () => {
  test("healthy stack: all ok, exit 0", async () => {
    saveRegistry({ daemons: [{ cwd: projectCwd, name: "proj" }] });
    const result = await runDoctor(healthyDeps());
    expect(result.healthy).toBe(true);
    expect(result.checks.every((c) => c.status === "ok")).toBe(true);
    const lines: string[] = [];
    expect(printDoctor(result, (l) => lines.push(l))).toBe(0);
    expect(lines.some((l) => l.includes("registry: 1 daemon"))).toBe(true);
  });

  test("empty registry is a warning, not a failure", async () => {
    const result = await runDoctor(healthyDeps());
    expect(result.healthy).toBe(true);
    const reg = result.checks.find((c) => c.name === "registry");
    expect(reg?.status).toBe("warn");
  });

  test("registry entry on the home cwd fails as the duplicate-spawn root cause", async () => {
    // The exact 2026-11-07 shape: home registered as a daemon.
    saveRegistry({ daemons: [{ cwd: testHome, name: "device" }] });
    const result = await runDoctor(healthyDeps());
    expect(result.healthy).toBe(false);
    const conflict = result.checks.find((c) => c.name === "home conflict");
    expect(conflict?.status).toBe("fail");
    expect(conflict?.detail).toContain("remote-pi remove");
    expect(printDoctor(result, () => {})).toBe(1);
  });

  test("unreachable relay fails with the phone impact spelled out", async () => {
    saveRegistry({ daemons: [{ cwd: projectCwd, name: "proj" }] });
    const deps = { ...healthyDeps(), fetchText: async () => null };
    const result = await runDoctor(deps);
    const relay = result.checks.find((c) => c.name === "relay");
    expect(relay?.status).toBe("fail");
    expect(relay?.detail).toContain("phone");
  });

  test("supervisor offline is a warning, fleet stays actionable", async () => {
    saveRegistry({ daemons: [{ cwd: projectCwd, name: "proj" }] });
    const deps = { ...healthyDeps(), supervisorProbe: async () => false, supervisorStatus: async () => null };
    const result = await runDoctor(deps);
    const sup = result.checks.find((c) => c.name === "supervisor");
    expect(sup?.status).toBe("warn");
    expect(result.healthy).toBe(true);
  });

  test("crash-looped fleet rows fail the run", async () => {
    saveRegistry({ daemons: [{ cwd: projectCwd, name: "proj" }] });
    const deps = {
      ...healthyDeps(),
      supervisorStatus: async () => ({
        daemons: [
          { id: daemonIdForCwd(projectCwd), cwd: projectCwd, name: "proj", state: "running" as const },
          { id: "device", cwd: testHome, name: "device", state: "crashed" as const, dead_since: "2026-11-07T00:00:00Z" },
        ],
      }),
    };
    const result = await runDoctor(deps);
    expect(result.healthy).toBe(false);
    const sup = result.checks.find((c) => c.name === "supervisor");
    expect(sup?.status).toBe("fail");
    expect(sup?.detail).toContain("crash-loop");
  });

  test("transient fleet rows are not missing-registry false positives", async () => {
    // Review f9, PR #103: doctor filtered transients by display NAME
    // (`name !== \"transient\"`), so a registry daemon NAMED \"transient\"
    // would false-positive as \"fleet rows without registry entries\".
    // The filter now keys on the explicit `transient` flag.
    saveRegistry({ daemons: [{ cwd: projectCwd, name: "transient" }] });
    const deps = {
      ...healthyDeps(),
      supervisorStatus: async () => ({
        daemons: [
          // Registry row legitimately named "transient" — must NOT be flagged.
          { id: daemonIdForCwd(projectCwd), cwd: projectCwd, name: "transient", state: "running" as const },
          // A real transient spawn with a custom name — under the old
          // name-based filter this flagged as "fleet rows without registry
          // entries"; the flag now filters it.
          { id: "deadbee0", cwd: "C:\\tmp\\other", name: "worker-2", state: "running" as const, transient: true },
        ],
      }),
    };
    const result = await runDoctor(deps);
    const sup = result.checks.find((c) => c.name === "supervisor");
    expect(sup?.status).toBe("ok");
    expect(sup?.detail ?? "").not.toContain("without registry entries");
  });

  test("path-based remote-pi worktree packages in settings warn", async () => {
    saveRegistry({ daemons: [{ cwd: projectCwd, name: "proj" }] });
    const deps = {
      ...healthyDeps(),
      readSettingsPackages: () => ["npm:pi-schedule", "../../source/pi/packages/remote_pi_off/pi-extension"],
    };
    const result = await runDoctor(deps);
    const settings = result.checks.find((c) => c.name === "pi settings");
    expect(settings?.status).toBe("warn");
    expect(settings?.detail).toContain("remote_pi_off");
    // A warning alone keeps the run healthy.
    expect(result.healthy).toBe(true);
  });

  test("pi binary spawn failure fails the run", async () => {
    saveRegistry({ daemons: [{ cwd: projectCwd, name: "proj" }] });
    const deps = { ...healthyDeps(), versionCheck: () => ({ ok: false, detail: "ENOENT" }) };
    const result = await runDoctor(deps);
    expect(result.healthy).toBe(false);
    const bin = result.checks.find((c) => c.name === "pi binary");
    expect(bin?.status).toBe("fail");
  });
});

describe("doctor — conflictingWorktreePackages", () => {
  test("flags path-based remote-pi entries, ignores npm packages and other paths", () => {
    const packages = [
      "npm:pi-schedule",
      "../../source/pi/packages/remote_pi_off/pi-extension",
      "C:\\x\\remote-pi\\pi-extension",
      "../../source/pi/packages/pi-something-else/pi-extension",
    ];
    expect(conflictingWorktreePackages(packages)).toEqual([
      "../../source/pi/packages/remote_pi_off/pi-extension",
      "C:\\x\\remote-pi\\pi-extension",
    ]);
  });
});
