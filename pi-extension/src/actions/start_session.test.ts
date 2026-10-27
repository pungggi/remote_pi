/**
 * Plan/124 + plan/152 — Start session always opens a visible terminal.
 * Exact IDs use `pi --session`; legacy rooms use `pi --continue`.
 */
import { beforeEach, describe, expect, test, vi } from "vitest";

vi.mock("./cwd_policy.js", () => ({
  remoteCwdAllowed: vi.fn(() => true),
}));

vi.mock("../rooms.js", () => ({
  roomIdFor: vi.fn(() => "room-1"),
}));

vi.mock("../session/rooms_registry.js", () => ({
  readRoomsRegistry: vi.fn(() => new Map()),
}));

vi.mock("./open_terminal.js", async (importOriginal) => ({
  ...await importOriginal<typeof import("./open_terminal.js")>(),
  openTerminalTab: vi.fn(),
}));

import { handleStartSession } from "./start_session.js";
import { roomIdFor } from "../rooms.js";
import { readRoomsRegistry } from "../session/rooms_registry.js";
import { openTerminalTab } from "./open_terminal.js";
import type { ClientMessage, ServerMessage } from "../protocol/types.js";

type StartMsg = Extract<ClientMessage, { type: "start_session_request" }>;

function fakeSender() {
  const sent: ServerMessage[] = [];
  return { send: (m: ServerMessage) => sent.push(m), sent };
}

function flush() {
  return new Promise((r) => setImmediate(r));
}

describe("handleStartSession visible terminal resume", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(readRoomsRegistry).mockReturnValue(new Map());
    vi.mocked(openTerminalTab).mockReset();
  });

  test("exact ID opens a new visible terminal with pi --session", async () => {
    const sessionId = "123e4567-e89b-42d3-a456-426614174000";
    vi.mocked(readRoomsRegistry).mockReturnValue(new Map([
      ["room-1", { cwd: "/x", roomId: "room-1", lastSeenAt: 1, sessionId }],
    ]));
    vi.mocked(openTerminalTab).mockResolvedValue({ ok: true, message: "opened", method: "wt" });
    const s = fakeSender();

    handleStartSession(s as any, {
      type: "start_session_request", id: "exact-1", cwd: "/x", name: "worker",
    } as StartMsg);
    await flush();

    expect(roomIdFor).toHaveBeenCalledWith("/x", "worker");
    expect(openTerminalTab).toHaveBeenCalledWith(
      "/x",
      `pi --session '${sessionId}'`,
      { newWindow: true },
    );
    expect(s.sent).toEqual([{
      type: "start_session_result",
      in_reply_to: "exact-1",
      ok: true,
      room_id: "room-1",
      message: "Opened terminal — resuming the saved Pi session.",
    }]);
  });

  test("exact terminal failure does not fall back to a different session", async () => {
    vi.mocked(readRoomsRegistry).mockReturnValue(new Map([
      ["room-1", { cwd: "/x", roomId: "room-1", lastSeenAt: 1, sessionId: "saved-id" }],
    ]));
    vi.mocked(openTerminalTab).mockResolvedValue({ ok: false, message: "wt failed", method: "wt" });
    const s = fakeSender();

    handleStartSession(s as any, {
      type: "start_session_request", id: "exact-2", cwd: "/x",
    } as StartMsg);
    await flush();

    expect(openTerminalTab).toHaveBeenCalledTimes(1);
    expect(s.sent[0]).toMatchObject({ ok: false, room_id: "room-1", message: "wt failed" });
  });

  test("no ID opens a new visible terminal with pi --continue", async () => {
    vi.mocked(openTerminalTab).mockResolvedValue({ ok: true, message: "opened", method: "wt" });
    const s = fakeSender();

    handleStartSession(s as any, {
      type: "start_session_request", id: "legacy-1", cwd: "/x",
    } as StartMsg);
    await flush();

    expect(openTerminalTab).toHaveBeenCalledWith("/x", "pi --continue", { newWindow: true });
    expect(s.sent).toEqual([{
      type: "start_session_result",
      in_reply_to: "legacy-1",
      ok: true,
      room_id: "room-1",
      message: "Opened terminal — continuing the latest Pi session in this folder.",
    }]);
  });

  test("legacy custom name scopes the registry room and blank name uses the default", async () => {
    vi.mocked(openTerminalTab).mockResolvedValue({ ok: true, message: "opened", method: "wt" });

    handleStartSession(fakeSender() as any, {
      type: "start_session_request", id: "named", cwd: "/x", name: "worker",
    } as StartMsg);
    handleStartSession(fakeSender() as any, {
      type: "start_session_request", id: "blank", cwd: "/x", name: "   ",
    } as StartMsg);
    await flush();

    expect(roomIdFor).toHaveBeenNthCalledWith(1, "/x", "worker");
    expect(roomIdFor).toHaveBeenNthCalledWith(2, "/x", undefined);
    expect(openTerminalTab).toHaveBeenCalledTimes(2);
  });

  test("legacy terminal failure is returned to the app", async () => {
    vi.mocked(openTerminalTab).mockResolvedValue({ ok: false, message: "wt failed", method: "wt" });
    const s = fakeSender();

    handleStartSession(s as any, {
      type: "start_session_request", id: "legacy-error", cwd: "/x",
    } as StartMsg);
    await flush();

    expect(s.sent[0]).toMatchObject({ ok: false, room_id: "room-1", message: "wt failed" });
  });

  test("missing cwd replies synchronously without opening a terminal", () => {
    const s = fakeSender();
    handleStartSession(s as any, {
      type: "start_session_request", id: "missing", cwd: "",
    } as StartMsg);

    expect(s.sent).toEqual([{
      type: "start_session_result", in_reply_to: "missing", ok: false, message: "cwd is required",
    }]);
    expect(openTerminalTab).not.toHaveBeenCalled();
  });
});
