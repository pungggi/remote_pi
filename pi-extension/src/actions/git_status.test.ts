import { describe, expect, test } from "vitest";
import {
  getGitStatusSnapshot,
  mainRepositoryRoot,
  repositoryLabel,
} from "./git_status.js";
import type { GitRunner } from "./git_status.js";

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

describe("getGitStatusSnapshot", () => {
  const statusOutput = [
    "# branch.head main",
    "# branch.upstream origin/main",
    "# branch.ab +0 -0",
    "",
  ].join("\n");

  test("reads repository identity when no cache is available", async () => {
    const run: GitRunner = async (_cwd, args) => {
      if (args[0] === "status") return statusOutput;
      if (args[0] === "remote") return "git@github.com:owner/repo.git\n";
      if (args[0] === "stash") return "";
      if (args[0] === "rev-parse" && args[1] === "--show-toplevel") {
        return "/src/repo\n";
      }
      if (args[0] === "rev-parse" && args.includes("--git-common-dir")) {
        return "/src/repo/.git\n";
      }
      if (args[0] === "rev-parse" && args[1] === "--verify") return "abc\n";
      throw new Error(`unexpected git command: ${args.join(" ")}`);
    };

    const snapshot = await getGitStatusSnapshot("/src/repo", undefined, run);

    expect(snapshot.status?.repository).toBe("owner/repo");
    expect(snapshot.repositoryInfo).toEqual({
      repoRoot: "/src/repo\n",
      remoteUrl: "git@github.com:owner/repo.git\n",
      commonDir: "/src/repo/.git\n",
    });
  });

  test("cached repository identity avoids three Git subprocesses", async () => {
    const calls: string[][] = [];
    const run: GitRunner = async (_cwd, args) => {
      calls.push(args);
      if (args[0] === "status") return statusOutput;
      if (args[0] === "stash") return "";
      if (args[0] === "rev-parse" && args[1] === "--verify") return "abc\n";
      throw new Error(`unexpected git command: ${args.join(" ")}`);
    };
    const repositoryInfo = {
      repoRoot: "/src/repo",
      remoteUrl: "git@github.com:owner/repo.git",
      commonDir: "/src/repo/.git",
    };

    const snapshot = await getGitStatusSnapshot(
      "/src/repo",
      repositoryInfo,
      run,
    );

    expect(calls).toEqual([
      ["status", "--porcelain=2", "--branch", "--no-renames", "-unormal"],
      ["rev-parse", "--verify", "origin/main"],
      ["stash", "list"],
    ]);
    expect(snapshot.repositoryInfo).toBe(repositoryInfo);
    expect(snapshot.status?.repository).toBe("owner/repo");
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
