/**
 * Plan/158 — file registry sidecar unit tests.
 *
 * Covers: append/load roundtrip (incl. optional fields), tolerant parsing
 * (corrupt/partial lines skipped, never thrown), the `<session>.jsonl →
 * <session>.files.jsonl` path mapping, and the `.pending.files.jsonl`
 * fallback when no transcript exists yet. Runs inside a sandboxed
 * PI_CODING_AGENT_DIR so the real ~/.pi tree is never touched.
 */
import { afterAll, afterEach, describe, expect, test } from "vitest";
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  appendRegistryEntry,
  loadRegistryEntries,
  registryPathForSession,
  registryTargetForCwd,
  type AgentFileRegistryEntry,
} from "./file_registry.js";
import { encodeCwd } from "./file_index.js";

const savedAgentDir = process.env.PI_CODING_AGENT_DIR;
const tmpAgentDir = mkdtempSync(join(tmpdir(), "pi-file-registry-"));
process.env.PI_CODING_AGENT_DIR = tmpAgentDir;

afterAll(() => {
  if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
  rmSync(tmpAgentDir, { recursive: true, force: true });
});

describe("file registry sidecar (plan/158)", () => {
  const agentDirs: string[] = [];

  afterEach(() => {
    for (const d of agentDirs.splice(0)) rmSync(d, { recursive: true, force: true });
  });

  /** A fake transcript under its own agent dir; resolves as "current session". */
  function seededTranscript(): { dir: string; sessionPath: string } {
    const dir = mkdtempSync(join(tmpAgentDir, "sessions-run-"));
    agentDirs.push(dir);
    const sessionsDir = join(dir, "sessions", encodeCwd(process.cwd()));
    mkdirSync(sessionsDir, { recursive: true });
    const sessionPath = join(sessionsDir, "1700000000000_test.jsonl");
    writeFileSync(sessionPath, "");
    return { dir, sessionPath };
  }

  function entry(over: Partial<AgentFileRegistryEntry> = {}): AgentFileRegistryEntry {
    return {
      fileId: `doc_${over.fileId ?? "0"}`,
      ts: 1700000000000,
      kind: "pdf",
      mime: "application/pdf",
      name: "report.pdf",
      bytes: 1234,
      absPath: join(tmpdir(), "report.pdf"),
      mtimeMs: 1700000000001,
      ...over,
    };
  }

  test("append + load roundtrip preserves every field", () => {
    const { sessionPath } = seededTranscript();
    const registryPath = registryPathForSession(sessionPath);
    appendRegistryEntry(registryPath, entry({ fileId: "doc_1", caption: "hello", allowNetwork: true }));
    appendRegistryEntry(registryPath, entry({ fileId: "doc_2", kind: "text", mime: "text/plain", name: "a.txt", bytes: 5 }));

    const all = loadRegistryEntries(registryPath);
    expect(all).toHaveLength(2);
    expect(all[0]).toMatchObject({
      fileId: "doc_1",
      ts: 1700000000000,
      kind: "pdf",
      mime: "application/pdf",
      name: "report.pdf",
      bytes: 1234,
      caption: "hello",
      allowNetwork: true,
      mtimeMs: 1700000000001,
    });
    expect(all[0]!.absPath).toContain("report.pdf");
    expect(all[1]).toMatchObject({ fileId: "doc_2", kind: "text", bytes: 5 });
  });

  test("optional fields absent → undefined, not null/empty", () => {
    const { sessionPath } = seededTranscript();
    const registryPath = registryPathForSession(sessionPath);
    appendRegistryEntry(registryPath, entry({
      fileId: "doc_min",
      caption: undefined,
      allowNetwork: undefined,
      mime: undefined,
      name: undefined,
    }));
    const [e] = loadRegistryEntries(registryPath);
    expect(e!.fileId).toBe("doc_min");
    expect(e!.caption).toBeUndefined();
    expect(e!.allowNetwork).toBeUndefined();
    expect(e!.mime).toBeUndefined();
    expect(e!.name).toBeUndefined();
  });

  test("corrupt lines are skipped, never thrown", () => {
    const { sessionPath } = seededTranscript();
    const registryPath = registryPathForSession(sessionPath);
    appendRegistryEntry(registryPath, entry({ fileId: "doc_ok" }));
    // Partial write (no closing brace), blank line, non-JSON line, non-object.
    appendFileSync(registryPath, '{"fileId": "doc_trunc", "absPath":\n', "utf8");
    appendFileSync(registryPath, "\n", "utf8");
    appendFileSync(registryPath, "not json at all\n", "utf8");
    appendFileSync(registryPath, '"just a string"\n', "utf8");

    const all = loadRegistryEntries(registryPath);
    expect(all.map((e) => e.fileId)).toEqual(["doc_ok"]);
  });

  test("missing registry file → empty array (no throw)", () => {
    expect(loadRegistryEntries(join(tmpdir(), "nope.files.jsonl"))).toEqual([]);
  });

  test("registryPathForSession maps .jsonl → .files.jsonl", () => {
    expect(registryPathForSession(join("s", "a_b.jsonl"))).toBe(join("s", "a_b.files.jsonl"));
    expect(registryPathForSession("x.JSONL")).toContain(".files.jsonl");
  });

  test("registryTargetForCwd falls back to .pending sidecar without a transcript", () => {
    const dir = mkdtempSync(join(tmpAgentDir, "sessions-run-"));
    agentDirs.push(dir);
    const cwd = join(dir, "proj");
    mkdirSync(cwd, { recursive: true });
    const target = registryTargetForCwd(cwd);
    expect(target).toContain(encodeCwd(cwd));
    expect(target).toContain(".pending.files.jsonl");
    // Append + load against the fallback path works.
    appendRegistryEntry(target, entry({ fileId: "doc_pending" }));
    expect(loadRegistryEntries(target)).toHaveLength(1);
  });
});
