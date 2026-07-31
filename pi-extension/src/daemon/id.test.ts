import { describe, expect, test } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { daemonIdForCwd } from "./id.js";

// Windows needs Developer Mode (or admin) to create symlinks — probe once so
// the realpath/symlink tests skip cleanly instead of EPERM-failing here.
const canSymlink = (() => {
  const dir = mkdtempSync(join(tmpdir(), "pi-sym-"));
  try {
    symlinkSync(dir, join(dir, "link"));
    return true;
  } catch {
    return false;
  } finally {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
})();

describe("daemonIdForCwd", () => {
  test("deterministic for the same cwd", () => {
    const a = daemonIdForCwd("/tmp/some/path/that/may/not/exist");
    const b = daemonIdForCwd("/tmp/some/path/that/may/not/exist");
    expect(a).toBe(b);
  });

  test("different cwds produce different ids", () => {
    const a = daemonIdForCwd("/tmp/path/a");
    const b = daemonIdForCwd("/tmp/path/b");
    expect(a).not.toBe(b);
  });

  test("id is 8-char hex (lowercase a-f + digits)", () => {
    const id = daemonIdForCwd("/tmp/path/c");
    expect(id).toMatch(/^[0-9a-f]{8}$/);
  });

  test.skipIf(!canSymlink)("realpath: symlinks collapse to the same id", () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-daemonid-"));
    const real = join(tmp, "real");
    mkdirSync(real);
    const link = join(tmp, "link");
    symlinkSync(real, link);
    expect(daemonIdForCwd(real)).toBe(daemonIdForCwd(link));
  });

  test("non-existent cwd falls back to raw-path hash (no throw)", () => {
    const id = daemonIdForCwd("/no/such/path/anywhere/xyz");
    expect(id).toMatch(/^[0-9a-f]{8}$/);
  });
});
