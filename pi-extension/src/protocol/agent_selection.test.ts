import { describe, expect, test } from "vitest";
import { decodeServer } from "./codec.js";
import {
  AGENT_KINDS,
  parseAgentKind,
  parseAgentSelection,
} from "./agent_selection.js";
import type { ServerMessage } from "./types.js";

describe("parseAgentKind (plan/173)", () => {
  test("absent and null are the default, Pi", () => {
    expect(parseAgentKind(undefined)).toEqual({ ok: true, agent: "pi" });
    expect(parseAgentKind(null)).toEqual({ ok: true, agent: "pi" });
  });

  test("both agents parse", () => {
    expect(parseAgentKind("pi")).toEqual({ ok: true, agent: "pi" });
    expect(parseAgentKind("agy")).toEqual({ ok: true, agent: "agy" });
    expect([...AGENT_KINDS]).toEqual(["pi", "agy"]);
  });

  test("an unknown agent is an error, never a fallback to Pi", () => {
    for (const bad of ["claude", "PI", "", 3, true, {}]) {
      const r = parseAgentKind(bad);
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.message).toMatch(/unknown agent/);
    }
  });

  test("the error names the value it refused", () => {
    const r = parseAgentKind("claude");
    expect(r).toEqual({
      ok: false,
      message: 'unknown agent "claude" (expected "pi" or "agy")',
    });
  });
});

describe("parseAgentSelection (plan/173)", () => {
  test("no fields → Pi, no model (the pre-173 request)", () => {
    expect(parseAgentSelection({})).toEqual({
      ok: true,
      selection: { agent: "pi", model: null },
    });
  });

  test("null halves are no model, same as absent", () => {
    expect(parseAgentSelection({ provider: null, model_id: null })).toEqual({
      ok: true,
      selection: { agent: "pi", model: null },
    });
  });

  test("a model needs both halves", () => {
    for (const fields of [{ provider: "zai" }, { model_id: "glm-5.3-flash" }]) {
      const r = parseAgentSelection(fields);
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.message).toMatch(/both provider and model_id/);
    }
  });

  test("Pi model passes through as provider/id", () => {
    expect(
      parseAgentSelection({ agent: "pi", provider: "zai", model_id: "glm-5.3-flash" }),
    ).toEqual({
      ok: true,
      selection: { agent: "pi", model: { provider: "zai", model_id: "glm-5.3-flash" } },
    });
  });

  test("AGY model keeps its id and the display provider", () => {
    expect(
      parseAgentSelection({ agent: "agy", provider: "google", model_id: "gemini-4-neon-high" }),
    ).toEqual({
      ok: true,
      selection: { agent: "agy", model: { provider: "google", model_id: "gemini-4-neon-high" } },
    });
  });

  test("forbidden characters in a token are refused with a clear error", () => {
    for (const bad of ["a b", "x;rm", "$(id)", "a/../../x", "-lead", "", "tab\tchar", "q\"uote"]) {
      const r = parseAgentSelection({ provider: "zai", model_id: bad });
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.message).toMatch(/invalid model id/);
    }
    const r = parseAgentSelection({ provider: "z ai", model_id: "glm" });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/invalid model provider/);
  });

  test("non-string halves are refused, not coerced", () => {
    for (const bad of [3, true, {}, []]) {
      expect(parseAgentSelection({ provider: "zai", model_id: bad }).ok).toBe(false);
      expect(parseAgentSelection({ provider: bad, model_id: "glm" }).ok).toBe(false);
    }
  });

  test("an unknown agent is reported before the model is looked at", () => {
    const r = parseAgentSelection({ agent: "claude", provider: "a b" });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/unknown agent/);
  });
});

describe("wire shapes (plan/173)", () => {
  test("device_info_result is a server message the codec accepts", () => {
    const msg: ServerMessage = decodeServer(
      JSON.stringify({
        type: "device_info_result",
        in_reply_to: "01J",
        ok: true,
        host: { platform: "android", label: "localhost", terminal: "tmux" },
        agents: ["pi", "agy"],
        version: "0.11.0",
      }),
    );
    expect(msg).toMatchObject({
      type: "device_info_result",
      ok: true,
      agents: ["pi", "agy"],
      version: "0.11.0",
      host: { platform: "android", terminal: "tmux" },
    });
  });

  test("device_info_result carries the reason when the device cannot describe itself", () => {
    const msg: ServerMessage = decodeServer(
      JSON.stringify({
        type: "device_info_result",
        in_reply_to: "01J",
        ok: false,
        agents: [],
        version: "0.11.0",
        message: "boom",
      }),
    );
    expect(msg).toMatchObject({ type: "device_info_result", ok: false, agents: [], message: "boom" });
  });

  // `models_list` is an action reply, not one of the relay fixture frames
  // `decodeServer` enumerates, so its shape is checked at compile time: the
  // literal below only builds while `agent` is part of the server union.
  test("models_list may carry the agent it answered for", () => {
    const msg: ServerMessage = {
      type: "models_list",
      in_reply_to: "01J",
      models: [
        {
          id: "gemini-4-neon-high",
          name: "Gemini 4 Neon (High)",
          provider: "google",
          reasoning: false,
          context_window: 0,
          vision: false,
        },
      ],
      agent: "agy",
    };
    expect(msg).toMatchObject({ type: "models_list", agent: "agy" });
    expect(msg.models).toHaveLength(1);
  });
});
