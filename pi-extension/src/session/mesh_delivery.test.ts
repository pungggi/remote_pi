import { afterEach, describe, expect, test, vi } from "vitest";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { MeshEnvelope } from "../extension-state.js";
import {
  MeshDeliveryRegistry,
  type MeshDeliveryController,
  type MeshDrainContext,
} from "./mesh_delivery.js";

type SendCall = [
  { customType: string; content?: string; display?: boolean },
  { triggerTurn?: boolean; deliverAs?: string },
];

const registries: MeshDeliveryRegistry[] = [];

function envelope(id: string): MeshEnvelope {
  return { id, from: "/work/repo@worker", re: null, body: { id } };
}

function harness(initialIdle = true) {
  let idle = initialIdle;
  const errors: string[] = [];
  const sendMessage = vi.fn();
  const pi = { sendMessage, sendUserMessage: () => undefined } as unknown as ExtensionAPI;
  const registry = new MeshDeliveryRegistry((message) => errors.push(message));
  registries.push(registry);
  const owner = registry.for(pi);
  const ctx: MeshDrainContext = { isIdle: () => idle };
  owner.captureContext(ctx);
  return {
    pi,
    registry,
    owner,
    ctx,
    errors,
    sendMessage,
    setIdle(value: boolean) { idle = value; },
  };
}

function calls(sendMessage: ReturnType<typeof vi.fn>): SendCall[] {
  return sendMessage.mock.calls as SendCall[];
}

function appends(sendMessage: ReturnType<typeof vi.fn>): SendCall[] {
  return calls(sendMessage).filter(([message, options]) =>
    message.customType === "remote-pi:mesh-message" && options.triggerTurn === false
  );
}

function wakes(sendMessage: ReturnType<typeof vi.fn>): SendCall[] {
  return calls(sendMessage).filter(([message, options]) =>
    message.customType === "remote-pi:mesh-wake" && options.triggerTurn === true
  );
}

function appendContents(sendMessage: ReturnType<typeof vi.fn>): string[] {
  return appends(sendMessage).map(([message]) => message.content ?? "");
}

afterEach(() => {
  for (const registry of registries.splice(0)) registry.disposeAll();
  vi.useRealTimers();
});

describe("MeshDeliveryController", () => {
  test("idle FIFO appends once before one separate hidden follow-up wake", async () => {
    const h = harness();
    h.owner.deliver(envelope("first"));
    h.owner.deliver({ ...envelope("second"), re: "first", body: "reply" });
    await Promise.resolve();

    expect(appendContents(h.sendMessage)).toEqual([
      expect.stringContaining("(id=first)"),
      expect.stringContaining("(id=second, re=first)"),
    ]);
    expect(appendContents(h.sendMessage)[1]).toContain("reply");
    expect(wakes(h.sendMessage)).toHaveLength(1);
    expect(calls(h.sendMessage).map(([message]) => message.customType)).toEqual([
      "remote-pi:mesh-message",
      "remote-pi:mesh-message",
      "remote-pi:mesh-wake",
    ]);
    expect(wakes(h.sendMessage)[0]).toEqual([
      expect.objectContaining({ display: false }),
      { triggerTurn: true, deliverAs: "followUp" },
    ]);
  });

  test("waits for live idle after agent_end before appending a FIFO batch", async () => {
    vi.useFakeTimers();
    const h = harness(false);
    h.owner.agentStart(h.ctx);
    h.owner.deliver(envelope("deferred-1"));
    h.owner.deliver(envelope("deferred-2"));
    await Promise.resolve();

    h.owner.agentEnd(h.ctx);
    await vi.advanceTimersByTimeAsync(10);
    expect(appends(h.sendMessage)).toHaveLength(0);
    expect(wakes(h.sendMessage)).toHaveLength(0);

    h.setIdle(true);
    await vi.advanceTimersByTimeAsync(10);
    expect(appendContents(h.sendMessage)).toEqual([
      expect.stringContaining("deferred-1"),
      expect.stringContaining("deferred-2"),
    ]);
    expect(wakes(h.sendMessage)).toHaveLength(1);
  });

  test("a delayed continuation keeps the pending batch out of both active runs", async () => {
    vi.useFakeTimers();
    const h = harness(false);
    h.owner.agentStart(h.ctx);
    h.owner.deliver(envelope("after-continuation"));
    h.owner.agentEnd(h.ctx);
    await vi.advanceTimersByTimeAsync(20);
    expect(h.sendMessage).not.toHaveBeenCalled();

    h.owner.agentStart(h.ctx);
    await vi.advanceTimersByTimeAsync(20);
    expect(h.sendMessage).not.toHaveBeenCalled();
    h.owner.agentEnd(h.ctx);
    h.setIdle(true);
    await vi.advanceTimersByTimeAsync(10);
    expect(appends(h.sendMessage)).toHaveLength(1);
    expect(wakes(h.sendMessage)).toHaveLength(1);
  });

  test("a synchronous wake rejection neither fabricates activity nor replays content", async () => {
    const h = harness();
    let rejectWake = true;
    h.sendMessage.mockImplementation((message: { customType: string }) => {
      if (message.customType === "remote-pi:mesh-wake" && rejectWake) {
        throw new Error("prompt still active");
      }
    });

    h.owner.deliver(envelope("first"));
    await Promise.resolve();
    expect(appendContents(h.sendMessage)).toEqual([expect.stringContaining("first")]);
    expect(wakes(h.sendMessage)).toHaveLength(1);

    rejectWake = false;
    h.owner.deliver(envelope("second"));
    await Promise.resolve();
    expect(appendContents(h.sendMessage)).toEqual([
      expect.stringContaining("first"),
      expect.stringContaining("second"),
    ]);
    expect(wakes(h.sendMessage)).toHaveLength(2);
    expect(h.errors[0]).toContain("prompt still active");
  });

  test("an unconfirmed wake releases later arrivals at timeout without replaying content", async () => {
    vi.useFakeTimers();
    const h = harness();
    h.owner.deliver(envelope("first"));
    await Promise.resolve();
    h.owner.deliver(envelope("second"));
    await Promise.resolve();

    await vi.advanceTimersByTimeAsync(999);
    expect(appendContents(h.sendMessage)).toEqual([expect.stringContaining("(id=first)")]);
    expect(wakes(h.sendMessage)).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(appendContents(h.sendMessage)).toEqual([
      expect.stringContaining("(id=first)"),
      expect.stringContaining("(id=second)"),
    ]);
    expect(wakes(h.sendMessage)).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(2_000);
    expect(appends(h.sendMessage)).toHaveLength(2);
    expect(wakes(h.sendMessage)).toHaveLength(2);
  });

  test("an unconfirmed wake timeout still waits for the live session to become idle", async () => {
    vi.useFakeTimers();
    const h = harness();
    h.owner.deliver(envelope("first"));
    await Promise.resolve();
    h.setIdle(false);
    await vi.advanceTimersByTimeAsync(1_000);

    h.owner.deliver(envelope("second"));
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(10);
    expect(appendContents(h.sendMessage)).toEqual([expect.stringContaining("first")]);
    expect(wakes(h.sendMessage)).toHaveLength(1);

    h.setIdle(true);
    await vi.advanceTimersByTimeAsync(10);
    expect(appendContents(h.sendMessage)).toEqual([
      expect.stringContaining("first"),
      expect.stringContaining("second"),
    ]);
    expect(wakes(h.sendMessage)).toHaveLength(2);
  });

  test("preserves an unsubmitted FIFO suffix after a synchronous partial append failure", async () => {
    const h = harness();
    let failSecondAppend = true;
    const accepted: string[] = [];
    h.sendMessage.mockImplementation((message: { customType: string; content?: string }) => {
      if (message.customType === "remote-pi:mesh-message" && message.content?.includes("second") && failSecondAppend) {
        h.owner.deliver(envelope("arrived-during-append"));
        throw new Error("append failed");
      }
      if (message.customType === "remote-pi:mesh-message") accepted.push(message.content ?? "");
    });

    h.owner.deliver(envelope("first"));
    h.owner.deliver(envelope("second"));
    await Promise.resolve();
    expect(accepted).toEqual([expect.stringContaining("first")]);
    expect(wakes(h.sendMessage)).toHaveLength(0);

    failSecondAppend = false;
    h.owner.deliver(envelope("third"));
    await Promise.resolve();
    expect(accepted).toEqual([
      expect.stringContaining("first"),
      expect.stringContaining("second"),
      expect.stringContaining("arrived-during-append"),
      expect.stringContaining("third"),
    ]);
    expect(wakes(h.sendMessage)).toHaveLength(1);
  });

  test("confirmed wakes release their token for the next post-end batch", async () => {
    vi.useFakeTimers();
    const h = harness();
    h.owner.deliver(envelope("confirmed"));
    await Promise.resolve();
    h.setIdle(false);
    h.owner.agentStart(h.ctx);
    h.owner.deliver(envelope("after-confirmation"));
    await Promise.resolve();
    expect(appends(h.sendMessage)).toHaveLength(1);

    h.owner.agentEnd(h.ctx);
    h.setIdle(true);
    await vi.advanceTimersByTimeAsync(10);
    expect(appendContents(h.sendMessage)).toEqual([
      expect.stringContaining("confirmed"),
      expect.stringContaining("after-confirmation"),
    ]);
    expect(wakes(h.sendMessage)).toHaveLength(2);
  });

  test.each(["microtask", "idle-recheck", "wake-timeout"])(
    "dispose invalidates %s work and rejects later delivery",
    async (pendingWork) => {
      vi.useFakeTimers();
      const h = harness(pendingWork !== "idle-recheck");
      h.owner.deliver(envelope("outgoing"));
      if (pendingWork !== "microtask") await Promise.resolve();
      if (pendingWork === "wake-timeout") {
        expect(wakes(h.sendMessage)).toHaveLength(1);
        h.owner.deliver(envelope("outgoing-pending"));
      }
      h.registry.dispose(h.pi);
      expect(h.owner.deliver(envelope("during-shutdown"))).toBe(false);
      h.setIdle(true);
      await Promise.resolve();
      await vi.advanceTimersByTimeAsync(2_000);
      expect(appends(h.sendMessage)).toHaveLength(pendingWork === "wake-timeout" ? 1 : 0);
      expect(wakes(h.sendMessage)).toHaveLength(pendingWork === "wake-timeout" ? 1 : 0);
    },
  );

  test("a replacement controller drains only replacement work", async () => {
    vi.useFakeTimers();
    const old = harness(false);
    old.owner.agentStart(old.ctx);
    old.owner.deliver(envelope("old-session"));
    old.registry.dispose(old.pi);
    old.setIdle(true);
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(2_000);
    expect(old.sendMessage).not.toHaveBeenCalled();

    const replacement = harness();
    replacement.registry.activate(replacement.pi);
    replacement.owner.deliver(envelope("replacement-session"));
    await Promise.resolve();
    expect(appendContents(replacement.sendMessage)).toEqual([
      expect.stringContaining("replacement-session"),
    ]);
    expect(wakes(replacement.sendMessage)).toHaveLength(1);
  });
});
