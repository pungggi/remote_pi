/**
 * Security fix 2026-08 (M3) — unit tests for the remote-action cwd policy.
 *
 * `projectsRoots` (config.js) and `listWorktrees` (worktree_registry.js) are
 * mocked so the policy is exercised as a pure containment function.
 */
import { beforeEach, describe, expect, test, vi } from "vitest";
import { sep } from "node:path";

let roots: string[] = [];
let worktrees: string[] = [];

vi.mock("../config.js", () => ({
  projectsRoots: () => roots,
}));
vi.mock("./worktree_registry.js", () => ({
  listWorktrees: () => worktrees.map((p) => ({ id: p, path: p })),
}));

import { remoteCwdAllowed } from "./cwd_policy.js";

const HOME = process.env["HOME"] ?? process.env["USERPROFILE"] ?? "/home/test";

describe("remoteCwdAllowed (security fix 2026-08)", () => {
  beforeEach(() => {
    roots = [];
    worktrees = [];
  });

  test("allows the project root itself", () => {
    roots = [`${HOME}${sep}source`];
    expect(remoteCwdAllowed(`${HOME}${sep}source`)).toBe(true);
  });

  test("allows any depth inside a root", () => {
    roots = [`${HOME}${sep}source`];
    expect(remoteCwdAllowed(`${HOME}${sep}source${sep}pi${sep}packages${sep}remote_pi`)).toBe(true);
  });

  test("rejects paths outside all roots", () => {
    roots = [`${HOME}${sep}source`];
    expect(remoteCwdAllowed(`${sep}tmp`)).toBe(false);
    expect(remoteCwdAllowed(`${HOME}${sep}other`)).toBe(false);
  });

  test("rejects prefix-lookalikes that are not under the root", () => {
    roots = [`${HOME}${sep}source${sep}pi`];
    expect(remoteCwdAllowed(`${HOME}${sep}source${sep}pi-backdoor`)).toBe(false);
  });

  test("rejects traversal encodings of an outside path", () => {
    roots = [`${HOME}${sep}source`];
    expect(remoteCwdAllowed(`${HOME}${sep}source${sep}..${sep}..${sep}etc`)).toBe(false);
  });

  test("allows registered worktrees even outside the roots", () => {
    roots = [`${HOME}${sep}source`];
    worktrees = [`${HOME}${sep}worktrees${sep}remote_pi_work`];
    expect(remoteCwdAllowed(`${HOME}${sep}worktrees${sep}remote_pi_work`)).toBe(true);
    // ...but not arbitrary siblings of a registered worktree.
    expect(remoteCwdAllowed(`${HOME}${sep}worktrees${sep}other`)).toBe(false);
  });

  test("rejects everything when no roots are configured", () => {
    roots = [];
    expect(remoteCwdAllowed(`${HOME}${sep}source`)).toBe(false);
  });
});
