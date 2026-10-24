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

const harness = vi.hoisted(() => ({
  count: 0,
  /** Factory resolutions — set only after the real module finished loading. */
  resolved: 0,
  /** Optional gate: the mock factory awaits it before resolving (race tests). */
  gate: null as Promise<void> | null,
}));
vi.mock("./main.js", async (importOriginal) => {
  harness.count += 1;
  if (harness.gate) await harness.gate;
  const mod = await importOriginal<typeof import("./main.js")>();
  harness.resolved += 1;
  return mod;
});

import extension from "./index.js";
import { ext, resetExtensionState } from "./extension-state.js";

type Handler = (event: never, ctx: never) => unknown;

/** Minimal pi stub — enough for the factory's registrations + handler capture. */
function makePi() {
  const handlers = new Map<string, Handler>();
  const commands = new Map<string, { handler: (args: string, ctx: unknown) => unknown }>();
  const sent: unknown[] = [];
  const sendOptions: unknown[] = [];
  const pi = {
    on: (event: string, handler: Handler) => { handlers.set(event, handler); },
    registerCommand: (name: string, spec: { handler: (args: string, ctx: unknown) => unknown }) => {
      commands.set(name, spec);
    },
    registerTool: () => undefined,
    registerMessageRenderer: () => undefined,
    // The pi-ask bridge subscribes via pi.events; a minimal bus keeps it null-safe.
    events: { on: () => undefined, off: () => undefined },
    sendMessage: (msg: unknown, options: unknown) => {
      sent.push(msg);
      sendOptions.push(options);
    },
    sendUserMessage: () => undefined,
  } as unknown as ExtensionAPI;
  return { pi, handlers, commands, sent, sendOptions };
}

const fakeCtx = { ui: { notify: () => undefined }, cwd: process.cwd() };

beforeEach(() => resetExtensionState());

describe("thin-entry lazy boundary (plan/143)", () => {
  test("importing the entry does not load the runtime", () => {
    expect(harness.count).toBe(0);
    // Light accessors work runtime-free.
    expect(ext.state).toBe("idle");
    expect(ext.activePeers.size).toBe(0);
  });

  test("factory + low-activity session events stay runtime-free", () => {
    const { pi, handlers, sent, sendOptions } = makePi();
    extension(pi);
    // Factory preamble (bridge rebind, skill deploy) is inline — no runtime.
    expect(harness.count).toBe(0);

    // session_start without a local config: auto-start gate stays closed.
    handlers.get("session_start")!({ type: "session_start" } as never, fakeCtx as never);
    expect(harness.count).toBe(0);

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
    expect(sendOptions[0]).toEqual({ triggerTurn: false });
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

    expect(harness.count).toBe(0);
  });

  test("session_shutdown during the runtime import cancels the deferred session_start (PR #62 race)", async () => {
    // Hold the runtime import open so session_shutdown can interleave.
    let release!: () => void;
    harness.gate = new Promise<void>((r) => { release = r; });
    process.env["REMOTE_PI_DAEMON"] = "1";
    process.env["REMOTE_PI_DIRECT_CONFIG"] = JSON.stringify({ agent_name: "T", auto_start_relay: true });
    try {
      const { pi, handlers } = makePi();
      extension(pi);
      // auto-start gate passes (daemon + direct config) → deferred fwd starts
      // the runtime import, now parked behind the gate.
      handlers.get("session_start")!({ type: "session_start" } as never, fakeCtx as never);
      expect(harness.count).toBe(1);
      expect(harness.resolved).toBe(0);

      // shutdown interleaves BEFORE the import resolves: inline teardown sets
      // disposed + bumps rootLifecycleGeneration.
      await handlers.get("session_shutdown")!({} as never, fakeCtx as never);
      expect(ext.disposed).toBe(true);
      const genAfterShutdown = ext.rootLifecycleGeneration;

      release();
      await vi.waitFor(() => expect(harness.resolved).toBe(1), { timeout: 15000 });
      // Flush the fwd .then chain.
      await new Promise((r) => setTimeout(r, 50));

      // The deferred onSessionStart must NOT have re-armed a replaced session:
      // disposed stays set, generations untouched, nothing started.
      expect(ext.disposed).toBe(true);
      expect(ext.rootLifecycleGeneration).toBe(genAfterShutdown);
      expect(ext.state).toBe("idle");
      expect(ext.meshNode).toBeNull();
    } finally {
      delete process.env["REMOTE_PI_DAEMON"];
      delete process.env["REMOTE_PI_DIRECT_CONFIG"];
      harness.gate = null;
    }
  });

  test("CTRL_PREFIX input swallows synchronously AND loads the runtime", async () => {
    const { pi, handlers } = makePi();
    extension(pi);
    const result = handlers.get("input")!({ text: "\x00remote-pi-ctrl:ping", source: "interactive" } as never, fakeCtx as never);
    // The swallow decision is synchronous (SDK contract)…
    expect(result).toEqual({ action: "handled" });
    // …the control dispatch forwarded to the runtime — already loaded by the
    // race test above (module cache), so no second factory run.
    expect(harness.count).toBe(1);
  });

  test("commands dispatch through the runtime once loaded", async () => {
    const { pi, commands } = makePi();
    extension(pi);
    const status = commands.get("remote-pi status")!;
    // Runtime already loaded by the previous test — the dispatch runs the
    // real command handler (sync fast path) without error.
    await status.handler("", fakeCtx);
    expect(harness.count).toBe(1);
  });
});
