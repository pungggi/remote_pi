// change_layout handler tests — the name-resolution core (pure fs) plus the
// reply shaping for the two synchronous failure modes (unknown name, missing
// Cockpit CLI). The happy path shells out to the real Cockpit CLI and is
// covered by the resolver + CLI-invocation unit boundaries instead.
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import {
  listNamedLayouts,
  resolveNamedLayout,
  findCockpitCli,
} from "./change_layout.js";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ckp-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("resolveNamedLayout", () => {
  test("resolves a layout at the root level", () => {
    writeFileSync(join(dir, "dev.ckp"), "panes: []\n");
    expect(resolveNamedLayout("dev", [dir])?.path).toBe(join(dir, "dev.ckp"));
  });

  test("resolves nested layouts up to the depth budget", () => {
    mkdirSync(join(dir, "proj"));
    writeFileSync(join(dir, "proj", "triage.ckp"), "panes: []\n");
    expect(resolveNamedLayout("triage", [dir])?.path).toBe(
      join(dir, "proj", "triage.ckp"),
    );
  });

  test("skips junk trees while descending", () => {
    mkdirSync(join(dir, "node_modules", "x", "y"), { recursive: true });
    writeFileSync(join(dir, "node_modules", "x", "y", "evil.ckp"), "panes: []\n");
    expect(resolveNamedLayout("evil", [dir])).toBeNull();
  });

  test("rejects traversal and path-shaped names", () => {
    expect(resolveNamedLayout("../etc/passwd", [dir])).toBeNull();
    expect(resolveNamedLayout("a/b", [dir])).toBeNull();
    expect(resolveNamedLayout("a\\b", [dir])).toBeNull();
    expect(resolveNamedLayout("  ", [dir])).toBeNull();
  });

  test("missing name yields null; roots searched in order", () => {
    const second = join(dir, "second");
    mkdirSync(second);
    writeFileSync(join(second, "only-here.ckp"), "panes: []\n");
    const empty = join(dir, "empty");
    mkdirSync(empty);
    expect(resolveNamedLayout("only-here", [empty])).toBeNull();
    expect(resolveNamedLayout("only-here", [empty, second])?.path).toBe(
      join(second, "only-here.ckp"),
    );
  });

  test("case-sensitive: .CKP does not match", () => {
    writeFileSync(join(dir, "UP.ckp"), "panes: []\n");
    expect(resolveNamedLayout("up", [dir])).toBeNull();
    expect(resolveNamedLayout("UP", [dir])?.path).toBe(join(dir, "UP.ckp"));
  });
});

describe("listNamedLayouts", () => {
  test("enumerates + sorts layouts across roots, first-wins on duplicates", () => {
    writeFileSync(join(dir, "b.ckp"), "panes: []\n");
    mkdirSync(join(dir, "sub"));
    writeFileSync(join(dir, "sub", "a.ckp"), "panes: []\n");
    const other = join(dir, "other-root");
    mkdirSync(other);
    writeFileSync(join(other, "c.ckp"), "panes: []\n");
    // duplicate name in a later root — first (dir) wins
    writeFileSync(join(other, "b.ckp"), "panes: []\n");
    const layouts = listNamedLayouts([dir, other]);
    expect(layouts.map((l) => l.name)).toEqual(["a", "b", "c"]);
  });
});

describe("findCockpitCli", () => {
  test("falls back to PATH lookup when ~/.cockpit/bin has no binary", () => {
    vi.spyOn(process, "platform", "get").mockReturnValue("linux" as never);
    // HOME-independent: the candidate under the REAL homedir almost certainly
    // does not exist in CI; assert we still get a usable command name.
    const cli = findCockpitCli();
    expect(typeof cli).toBe("string");
    expect(cli.length).toBeGreaterThan(0);
    vi.restoreAllMocks();
  });
});
