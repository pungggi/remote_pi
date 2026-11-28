import { describe, expect, test } from "vitest";
import { AGY_LAUNCH_COMMAND, buildAgentCommand, piModelFlag, shellSingleQuote } from "./launch.js";

describe("buildAgentCommand (plan/173 A2)", () => {
  test("Pi without a model: bare, new, continue, and the stored session id", () => {
    expect(buildAgentCommand({ agent: "pi" })).toBe("pi");
    expect(buildAgentCommand({ agent: "pi", resume: { kind: "new" } })).toBe("pi");
    expect(buildAgentCommand({ agent: "pi", resume: { kind: "continue" } })).toBe("pi --continue");
    expect(buildAgentCommand({ agent: "pi", resume: { kind: "session-id", id: "abc-123" } })).toBe(
      "pi --session-id 'abc-123'",
    );
  });

  // Issue #142 — the room registry can hold an id whose session has no file
  // (never written, or deleted). `pi --session <id>` then exits at once and
  // the terminal closes with it; `--session-id` opens the session or creates
  // it, so the start survives both cases.
  test("a stored session id is opened or created, never --session", () => {
    const command = buildAgentCommand({
      agent: "pi",
      resume: { kind: "session-id", id: "01a22212-e81e-70d3-ad8d-f657d0ed74c5" },
    });
    expect(command).toBe("pi --session-id '01a22212-e81e-70d3-ad8d-f657d0ed74c5'");
    expect(command).not.toMatch(/--session /);
  });

  test("Pi with a model gets --model provider/id after the resume flag", () => {
    const model = { provider: "zai", model_id: "glm-5.3-flash" };
    expect(buildAgentCommand({ agent: "pi", model })).toBe("pi --model zai/glm-5.3-flash");
    expect(buildAgentCommand({ agent: "pi", resume: { kind: "continue" }, model })).toBe(
      "pi --continue --model zai/glm-5.3-flash",
    );
    expect(buildAgentCommand({ agent: "pi", resume: { kind: "session-id", id: "s1" }, model })).toBe(
      "pi --session-id 's1' --model zai/glm-5.3-flash",
    );
  });

  test("AGY runs through the mesh wrapper and only its own model id", () => {
    expect(buildAgentCommand({ agent: "agy" })).toBe(AGY_LAUNCH_COMMAND);
    expect(buildAgentCommand({ agent: "agy" })).toBe("remote-pi agy");
    // The display provider the app sends never reaches the command line.
    expect(
      buildAgentCommand({ agent: "agy", model: { provider: "google", model_id: "gemini-4-neon-high" } }),
    ).toBe("remote-pi agy --model gemini-4-neon-high");
  });

  test("AGY has no session resume: a resume hint does not change its command", () => {
    expect(
      buildAgentCommand({ agent: "agy", resume: { kind: "session-id", id: "stored-pi-session" } }),
    ).toBe("remote-pi agy");
  });

  test("a model token that must not reach a shell is refused, for both agents", () => {
    for (const bad of ["a b", "x;rm -rf", "$(id)", "a/../../x", "-lead", ""]) {
      expect(() => buildAgentCommand({ agent: "pi", model: { provider: "zai", model_id: bad } })).toThrow(RangeError);
      expect(() => buildAgentCommand({ agent: "agy", model: { provider: "google", model_id: bad } })).toThrow(RangeError);
    }
    expect(() => buildAgentCommand({ agent: "pi", model: { provider: "z ai", model_id: "glm" } })).toThrow(/invalid model provider/);
    expect(() => buildAgentCommand({ agent: "pi", model: { provider: "zai", model_id: "a b" } })).toThrow(/invalid model id/);
  });

  test("piModelFlag is empty without a model", () => {
    expect(piModelFlag(null)).toBe("");
    expect(piModelFlag(undefined)).toBe("");
  });

  test("a session id is single-quoted for PowerShell and POSIX shells", () => {
    expect(shellSingleQuote("plain")).toBe("'plain'");
    expect(shellSingleQuote("it's")).toBe("'it''s'");
  });
});
