import { describe, expect, it } from "vitest";
import {
  applyRefWithPrecedence,
  ghPrViewRef,
  parseManualRefInput,
  sameRef,
  scanTextForRefSuggestion,
} from "./ref_ingest.js";

describe("parseManualRefInput (plan/149 manual path)", () => {
  it("parses a full GitHub PR URL", () => {
    expect(parseManualRefInput("https://github.com/pungggi/remote_pi/pull/70")).toEqual({
      pr: { number: 70, url: "https://github.com/pungggi/remote_pi/pull/70", state: null },
      issue: null,
      source: "manual",
    });
  });

  it("parses an issues URL as the issue slot", () => {
    expect(parseManualRefInput("https://github.com/pungggi/remote_pi/issues/123")).toEqual({
      pr: null,
      issue: { number: 123, url: "https://github.com/pungggi/remote_pi/issues/123", state: null },
      source: "manual",
    });
  });

  it("parses owner/repo#123 as an issue slot", () => {
    expect(parseManualRefInput("pungggi/remote_pi#123")).toEqual({
      pr: null,
      issue: { number: 123, url: "https://github.com/pungggi/remote_pi/issues/123", state: null },
      source: "manual",
    });
  });

  it("parses a URL buried in prose", () => {
    const r = parseManualRefInput("fixes https://github.com/o/r/pull/9 when ready");
    expect(r?.pr?.number).toBe(9);
  });

  it("REJECTS a bare #123 (acceptance: never enough on its own)", () => {
    expect(parseManualRefInput("#123")).toBeNull();
    expect(parseManualRefInput("see #123 and #456")).toBeNull();
  });

  it("rejects plain text / empty", () => {
    expect(parseManualRefInput("")).toBeNull();
    expect(parseManualRefInput("hello world")).toBeNull();
    expect(parseManualRefInput("https://example.com/o/r/pull/1")).toBeNull();
  });
});

describe("scanTextForRefSuggestion (plan/149 chat scan)", () => {
  it("suggests from a full URL, source chat", () => {
    const s = scanTextForRefSuggestion("PR ready: https://github.com/o/r/pull/45");
    expect(s).toEqual({
      pr: { number: 45, url: "https://github.com/o/r/pull/45", state: null },
      issue: null,
      source: "chat",
    });
  });

  it("suggests from owner/repo#123", () => {
    const s = scanTextForRefSuggestion("tracking o/r#77 for this");
    expect(s?.issue?.number).toBe(77);
    expect(s?.source).toBe("chat");
  });

  it("NEVER suggests from a bare #123 (acceptance)", () => {
    expect(scanTextForRefSuggestion("plan 51 ended up meaning two different things #51")).toBeNull();
  });

  it("the LAST mention wins (most recent is the relevant one)", () => {
    const s = scanTextForRefSuggestion(
      "first https://github.com/o/r/pull/1 then later o/r#2",
    );
    expect(s?.issue?.number).toBe(2);
  });

  it("returns null for text without refs", () => {
    expect(scanTextForRefSuggestion("no links here")).toBeNull();
    expect(scanTextForRefSuggestion("")).toBeNull();
  });
});

describe("applyRefWithPrecedence (manual > gh > chat)", () => {
  const ghRef = (n: number, state = "OPEN") => ({
    pr: { number: n, url: `https://github.com/o/r/pull/${n}`, state },
    issue: null as null,
    source: "gh" as const,
  });
  const manualIssue = (n: number) => ({
    pr: null as null,
    issue: { number: n, url: `https://github.com/o/r/issues/${n}`, state: null },
    source: "manual" as const,
  });

  it("manual always wins over anything", () => {
    const cur = ghRef(45);
    const incoming = manualIssue(12);
    const { next, changed } = applyRefWithPrecedence(cur, incoming);
    expect(changed).toBe(true);
    expect(next.source).toBe("manual");
    expect(next.issue?.number).toBe(12);
  });

  it("gh never replaces a manual PR with a DIFFERENT PR number", () => {
    const cur = {
      pr: { number: 12, url: "https://github.com/o/r/pull/12", state: null },
      issue: null as null,
      source: "manual" as const,
    };
    const { next, changed } = applyRefWithPrecedence(cur, ghRef(45));
    expect(changed).toBe(false);
    expect(next).toEqual(cur);
  });

  it("gh refreshes state/url of the SAME manual PR", () => {
    const cur = {
      pr: { number: 45, url: "https://github.com/o/r/pull/45", state: null },
      issue: null as null,
      source: "manual" as const,
    };
    const { next, changed } = applyRefWithPrecedence(cur, ghRef(45, "MERGED"));
    expect(changed).toBe(true);
    expect(next.pr?.state).toBe("MERGED");
    expect(next.source).toBe("manual"); // provenance stays manual
  });

  it("gh ADDS a PR beside a manual issue link (both slots kept)", () => {
    const cur = manualIssue(12);
    const { next, changed } = applyRefWithPrecedence(cur, ghRef(45));
    expect(changed).toBe(true);
    expect(next.issue?.number).toBe(12);
    expect(next.pr?.number).toBe(45);
    expect(next.source).toBe("manual");
  });

  it("gh over gh / gh over chat applies", () => {
    const fromChat = {
      pr: { number: 9, url: "https://github.com/o/r/pull/9", state: null },
      issue: null as null,
      source: "chat" as const,
    };
    const { next, changed } = applyRefWithPrecedence(fromChat, ghRef(45));
    expect(changed).toBe(true);
    expect(next.source).toBe("gh");
    expect(next.pr?.number).toBe(45);
  });

  it("identical values report changed=false (no wire churn)", () => {
    const cur = ghRef(45);
    const { changed } = applyRefWithPrecedence(cur, ghRef(45));
    expect(changed).toBe(false);
  });

  it("sameRef treats undefined and null slots as equal", () => {
    expect(sameRef(null, undefined)).toBe(true);
    expect(
      sameRef({ pr: { number: 1, url: null, state: null } }, { pr: { number: 1 } }),
    ).toBe(true);
  });
});

describe("ghPrViewRef (plan/149 gh path)", () => {
  it("parses number/url/state", async () => {
    const run = async () => JSON.stringify({ number: 45, url: "https://github.com/o/r/pull/45", state: "OPEN" });
    const ref = await ghPrViewRef("C:\\proj", run);
    expect(ref).toEqual({
      pr: { number: 45, url: "https://github.com/o/r/pull/45", state: "OPEN" },
      issue: null,
      source: "gh",
    });
  });

  it("runner failure → null (changes nothing, errors nothing)", async () => {
    const run = async () => null;
    expect(await ghPrViewRef("C:\\proj", run)).toBeNull();
  });

  it("malformed JSON → null", async () => {
    const run = async () => "not json";
    expect(await ghPrViewRef("C:\\proj", run)).toBeNull();
  });

  it("JSON without a finite number → null", async () => {
    const run = async () => JSON.stringify({ url: "x", state: "OPEN" });
    expect(await ghPrViewRef("C:\\proj", run)).toBeNull();
  });
});
