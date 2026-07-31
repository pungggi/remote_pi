/**
 * Shared helpers for tests. Excluded from the `dist/` build via tsconfig
 * (`src/test-helpers.ts` in `exclude`), so it never ships — it exists purely
 * for test files to import.
 */
import { mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * Whether the current process can create symlinks. Windows needs Developer
 * Mode (or admin) for `fs.symlinkSync`; tests that create symlinks should
 * `test.skipIf(!canSymlink)` so they skip cleanly instead of EPERM-failing.
 * Probed once at import time.
 */
export const canSymlink: boolean = (() => {
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
