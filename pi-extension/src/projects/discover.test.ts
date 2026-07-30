import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, afterEach, beforeEach, test, expect } from "vitest";
import { discoverProjects } from "./discover.js";

/** `gitDir` true → create `.git` as a directory (main repo);
 *  false → create `.git` as a file (worktree/submodule pointer). */
function makeRepo(dir: string, gitDir = true): void {
  mkdirSync(dir, { recursive: true });
  const dot = join(dir, ".git");
  if (gitDir) mkdirSync(dot);
  else writeFileSync(dot, "gitdir: ../main/.git/worktrees/x\n");
}

let root: string;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "rpi-disc-"));
});
afterEach(() => {
  try { rmSync(root, { recursive: true, force: true }); } catch { /* ignored */ }
});

describe("discoverProjects", () => {
  test("lists main repos (.git dir) under a root", () => {
    makeRepo(join(root, "ngTradr"));
    makeRepo(join(root, "remote_pi"));
    mkdirSync(join(root, "not-a-repo"), { recursive: true });
    const found = discoverProjects([root]).map((p) => p.name).sort();
    expect(found).toEqual(["ngTradr", "remote_pi"]);
  });

  test("skips git worktrees (.git file) — only main repos show", () => {
    makeRepo(join(root, "ngTradr"));            // main → listed
    makeRepo(join(root, "ngTradr_www"), false); // worktree → skipped
    const found = discoverProjects([root]).map((p) => p.name);
    expect(found).toEqual(["ngTradr"]);
  });

  test("finds nested main repos up to maxDepth", () => {
    makeRepo(join(root, "ngTradr"));                       // depth 0
    makeRepo(join(root, "pi", "packages", "remote_pi"));   // depth 2
    makeRepo(join(root, "a", "b", "c", "deep"));           // depth 3
    // maxDepth 2 → finds depth 0 + 2, excludes the depth-3 'deep'
    const shallow = discoverProjects([root], { maxDepth: 2 }).map((p) => p.name).sort();
    expect(shallow).toEqual(["ngTradr", "remote_pi"]);
    // maxDepth 3 → also finds 'deep'
    const deeper = discoverProjects([root], { maxDepth: 3 }).map((p) => p.name).sort();
    expect(deeper).toEqual(["deep", "ngTradr", "remote_pi"]);
  });

  test("respects maxEntries cap", () => {
    for (let i = 0; i < 5; i++) makeRepo(join(root, `r${i}`));
    const found = discoverProjects([root], { maxEntries: 3 });
    expect(found.length).toBe(3);
  });

  test("skips junk trees (node_modules, hidden, build output)", () => {
    makeRepo(join(root, "node_modules", "pkg"));   // skipped (descent filter)
    makeRepo(join(root, ".cache", "x"));           // skipped (hidden)
    makeRepo(join(root, "build", "out"));          // skipped (build)
    makeRepo(join(root, "real"));                  // found
    const names = discoverProjects([root]).map((p) => p.name);
    expect(names).toEqual(["real"]);
  });

  test.skipIf(process.platform === "win32")("dedupes symlinked clones to one entry (realpath)", () => {
    // POSIX-only assertion: Node's realpathSync resolves dir symlinks, so a
    // symlink to a repo collapses with its target. On Windows, dev-mode
    // symlinks resolve to distinct realpaths, so dedupe doesn't apply —
    // the entry simply appears twice (harmless; curation is plan/122).
    makeRepo(join(root, "ngTradr"));
    symlinkSync(join(root, "ngTradr"), join(root, "ngTradr_link"), "dir");
    const found = discoverProjects([root]);
    expect(found.length).toBe(1);
    expect(found[0]!.name).toBe("ngTradr");
  });

  test("sorts by name then path", () => {
    makeRepo(join(root, "banana"));
    makeRepo(join(root, "apple"));
    const found = discoverProjects([root]).map((p) => p.name);
    expect(found).toEqual(["apple", "banana"]);
  });

  test("never throws on a missing / unreadable root — skips silently", () => {
    makeRepo(join(root, "ngTradr"));
    const found = discoverProjects([root, "/definitely/not/here/xyz", join(root, "nope")]);
    expect(found.map((p) => p.name)).toEqual(["ngTradr"]);
  });

  test("tilde/empty roots are tolerated", () => {
    makeRepo(join(root, "ngTradr"));
    expect(() => discoverProjects([root, "", "   "])).not.toThrow();
  });
});
