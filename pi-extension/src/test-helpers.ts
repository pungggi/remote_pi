/**
 * Shared helpers for tests. Excluded from the `dist/` build via tsconfig
 * (`src/test-helpers.ts` in `exclude`), so it never ships — it exists purely
 * for test files to import.
 */
import { chmodSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
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

/**
 * Plan/173 — a stand-in for `pi --mode rpc` that behaves like a daemon which
 * is already connected to the relay: it answers `get_state` and, on the first
 * `prompt`, records the prompt text in the file named by `STUB_LOG` (set it
 * in the environment before spawning) and posts one `remote-pi:pair-code`
 * custom message — the same two stdout lines the real extension produces for
 * `/remote-pi pair`.
 *
 * Returns the value to pass as `piBin`: a shebang script on POSIX, an npm
 * style `.cmd` shim on Windows (which `resolvePiSpawn` unwraps to
 * `node <stub>`), so the same test runs on both.
 */
export function writePairStub(dir: string): string {
  const script = join(dir, "pair-stub.mjs");
  writeFileSync(
    script,
    [
      "#!/usr/bin/env node",
      "import { appendFileSync } from 'node:fs';",
      "process.stdin.setEncoding('utf8');",
      "let b = ''; let paired = false;",
      "process.stdin.on('data', (c) => {",
      "  b += c; let n;",
      "  while ((n = b.indexOf('\\n')) >= 0) {",
      "    const l = b.slice(0, n); b = b.slice(n + 1);",
      "    let m; try { m = JSON.parse(l); } catch { continue; }",
      "    if (m.type === 'get_state') {",
      "      process.stdout.write(JSON.stringify({ type: 'response', command: 'get_state', id: m.id, success: true, data: { isStreaming: false } }) + '\\n');",
      "    }",
      "    if (m.type === 'prompt' && !paired) {",
      "      paired = true;",
      "      appendFileSync(process.env.STUB_LOG, m.message + '\\n');",
      "      process.stdout.write(JSON.stringify({ id: m.id, type: 'response', command: 'prompt', success: true }) + '\\n');",
      "      process.stdout.write(JSON.stringify({ type: 'message_end', message: { role: 'custom', customType: 'remote-pi:pair-code', content: 'QR', display: true, timestamp: 1, details: { uri: 'remotepi://pair?t=abc&epk=k&n=device&rm=device', token: 'abc', expiresAt: 1900000000000, roomId: 'device', name: 'device' } } }) + '\\n');",
      "    }",
      "  }",
      "});",
      "setInterval(() => {}, 1e9);",
      "",
    ].join("\n"),
  );
  if (process.platform === "win32") {
    // Same shape as an npm global shim, so resolvePiSpawn recovers the script.
    const shim = join(dir, "pair-stub.cmd");
    writeFileSync(shim, '@echo off\r\n"%_prog%"  "%dp0%\\pair-stub.mjs" %*\r\n');
    return shim;
  }
  chmodSync(script, 0o755);
  return script;
}
