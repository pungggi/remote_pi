import { describe, expect, test } from "vitest";
import { mainRepositoryRoot, repositoryLabel } from "./git_status.js";

describe("repositoryLabel", () => {
  test("uses owner/repo from HTTPS remotes", () => {
    expect(
      repositoryLabel("https://github.com/pungggi/pi-reflex.git\n", null),
    ).toBe("pungggi/pi-reflex");
  });

  test("uses owner/repo from SCP-style SSH remotes", () => {
    expect(repositoryLabel("git@github.com:pungggi/pi-ps.git", null)).toBe(
      "pungggi/pi-ps",
    );
  });

  test("preserves nested groups from URL-style SSH remotes", () => {
    expect(
      repositoryLabel("ssh://git@gitlab.com/group/subgroup/project.git", null),
    ).toBe("group/subgroup/project");
  });

  test("normalizes trailing slashes and local Windows remotes", () => {
    expect(repositoryLabel("git@github.com:owner/repo.git/", null)).toBe(
      "owner/repo",
    );
    expect(repositoryLabel("C:\\src\\local-repo", null)).toBe("local-repo");
  });

  test("falls back to the repository root for local-only repositories", () => {
    expect(repositoryLabel(null, "/src/pi-context-engine\n")).toBe(
      "pi-context-engine",
    );
  });

  test("returns null when neither identity is available", () => {
    expect(repositoryLabel(null, null)).toBeNull();
    expect(repositoryLabel(" ", " ")).toBeNull();
  });
});

describe("mainRepositoryRoot", () => {
  test("resolves a worktree to the MAIN checkout root via the common dir", () => {
    // Linked worktree: toplevel is the worktree folder, common dir points
    // back at the primary checkout's .git.
    expect(
      mainRepositoryRoot(
        "C:\\src\\pi\\remote_pi_off",
        "C:/src/pi/remote_pi/.git",
      ),
    ).toBe("C:/src/pi/remote_pi");
    expect(
      mainRepositoryRoot("/w/remote_pi_vie", "/src/remote_pi/.git"),
    ).toBe("/src/remote_pi");
  });

  test("a plain checkout resolves to its own root", () => {
    expect(mainRepositoryRoot("/src/repo", "/src/repo/.git")).toBe("/src/repo");
  });

  test("old git / submodule / missing common dir falls back to the toplevel", () => {
    // git without --path-format support answers nothing for common dir.
    expect(mainRepositoryRoot("/w/remote_pi_off", null)).toBe("/w/remote_pi_off");
    // Submodule common dirs live under .git/modules/<name> — not a main root.
    expect(
      mainRepositoryRoot("/src/repo/sub", "/src/repo/.git/modules/sub"),
    ).toBe("/src/repo/sub");
    expect(mainRepositoryRoot(null, null)).toBeNull();
  });
});
