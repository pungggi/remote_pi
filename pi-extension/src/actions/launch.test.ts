import { describe, expect, test } from "vitest";
import { AGY_LAUNCH_COMMAND, buildAgentCommand, piModelFlag, shellSingleQuote } from "./launch.js";

describe("buildAgentCommand (plan/173 A2)", () => {
  test("Pi without a model is the pre-173 command for every resume kind", () => {
    expect(buildAgentCommand({ agent: "pi" })).toBe("pi");
    expect(buildAgentCommand({ agent: "pi", resume: { kind: "new" } })).toBe("pi");
    expect(buildAgentCommand({ agent: "pi", resume: { kind: "continue" } })).toBe("pi --continue");
    expect(buildAgentCommand({ agent: "pi", resume: { kind: "session", id: "abc-123" } })).toBe(
      "pi --session 'abc-123'",
    );
  });

  test("Pi with a model gets --model provider/id after the resume flag", () => {
    const model = { provider: "zai", model_id: "glm-5.3-flash" };
    expect(buildAgentCommand({ agent: "pi", model })).toBe("pi --model zai/glm-5.3-flash");
    expect(buildAgentCommand({ agent: "pi", resume: { kind: "continue" }, model })).toBe(
      "pi --continue --model zai/glm-5.3-flash",
    );
    expect(buildAgentCommand({ agent: "pi", resume: { kind: "session", id: "s1" }, model })).toBe(
      "pi --session 's1' --model zai/glm-5.3-flash",
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
      buildAgentCommand({ agent: "agy", resume: { kind: "session", id: "stored-pi-session" } }),
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
