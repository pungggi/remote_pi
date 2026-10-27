import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll } from "vitest";

// One sandbox per test-file worker: no per-test timing overhead, and delayed
// reconnect work can never write into the developer's real ~/.pi tree after
// an individual test restores its own environment overrides.
const originalHome = process.env["REMOTE_PI_HOME"];
const testHome = mkdtempSync(join(tmpdir(), "remote-pi-test-file-home-"));
process.env["REMOTE_PI_HOME"] = testHome;

afterAll(() => {
  if (originalHome === undefined) delete process.env["REMOTE_PI_HOME"];
  else process.env["REMOTE_PI_HOME"] = originalHome;
  rmSync(testHome, { recursive: true, force: true });
});
