/**
 * plan/143 / issue #61 — lazy-boundary guard.
 *
 * The thin entry's whole point is that low-activity pi sessions never pay the
 * ~2 s runtime import. This file guards that boundary: `./main.js` is mocked
 * with a LOAD MARKER (its factory re-exports the real module), so any import
 * of the runtime — static or dynamic — is observable.
 *
 * Deliberately does NOT call `_preloadRuntimeForTest()`: the runtime may only
 * load when the last test explicitly commands it.
 */

import { beforeEach, describe, expect, test, vi } from "vitest";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const mainLoadMarker = vi.hoisted(() => ({ count: 0 }));
vi.mock("./main.js", async (importOriginal) => {
  mainLoadMarker.count += 1;
  return await importOriginal<typeof import("./main.js")>();
});

import extension from "./index.js";
import { ext, resetExtensionState } from "./extension-state.js";

type Handler = (event: never, ctx: never) => unknown;

/** Minimal pi stub — enough for the factory's registrations + handler capture. */
function makePi() {
  const handlers = new Map<string, Handler>();
  const commands = new Map<string, { handler: (args: string, ctx: unknown) => unknown }>();
  const sent: unknown[] = [];
  const pi = {
    on: (event: string, handler: Handler) => { handlers.set(event, handler); },
    registerCommand: (name: string, spec: { handler: (args: string, ctx: unknown) => unknown }) => {
      commands.set(name, spec);
    },
    registerTool: () => undefined,
    registerMessageRenderer: () => undefined,
    // The pi-ask bridge subscribes via pi.events; a minimal bus keeps it null-safe.
    events: { on: () => undefined, off: () => undefined },
    sendMessage: (msg: unknown) => { sent.push(msg); },
    sendUserMessage: () => undefined,
  } as unknown as ExtensionAPI;
  return { pi, handlers, commands, sent };
}

const fakeCtx = { ui: { notify: () => undefined }, cwd: process.cwd() };

beforeEach(() => resetExtensionState());

describe("thin-entry lazy boundary (plan/143)", () => {
  test("importing the entry does not load the runtime", () => {
    expect(mainLoadMarker.count).toBe(0);
    // Light accessors work runtime-free.
    expect(ext.state).toBe("idle");
    expect(ext.activePeers.size).toBe(0);
  });

  test("factory + low-activity session events stay runtime-free", () => {
    const { pi, handlers, sent } = makePi();
    extension(pi);
    // Factory preamble (bridge rebind, skill deploy) is inline — no runtime.
    expect(mainLoadMarker.count).toBe(0);

    // session_start without a local config: auto-start gate stays closed.
    handlers.get("session_start")!({ type: "session_start" } as never, fakeCtx as never);
    expect(mainLoadMarker.count).toBe(0);

    // A full no-peer turn: agent lifecycle + streamed text + message buffer
    // are pure ext writes (mirrors of main.ts's handlers).
    handlers.get("agent_start")!({} as never, fakeCtx as never);
    expect(ext.agentRunActive).toBe(true);
    handlers.get("message_update")!(
      { assistantMessageEvent: { type: "text_delta", delta: "hello" } } as never,
      fakeCtx as never,
    );
    expect(ext.turnText).toBe("hello");
    handlers.get("message_end")!(
      { message: { role: "user", content: "hi" } } as never,
      fakeCtx as never,
    );
    expect(ext.messageBuffer).toHaveLength(1);

    // turn_start late-model hydration runs runtime-free.
    const modelCtx = { ...fakeCtx, getModel: () => ({ name: "claude-test" }) };
    handlers.get("turn_start")!({} as never, modelCtx as never);
    expect(ext.currentModel).toBe("claude-test");

    // ui_prompt_* mirrors publish the custom-message transition via ext.pi.
    handlers.get("ui_prompt_start")!({ kind: "confirm", title: "Continue?" } as never, fakeCtx as never);
    expect(ext.waitingSdkInput).toBe(true);
    expect(sent).toHaveLength(1);
    expect((sent[0] as { customType?: string }).customType).toBe("remote-pi:ui-prompt");
    handlers.get("ui_prompt_end")!({} as never, fakeCtx as never);
    expect(ext.waitingSdkInput).toBe(false);
    // No second message: the transition mirror keys off
    // `ext.myRoomMeta?.waiting_for_input`, which is null until a relay session
    // builds the meta (identical to main's _publishWaitingForUser).
    expect(sent).toHaveLength(1);

    // session_compaction's synthetic marker is buffered runtime-free.
    handlers.get("session_compact")!(
      { compactionEntry: { summary: "s", tokensBefore: 42 } } as never,
      fakeCtx as never,
    );
    expect(ext.messageBuffer).toHaveLength(2);
    expect((ext.messageBuffer[1] as { role?: string }).role).toBe("compaction");

    // Non-CTRL input with no peers is a no-op (main.onInputRest is peers-gated).
    const inputResult = handlers.get("input")!({ text: "hello", source: "interactive" } as never, fakeCtx as never);
    expect(inputResult).toBeUndefined();

    // session_shutdown with nothing live tears down inline.
    expect((handlers.get("session_shutdown")!({} as never, fakeCtx as never) as Promise<void>)).toBeInstanceOf(Promise);
    expect(ext.disposed).toBe(true);

    expect(mainLoadMarker.count).toBe(0);
  });

  test("CTRL_PREFIX input swallows synchronously AND loads the runtime", async () => {
    const { pi, handlers } = makePi();
    extension(pi);
    const result = handlers.get("input")!({ text: "\x00remote-pi-ctrl:ping", source: "interactive" } as never, fakeCtx as never);
    // The swallow decision is synchronous (SDK contract)…
    expect(result).toEqual({ action: "handled" });
    // …while the control dispatch forwards to the runtime (heavy action).
    await vi.waitFor(() => expect(mainLoadMarker.count).toBe(1));
  });

  test("commands dispatch through the runtime once loaded", async () => {
    const { pi, commands } = makePi();
    extension(pi);
    const status = commands.get("remote-pi status")!;
    // Runtime already loaded by the previous test — the dispatch runs the
    // real command handler (sync fast path) without error.
    await status.handler("", fakeCtx);
    expect(mainLoadMarker.count).toBe(1);
  });
});
