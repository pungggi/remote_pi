import { afterEach, describe, expect, test } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { touchDaemonHeartbeat } from "./refresh.js";
import { readRoomsRegistry, roomsRegistryPath, upsertRoom } from "../session/rooms_registry.js";
import { ext } from "../extension-state.js";

/**
 * Plan/168 step 4 — the daemon-mode registry heartbeat. `lastSeenAt` must
 * move on the 60 s tick (freshness == "relay path alive"), not only on
 * (re)connect; the watchdog and the app's daemon-dark diagnosis read it.
 */

afterEach(() => {
  delete process.env["REMOTE_PI_HOME"];
  delete process.env["REMOTE_PI_DAEMON"];
  ext.myRoomId = undefined;
});

describe("touchDaemonHeartbeat (plan/168)", () => {
  test("daemon mode refreshes lastSeenAt for its room", () => {
    const home = mkdtempSync(join(tmpdir(), "pi-hb-"));
    process.env["REMOTE_PI_HOME"] = home;
    try {
      const old = 1; // ancient — proves the write moved it
      upsertRoom({ cwd: home, roomId: "device", lastSeenAt: old }, roomsRegistryPath());
      process.env["REMOTE_PI_DAEMON"] = "1";
      ext.myRoomId = "device";

      touchDaemonHeartbeat(home);

      const entry = readRoomsRegistry(roomsRegistryPath()).get("device");
      expect(entry).toBeDefined();
      expect(entry!.lastSeenAt).toBeGreaterThan(old);
    } finally {
      try { rmSync(home, { recursive: true, force: true }); } catch { /* best-effort */ }
    }
  });

  test("no-op outside daemon mode and without a room", () => {
    const home = mkdtempSync(join(tmpdir(), "pi-hb-"));
    process.env["REMOTE_PI_HOME"] = home;
    try {
      upsertRoom({ cwd: home, roomId: "device", lastSeenAt: 1 }, roomsRegistryPath());
      // Interactive session: no REMOTE_PI_DAEMON → registry untouched.
      ext.myRoomId = "device";
      touchDaemonHeartbeat(home);
      expect(readRoomsRegistry(roomsRegistryPath()).get("device")!.lastSeenAt).toBe(1);
      // Daemon mode but no room id yet → untouched.
      process.env["REMOTE_PI_DAEMON"] = "1";
      ext.myRoomId = undefined;
      touchDaemonHeartbeat(home);
      expect(readRoomsRegistry(roomsRegistryPath()).get("device")!.lastSeenAt).toBe(1);
    } finally {
      try { rmSync(home, { recursive: true, force: true }); } catch { /* best-effort */ }
    }
  });
});
