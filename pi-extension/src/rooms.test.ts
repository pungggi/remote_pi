import { mkdtempSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "vitest";
import { roomIdForCwd, roomIdFor } from "./rooms.js";
import { canSymlink } from "./test-helpers.js";
import { defaultAgentName } from "./session/local_config.js";

describe("roomIdForCwd", () => {
  test("deterministic for the same cwd", () => {
    const a = roomIdForCwd("/tmp/some/path/that/may/not/exist");
    const b = roomIdForCwd("/tmp/some/path/that/may/not/exist");
    expect(a).toBe(b);
  });

  test("different cwds produce different ids", () => {
    const a = roomIdForCwd("/tmp/path/a");
    const b = roomIdForCwd("/tmp/path/b");
    expect(a).not.toBe(b);
  });

  test("id is 12-char base64url (safe in URLs / log lines)", () => {
    const id = roomIdForCwd("/tmp/path/c");
    expect(id).toMatch(/^[A-Za-z0-9_-]{12}$/);
  });

  test.skipIf(!canSymlink)("realpath: symlinks resolve to the same id", () => {
    // Real fs setup: dir + symlink → dir. Both must produce identical ids.
    const tmp = mkdtempSync(join(tmpdir(), "remote-pi-rooms-"));
    const real = join(tmp, "real");
    mkdirSync(real);
    writeFileSync(join(real, "marker"), "x");
    const link = join(tmp, "link");
    symlinkSync(real, link);

    expect(roomIdForCwd(real)).toBe(roomIdForCwd(link));
  });

  test("non-existent cwd falls back to raw-path hash (no throw)", () => {
    const id = roomIdForCwd("/no/such/path/anywhere/xyz");
    expect(id).toMatch(/^[A-Za-z0-9_-]{12}$/);
  });
});

describe("roomIdFor (plan/41 — App↔Pi room per (cwd, name))", () => {
  const cwd = "/tmp/proj/backend";              // basename → default name "backend"
  const dflt = defaultAgentName(cwd);           // "backend"

  test("INVARIANT: default/absent name preserves the LEGACY cwd-only id (no re-keying)", () => {
    expect(roomIdFor(cwd)).toBe(roomIdForCwd(cwd));         // absent name
    expect(roomIdFor(cwd, dflt)).toBe(roomIdForCwd(cwd));   // name == defaultAgentName(cwd)
  });

  test("a custom agent_name produces a DISTINCT id (name-scoped)", () => {
    expect(roomIdFor(cwd, "reviewer")).not.toBe(roomIdForCwd(cwd));
    expect(roomIdFor(cwd, "reviewer")).toMatch(/^[A-Za-z0-9_-]{12}$/);
  });

  test("two different names in the SAME folder → distinct ids", () => {
    expect(roomIdFor(cwd, "alice")).not.toBe(roomIdFor(cwd, "bob"));
  });

  test("`folder` (default → legacy) vs `folder#2` (scoped) → distinct", () => {
    // The disambiguation for two UNNAMED agents: 1st keeps the legacy room,
    // 2nd gets a name-scoped room under the broker's #2 suffix.
    expect(roomIdFor(cwd, dflt)).toBe(roomIdForCwd(cwd));          // 1st = legacy
    expect(roomIdFor(cwd, `${dflt}#2`)).not.toBe(roomIdForCwd(cwd)); // 2nd = scoped
    expect(roomIdFor(cwd, dflt)).not.toBe(roomIdFor(cwd, `${dflt}#2`));
  });

  test.skipIf(!canSymlink)("realpath: a symlinked cwd yields the SAME name-scoped id as the real dir", () => {
    const tmp = mkdtempSync(join(tmpdir(), "remote-pi-rooms41-"));
    const real = join(tmp, "real");
    mkdirSync(real);
    writeFileSync(join(real, "marker"), "x");
    const link = join(tmp, "link");
    symlinkSync(real, link);
    // Custom name (≠ either basename) → both take the scoped branch, which
    // canonicalizes via realpath → identical id despite different basenames.
    expect(roomIdFor(real, "reviewer")).toBe(roomIdFor(link, "reviewer"));
  });

  test("scoped id is 12-char base64url", () => {
    expect(roomIdFor(cwd, "reviewer")).toMatch(/^[A-Za-z0-9_-]{12}$/);
  });
});
