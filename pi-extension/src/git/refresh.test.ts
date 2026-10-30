import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import type { WireGitStatus } from "../protocol/types.js";
import type { RelayClient } from "../transport/relay_client.js";

const mocks = vi.hoisted(() => ({
  getGitStatusSnapshot: vi.fn(),
  ghPrViewRef: vi.fn(),
  upsertRoomMeta: vi.fn(),
}));

vi.mock("../actions/git_status.js", () => ({
  getGitStatusSnapshot: mocks.getGitStatusSnapshot,
}));
vi.mock("../session/ref_ingest.js", () => ({
  ghPrViewRef: mocks.ghPrViewRef,
  applyRefWithPrecedence: vi.fn((_current, incoming) => ({
    next: incoming,
    changed: true,
  })),
}));
vi.mock("../session/rooms_registry.js", () => ({
  upsertRoomMeta: mocks.upsertRoomMeta,
}));

import { ext } from "../extension-state.js";
import { startGitRefresh, stopGitRefresh } from "./refresh.js";

const repositoryInfo = {
  repoRoot: "/src/repo",
  remoteUrl: "git@github.com:owner/repo.git",
  commonDir: "/src/repo/.git",
};

function gitStatus(branch = "main"): WireGitStatus {
  return {
    branch,
    repository: "owner/repo",
    upstream: `origin/${branch}`,
    aheadBy: 0,
    behindBy: 0,
    upstreamGone: false,
    indexAdded: 0,
    indexModified: 0,
    indexDeleted: 0,
    indexUnmerged: 0,
    workingAdded: 0,
    workingModified: 0,
    workingDeleted: 0,
    workingUnmerged: 0,
    stashCount: 0,
  };
}

async function flushMicrotasks(): Promise<void> {
  for (let i = 0; i < 6; i++) await Promise.resolve();
}

describe("git refresh resource use", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    for (const mock of Object.values(mocks)) mock.mockReset();
    mocks.getGitStatusSnapshot.mockResolvedValue({
      status: gitStatus(),
      repositoryInfo,
    });
    mocks.ghPrViewRef.mockResolvedValue(null);
    ext.relay = { sendControl: vi.fn() } as unknown as RelayClient;
    ext.myRoomId = "room";
    ext.myRoomMeta = { name: "repo", cwd: "/src/repo" };
    ext.lastGitStatus = undefined;
  });

  afterEach(() => {
    stopGitRefresh();
    ext.relay = null;
    ext.myRoomId = null;
    ext.myRoomMeta = null;
    ext.lastGitStatus = undefined;
    vi.useRealTimers();
  });

  test("reuses repository identity and polls GH every five minutes", async () => {
    startGitRefresh();
    await flushMicrotasks();

    expect(mocks.getGitStatusSnapshot).toHaveBeenCalledTimes(1);
    expect(mocks.getGitStatusSnapshot).toHaveBeenLastCalledWith(
      "/src/repo",
      undefined,
    );
    expect(mocks.ghPrViewRef).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(60_000);
    expect(mocks.getGitStatusSnapshot).toHaveBeenCalledTimes(2);
    expect(mocks.getGitStatusSnapshot).toHaveBeenLastCalledWith(
      "/src/repo",
      repositoryInfo,
    );
    expect(mocks.ghPrViewRef).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(4 * 60_000);
    expect(mocks.getGitStatusSnapshot).toHaveBeenCalledTimes(6);
    expect(mocks.ghPrViewRef).toHaveBeenCalledTimes(2);
  });

  test("refreshes GH immediately when the branch changes", async () => {
    startGitRefresh();
    await flushMicrotasks();
    expect(mocks.ghPrViewRef).toHaveBeenCalledTimes(1);

    mocks.getGitStatusSnapshot.mockResolvedValue({
      status: gitStatus("feature/perf"),
      repositoryInfo,
    });
    await vi.advanceTimersByTimeAsync(60_000);

    expect(mocks.ghPrViewRef).toHaveBeenCalledTimes(2);
  });

  test("skips overlapping ticks while a refresh is still running", async () => {
    let resolveSnapshot!: (value: {
      status: WireGitStatus;
      repositoryInfo: typeof repositoryInfo;
    }) => void;
    mocks.getGitStatusSnapshot.mockReturnValue(new Promise((resolve) => {
      resolveSnapshot = resolve;
    }));

    startGitRefresh();
    await vi.advanceTimersByTimeAsync(2 * 60_000);
    expect(mocks.getGitStatusSnapshot).toHaveBeenCalledTimes(1);
    expect(mocks.ghPrViewRef).not.toHaveBeenCalled();

    resolveSnapshot({ status: gitStatus(), repositoryInfo });
    await flushMicrotasks();
    expect(mocks.ghPrViewRef).toHaveBeenCalledTimes(1);
  });
});
