/**
 * Plan/107 — on-demand git status for the session-info dialog.
 *
 * The app sends `git_status_request`; this handler runs
 * `git status --porcelain=2 --branch` in the session cwd (the same command
 * pi-posh-git uses for its footer) and replies with a `git_status_result`
 * carrying the parsed counts, or `status: null` when the cwd isn't a git
 * repo / git is unavailable.
 *
 * On-demand (not pushed): the dialog only needs a snapshot when opened, so we
 * avoid a relay `room_meta` change + continuous polling. The request/reply
 * ride the existing typed-action channel (id ↔ in_reply_to), forwarded by the
 * relay verbatim.
 *
 * The porcelain=2 parser is ported from pi-posh-git (MIT, same author) so the
 * dialog shows exactly what the footer shows.
 */
import { execFile } from "node:child_process";
import { basename } from "node:path";
import type { ClientMessage } from "../protocol/types.js";
import type { WireGitStatus } from "../protocol/types.js";
import type { ActionReplySender } from "./handlers.js";

type GitStatusRequestMsg = Extract<ClientMessage, { type: "git_status_request" }>;

/** Repository identity changes rarely, unlike working-tree status. The
 * periodic publisher caches it briefly to avoid three extra Git processes
 * on every refresh. */
export interface GitRepositoryInfo {
  repoRoot: string | null;
  remoteUrl: string | null;
  commonDir: string | null;
}

export interface GitStatusSnapshot {
  status: WireGitStatus | null;
  /** Null when status could not be read; callers must not cache this as a
   * negative repository result. */
  repositoryInfo: GitRepositoryInfo | null;
}

export type GitRunner = (cwd: string, args: string[]) => Promise<string | null>;

function runGit(cwd: string, args: string[]): Promise<string | null> {
  return new Promise((resolve) => {
    execFile(
      "git",
      ["--no-optional-locks", ...args],
      { cwd, timeout: 5000, maxBuffer: 1024 * 1024 },
      (err, stdout) => {
        // Non-zero exit (e.g. not a repo → status exits 128) → null.
        if (err) resolve(null);
        else resolve(stdout);
      },
    );
  });
}

export async function getGitStatus(cwd: string): Promise<WireGitStatus | null> {
  return (await getGitStatusSnapshot(cwd)).status;
}

/** Reads volatile status while optionally reusing stable repository identity.
 * The runner seam keeps the process-count behavior directly testable. */
export async function getGitStatusSnapshot(
  cwd: string,
  repositoryInfo?: GitRepositoryInfo,
  run: GitRunner = runGit,
): Promise<GitStatusSnapshot> {
  const [statusResult, resolvedRepositoryInfo] = await Promise.all([
    run(cwd, [
      "status", "--porcelain=2", "--branch", "--no-renames", "-unormal",
    ]),
    repositoryInfo
      ? Promise.resolve(repositoryInfo)
      : readGitRepositoryInfo(cwd, run),
  ]);
  if (!statusResult) return { status: null, repositoryInfo: null };

  const repository = repositoryLabel(
    resolvedRepositoryInfo.remoteUrl,
    mainRepositoryRoot(
      resolvedRepositoryInfo.repoRoot,
      resolvedRepositoryInfo.commonDir,
    ),
  );
  const lines = statusResult.split("\n");

  let branch = "";
  let upstream: string | null = null;
  let aheadBy = 0;
  let behindBy = 0;
  let upstreamGone = false;
  let indexAdded = 0;
  let indexModified = 0;
  let indexDeleted = 0;
  let indexUnmerged = 0;
  let workingAdded = 0;
  let workingModified = 0;
  let workingDeleted = 0;
  let workingUnmerged = 0;

  for (const line of lines) {
    if (line.startsWith("# branch.head ")) {
      branch = line.slice("# branch.head ".length);
      if (branch === "(detached)") {
        const sha = await run(cwd, ["rev-parse", "--short", "HEAD"]);
        branch = sha ? `(${sha.trim()})` : "(detached)";
      }
    } else if (line.startsWith("# branch.upstream ")) {
      upstream = line.slice("# branch.upstream ".length);
    } else if (line.startsWith("# branch.ab ")) {
      const parts = line.slice("# branch.ab ".length).split(" ");
      aheadBy = parseInt(parts[0]!, 10) || 0;
      behindBy = Math.abs(parseInt(parts[1]!, 10)) || 0;
    } else if (line.startsWith("1 ") || line.startsWith("2 ")) {
      const x = line.charAt(2);
      const y = line.charAt(3);
      if (x === "A") indexAdded++;
      else if (x === "M") indexModified++;
      else if (x === "D") indexDeleted++;
      else if (x === "R" || x === "C") indexModified++;
      else if (x === "U") indexUnmerged++;
      if (y === "A" || y === "?") workingAdded++;
      else if (y === "M") workingModified++;
      else if (y === "D") workingDeleted++;
      else if (y === "U") workingUnmerged++;
    } else if (line.startsWith("? ")) {
      workingAdded++;
    } else if (line.startsWith("u ")) {
      const x = line.charAt(2);
      const y = line.charAt(3);
      if (x === "A") indexAdded++;
      else if (x === "M") indexModified++;
      else if (x === "D") indexDeleted++;
      else if (x === "U") indexUnmerged++;
      if (y === "A") workingAdded++;
      else if (y === "M") workingModified++;
      else if (y === "D") workingDeleted++;
      else if (y === "U") workingUnmerged++;
    }
  }

  // Detect upstream gone: upstream recorded but the ref no longer resolves.
  if (upstream) {
    const rev = await run(cwd, ["rev-parse", "--verify", upstream]);
    if (!rev) upstreamGone = true;
  }

  // Stash count (only bother querying once we know it's a repo).
  let stashCount = 0;
  const stashResult = await run(cwd, ["stash", "list"]);
  if (stashResult?.trim()) stashCount = stashResult.trim().split("\n").length;

  return {
    status: {
      branch, repository, upstream, aheadBy, behindBy, upstreamGone,
      indexAdded, indexModified, indexDeleted, indexUnmerged,
      workingAdded, workingModified, workingDeleted, workingUnmerged,
      stashCount,
    },
    repositoryInfo: resolvedRepositoryInfo,
  };
}

async function readGitRepositoryInfo(
  cwd: string,
  run: GitRunner,
): Promise<GitRepositoryInfo> {
  const [repoRoot, remoteUrl, commonDir] = await Promise.all([
    run(cwd, ["rev-parse", "--show-toplevel"]),
    run(cwd, ["remote", "get-url", "origin"]),
    run(cwd, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
  ]);
  return { repoRoot, remoteUrl, commonDir };
}

/**
 * Stable display identity for repository grouping. Hosted remotes preserve
 * their owner/group path (`pungggi/pi-ps`); local-only repositories fall back
 * to the root folder name. Worktrees therefore join the same repository group.
 */
export function repositoryLabel(
  remoteUrl: string | null,
  repoRoot: string | null,
): string | null {
  const remote = remoteUrl?.trim().replaceAll("\\", "/") ?? "";
  if (remote) {
    const cleaned = remote.replace(/\/+$/, "").replace(/\.git$/i, "");
    const isUrl = /^[a-z][a-z\d+.-]*:\/\//i.test(cleaned);
    const isWindowsPath = /^[a-z]:\//i.test(cleaned);
    // SCP-style SSH: git@github.com:owner/repo
    const scp = isUrl || isWindowsPath
      ? null
      : cleaned.match(/^(?:[^@/]+@)?[^:/]+:(.+)$/);
    // URL-style remotes: https://host/owner/repo, ssh://host/group/repo
    const url = cleaned.match(
      /^[a-z][a-z\d+.-]*:\/\/(?:[^@/]+@)?[^/]+(\/.*)$/i,
    );
    const remotePath = url?.[1] ?? scp?.[1];
    if (remotePath) {
      const segments = remotePath.split("/").filter(Boolean);
      if (segments.length > 0) return segments.join("/");
    }
    // A local path used as a remote still identifies a repository, but has
    // no owner slug to preserve.
    if (!isUrl && !scp) return basename(cleaned) || null;
  }
  const root = repoRoot?.trim();
  return root ? basename(root) || null : null;
}

/**
 * The MAIN repository root, not the worktree root: `--show-toplevel` inside
 * a linked worktree returns the worktree folder, so a local-only repository
 * would otherwise group every worktree under its own folder name (a
 * worktree/branch identity, not the repository). `--git-common-dir` points
 * at `<main-root>/.git` from anywhere in the repository; its parent is the
 * main checkout. Falls back to the toplevel for old gits (no
 * `--path-format`), submodules (`…/.git/modules/<name>`), and bare repos.
 */
export function mainRepositoryRoot(
  repoRoot: string | null,
  commonDir: string | null,
): string | null {
  const common = commonDir?.trim().replaceAll("\\", "/") ?? "";
  if (common.endsWith("/.git")) return common.slice(0, -"/.git".length);
  return repoRoot?.trim() ?? null;
}

/**
 * Replies with a `git_status_result`. `status` is `null` when the cwd is null,
 * not a git repo, or git is unavailable — the app renders "not a git repo".
 * Never throws: a git failure is a null status, not a protocol error.
 */
export async function handleGitStatus(
  sender: ActionReplySender,
  msg: GitStatusRequestMsg,
  cwd: string | null,
): Promise<void> {
  const status = cwd ? await getGitStatus(cwd) : null;
  sender.send({ type: "git_status_result", in_reply_to: msg.id, status });
}
