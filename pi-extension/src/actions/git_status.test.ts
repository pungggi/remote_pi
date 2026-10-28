import { describe, expect, test } from "vitest";
import { repositoryLabel } from "./git_status.js";

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
