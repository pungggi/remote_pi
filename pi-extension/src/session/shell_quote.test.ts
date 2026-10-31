import { describe, expect, test } from "vitest";
import { quoteWindowsShellArg, quoteWindowsShellArgs } from "./shell_quote.js";

describe("quoteWindowsShellArg", () => {
  test("keeps metacharacter-free arguments bare", () => {
    expect(quoteWindowsShellArg("--resume")).toBe("--resume");
    expect(quoteWindowsShellArg("C:\\repo\\src.ts")).toBe("C:\\repo\\src.ts");
    expect(quoteWindowsShellArg("user@host")).toBe("user@host");
  });

  test("quotes arguments whose unquoted form would be re-split by cmd.exe", () => {
    // The review's example: `&` must not become a command separator.
    expect(quoteWindowsShellArg("explain A & B")).toBe('"explain A & B"');
    expect(quoteWindowsShellArg("a|b")).toBe('"a|b"');
    expect(quoteWindowsShellArg("<input>")).toBe('"<input>"');
    expect(quoteWindowsShellArg("two words")).toBe('"two words"');
    expect(quoteWindowsShellArg("")).toBe('""');
  });

  test("doubles embedded quotes so cmd.exe stays inside the quoted region", () => {
    expect(quoteWindowsShellArg('say "hi"')).toBe('"say ""hi"""');
  });

  test("doubles trailing backslashes so they cannot escape the closing quote", () => {
    expect(quoteWindowsShellArg("C:\\my dir\\")).toBe('"C:\\my dir\\\\"');
  });

  test("quotes the whole passthrough argv", () => {
    expect(quoteWindowsShellArgs(["--flag", "explain A & B", "plain"])).toEqual([
      "--flag",
      '"explain A & B"',
      "plain",
    ]);
  });
});
