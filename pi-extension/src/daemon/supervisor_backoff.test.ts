// Unit tests for the supervisor's crash-backoff semantics (PR #30 review).
//
// Finding 2 (augmentcode): the EXIT_DAEMON_FRESH_SESSION recycle path did
// not refresh `spawnedAt`, so a recycled daemon that immediately crash-loops
// kept inheriting the PREVIOUS incarnation's healthy uptime. The uptime
// reset in the crash path then zeroed the backoff on every exit → 1-second
// crash loop instead of escalating retries.
//
// Also covers the no-give-up policy (bug 2026-08-20): after exhausting the
// backoff schedule the supervisor keeps retrying at the max cadence.

import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { Supervisor } from "./supervisor.js";
import { EXIT_DAEMON_FRESH_SESSION } from "./rpc_child.js";

describe("Supervisor crash backoff (private _onChildExit)", () => {
  let sup: Supervisor;
  let spawns: number;
  let slot: {
    id: string;
    cwd: string;
    child: { noteRestart: () => void; spawn: () => void };
    restartTimer: ReturnType<typeof setTimeout> | null;
    restartAttempt: number;
    spawnedAt: number;
    transient: boolean;
  };

  beforeEach(() => {
    vi.useFakeTimers();
    sup = new Supervisor({
      sockPath: "unused.sock",
      extensionPath: "/no/such/extension.js",
      piBin: process.execPath,
    });
    spawns = 0;
    slot = {
      id: "device",
      cwd: "/tmp",
      child: {
        noteRestart: () => {},
        spawn: () => {
          spawns += 1;
        },
      },
      restartTimer: null,
      restartAttempt: 0,
      spawnedAt: Date.now(),
      transient: false,
    };
    (sup as unknown as { children: Map<string, typeof slot> }).children.set("device", slot);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  function exit(code: number): void {
    (sup as unknown as {
      _onChildExit: (id: string, evt: { isCrash: boolean; code: number }) => void;
    })._onChildExit("device", { isCrash: true, code });
  }

  test("FRESH_SESSION recycle refreshes spawnedAt: crash loops ESCALATE instead of staying at 1s", () => {
    // Healthy incarnation: spawned 11 minutes ago, some crash budget spent.
    slot.restartAttempt = 3;
    slot.spawnedAt = Date.now() - 11 * 60 * 1000;

    // 1) App-triggered recycle (/new) → immediate respawn, budget reset —
    //    intentional: a recycle must not inherit crash debt.
    exit(EXIT_DAEMON_FRESH_SESSION);
    expect(spawns).toBe(1);
    expect(slot.restartAttempt).toBe(0);
    expect(slot.spawnedAt).toBe(Date.now()); // refreshed (the fix)

    // 2) First post-recycle crash: attempt 0 → 1s backoff (legitimate).
    exit(1);
    vi.advanceTimersByTime(1_000);
    expect(spawns).toBe(2);

    // 3) THE REGRESSION: without the spawnedAt refresh, every crash saw the
    //    OLD incarnation's ≥10-min uptime and reset the budget → 1s loop
    //    forever. With the fix, attempt now escalates: 5s for the next.
    exit(1);
    vi.advanceTimersByTime(1_000);
    expect(spawns).toBe(2); // NOT respawned after another 1s
    vi.advanceTimersByTime(4_000);
    expect(spawns).toBe(3); // respawned at the 5s cadence
  });

  test("long-healthy child that crashes earns a backoff reset (fast restart)", () => {
    slot.restartAttempt = 4; // fully spent schedule
    slot.spawnedAt = Date.now() - 15 * 60 * 1000; // healthy 15 min

    exit(1);
    // Uptime reset applies → attempt back to 0 → delay 1s.
    vi.advanceTimersByTime(1_000);
    expect(spawns).toBe(1);
  });

  test("never gives up: keeps retrying at the max cadence after exhausting the schedule", () => {
    slot.restartAttempt = 0;
    slot.spawnedAt = Date.now(); // crash instantly — no uptime reset

    // Exhaust the whole schedule (4 backoffs) + beyond.
    for (let i = 0; i < 8; i++) {
      exit(1);
      vi.advanceTimersByTime(5 * 60 * 1000); // advance past ANY backoff
    }
    // Still respawning (8 crash exits → 8 spawns), no give-up branch taken.
    expect(spawns).toBeGreaterThanOrEqual(8);
    expect(slot.restartAttempt).toBeGreaterThanOrEqual(8);
  });
});
