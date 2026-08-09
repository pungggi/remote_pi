import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtemp, rm, writeFile, utimes } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  buildIndex,
  decodeCursor,
  encodeCwd,
  encodeCursor,
  readMessages,
  refreshIndex,
  resolveCurrentSessionFile,
  sessionsRoot,
  type FileIndex,
} from "./file_index.js";

/** One `{type:'message', message:{...}}` line, no trailing newline yet. */
function msgLine(role: string, ts: number, content: string, extra: Record<string, unknown> = {}): string {
  return JSON.stringify({ type: "message", message: { role, timestamp: ts, content, ...extra } });
}

async function tmpDir(): Promise<string> {
  return mkdtemp(join(tmpdir(), "pi-fix-"));
}

describe("file_index path helpers", () => {
  it("encodeCwd: strips leading sep, replaces / \\ : with -, wraps in --…--", () => {
    expect(encodeCwd("/Users/jacob/app")).toBe("--Users-jacob-app--");
    expect(encodeCwd("R:\\code\\orbe")).toBe("--R--code-orbe--");
    expect(encodeCwd("C:/Users/Alessandro/source/pi")).toBe("--C--Users-Alessandro-source-pi--");
  });

  it("sessionsRoot: honors PI_CODING_AGENT_DIR", () => {
    const prev = process.env.PI_CODING_AGENT_DIR;
    try {
      process.env.PI_CODING_AGENT_DIR = "/tmp/agent-x";
      expect(sessionsRoot()).toBe(join("/tmp/agent-x", "sessions"));
    } finally {
      if (prev === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = prev;
    }
  });
});

describe("file_index buildIndex", () => {
  let dir: string;
  beforeEach(async () => ({ dir } = { dir: await tmpDir() } as { dir: string }));
  afterEach(async () => {
    if (dir) await rm(dir, { recursive: true, force: true });
  });

  it("indexes only message lines, records byteOffset/byteLen/ts/role", async () => {
    const path = join(dir, "s.jsonl");
    const lines = [
      JSON.stringify({ type: "summary", text: "not a message" }),
      msgLine("user", 1000, "hello"),
      msgLine("assistant", 1001, [{ type: "text", text: "hi" }]),
      "{ this is not valid json",
      msgLine("toolResult", 1002, "ok"),
      "",
    ];
    await writeFile(path, lines.join("\n") + "\n");
    const idx = await buildIndex(path);
    expect(idx.entries.map((e) => e.role)).toEqual(["user", "assistant", "toolResult"]);
    expect(idx.entries.map((e) => e.ts)).toEqual([1000, 1001, 1002]);
    // byteOffset ascending (chronological) + byteLen excludes trailing \n
    for (const e of idx.entries) expect(e.byteLen).toBeGreaterThan(0);
    expect(idx.entries[0].byteOffset).toBeLessThan(idx.entries[1].byteOffset);
    expect(idx.keys.has("1000:user")).toBe(true);
    expect(idx.keys.has("1002:toolResult")).toBe(true);
    expect(idx.keys.size).toBe(3);
    expect(idx.olderDropped).toBe(false);
  });

  it("skips a trailing partial line (no \\n) and sets resumeOffset before it", async () => {
    const path = join(dir, "s.jsonl");
    const complete = msgLine("user", 1000, "hi");
    const partial = msgLine("assistant", 1001, "mid-write"); // NO trailing \n
    await writeFile(path, complete + "\n" + partial);
    const idx = await buildIndex(path);
    expect(idx.entries.map((e) => e.role)).toEqual(["user"]); // partial not consumed
    // resumeOffset lands just past the complete line's \n, i.e. before the partial
    expect(idx.lastByteOffset).toBe(complete.length + 1);
  });
});

describe("file_index refreshIndex (cache / tail-scan / rebuild)", () => {
  let dir: string;
  let path: string;
  beforeEach(async () => {
    dir = await tmpDir();
    path = join(dir, "s.jsonl");
  });
  afterEach(async () => {
    if (dir) await rm(dir, { recursive: true, force: true });
  });

  it("cache hit: identical {path,size,mtime} returns prev (no I/O)", async () => {
    await writeFile(path, msgLine("user", 1, "a") + "\n");
    const idx = await buildIndex(path);
    const same = await refreshIndex(idx, { path, size: idx.size, mtimeMs: idx.mtimeMs });
    expect(same).toBe(idx); // identity — no rebuild
  });

  it("tail scan: file grew → appends only new lines, advances resumeOffset", async () => {
    const first = msgLine("user", 1, "a") + "\n";
    await writeFile(path, first);
    const prev = await buildIndex(path);
    expect(prev.entries).toHaveLength(1);

    // append two more lines
    const more = msgLine("assistant", 2, "b") + "\n" + msgLine("user", 3, "c") + "\n";
    const { statSync } = await import("node:fs");
    await writeFile(path, first + more, { flag: "w" });
    const st = statSync(path);
    const next = await refreshIndex(prev, { path, size: st.size, mtimeMs: st.mtimeMs });
    expect(next.entries.map((e) => e.role)).toEqual(["user", "assistant", "user"]);
    expect(next.lastByteOffset).toBeGreaterThan(prev.lastByteOffset);
    expect(next.keys.size).toBe(3);
  });

  it("tail scan completes a previously-partial trailing line", async () => {
    const complete = msgLine("user", 1, "a");
    await writeFile(path, complete + "\n" + msgLine("assistant", 2, "partial"));
    const prev = await buildIndex(path);
    expect(prev.entries.map((e) => e.role)).toEqual(["user"]); // partial held

    // now finish the partial (append its \n) + one more line
    const { statSync } = await import("node:fs");
    await writeFile(path, complete + "\n" + msgLine("assistant", 2, "partial") + "\n" + msgLine("user", 3, "next") + "\n", { flag: "w" });
    const st = statSync(path);
    const next = await refreshIndex(prev, { path, size: st.size, mtimeMs: st.mtimeMs });
    expect(next.entries.map((e) => e.role)).toEqual(["user", "assistant", "user"]);
  });

  it("rebuild: file shrank (replace/truncate) → full re-scan", async () => {
    await writeFile(path, msgLine("user", 1, "a") + "\n" + msgLine("user", 2, "b") + "\n");
    const prev = await buildIndex(path);
    // overwrite with a single shorter line (size shrank)
    const { statSync } = await import("node:fs");
    await writeFile(path, msgLine("user", 9, "z") + "\n", { flag: "w" });
    const st = statSync(path);
    const next = await refreshIndex(prev, { path, size: st.size, mtimeMs: st.mtimeMs });
    expect(next.entries.map((e) => e.ts)).toEqual([9]);
    expect(next).not.toBe(prev);
  });

  it("rebuild: same-size rewrite (mtime changed) → full re-scan, no stale entries", async () => {
    const { statSync } = await import("node:fs");
    // two single-line files with identical byte length but different content
    // (ts 1→9, text aaa→bbb: both same-length JSON).
    await writeFile(path, msgLine("user", 1, "aaa") + "\n");
    const prev = await buildIndex(path);
    expect(prev.entries.map((e) => e.ts)).toEqual([1]);

    await writeFile(path, msgLine("user", 9, "bbb") + "\n", { flag: "w" });
    const st = statSync(path);
    // same size, different mtime ⇒ must NOT tail-scan-noop; must rebuild.
    const next = await refreshIndex(prev, { path, size: st.size, mtimeMs: st.mtimeMs + 1000 });
    expect(next.entries.map((e) => e.ts)).toEqual([9]); // rebuilt, not stale [1]
    expect(next).not.toBe(prev);
  });

  it("INDEX_MAX cap: keeps newest N, sets olderDropped, keys reflect kept only", async () => {
    const prev = process.env.REMOTE_PI_HISTORY_INDEX_MAX;
    process.env.REMOTE_PI_HISTORY_INDEX_MAX = "3";
    try {
      const lines = [1, 2, 3, 4, 5].map((n) => msgLine("user", n, `m${n}`)).join("\n") + "\n";
      await writeFile(path, lines);
      const idx = await buildIndex(path);
      expect(idx.entries.map((e) => e.ts)).toEqual([3, 4, 5]); // newest 3
      expect(idx.olderDropped).toBe(true);
      const expectedKeys = new Set(idx.entries.map((e) => `${e.ts}:${e.role}`));
      expect(idx.keys).toEqual(expectedKeys);
      expect(idx.keys.has("1:user")).toBe(false);
      expect(idx.keys.has("5:user")).toBe(true);
    } finally {
      if (prev === undefined) delete process.env.REMOTE_PI_HISTORY_INDEX_MAX;
      else process.env.REMOTE_PI_HISTORY_INDEX_MAX = prev;
    }
  });
});

describe("file_index readMessages", () => {
  let dir: string;
  afterEach(async () => {
    if (dir) await rm(dir, { recursive: true, force: true });
  });

  it("reads only the requested byte ranges and parses message bodies", async () => {
    dir = await tmpDir();
    const path = join(dir, "s.jsonl");
    const lines = [
      msgLine("user", 10, "first"),
      msgLine("assistant", 11, [{ type: "text", text: "second" }]),
      msgLine("toolResult", 12, "third", { toolCallId: "tc1" }),
    ].join("\n") + "\n";
    await writeFile(path, lines);
    const idx = await buildIndex(path);
    // request only the assistant + toolResult entries
    const page = idx.entries.slice(1, 3);
    const msgs = await readMessages(path, page);
    expect(msgs.map((m) => m.role)).toEqual(["assistant", "toolResult"]);
    expect(msgs[0].content).toEqual([{ type: "text", text: "second" }]);
    expect(msgs[1]).toMatchObject({ role: "toolResult", toolCallId: "tc1" });
  });
});

describe("file_index cursor codec", () => {
  it("round-trips file-offset cursors", () => {
    expect(encodeCursor({ kind: "off", offset: 12345 })).toBe("off:12345");
    expect(decodeCursor("off:12345")).toEqual({ kind: "off", offset: 12345 });
  });
  it("round-trips RAM-index cursors", () => {
    expect(encodeCursor({ kind: "ram", index: 7 })).toBe("ram:7");
    expect(decodeCursor("ram:7")).toEqual({ kind: "ram", index: 7 });
  });
  it("decode tolerates undefined / garbage", () => {
    expect(decodeCursor(undefined)).toBeNull();
    expect(decodeCursor(null)).toBeNull();
    expect(decodeCursor("nope:1")).toBeNull();
    expect(decodeCursor("off:abc")).toBeNull();
  });
});

describe("file_index resolveCurrentSessionFile", () => {
  let dir: string;
  let savedRoot: string;
  beforeEach(async () => {
    dir = await tmpDir();
    savedRoot = process.env.PI_CODING_AGENT_DIR!;
    process.env.PI_CODING_AGENT_DIR = dir;
  });
  afterEach(async () => {
    process.env.PI_CODING_AGENT_DIR = savedRoot;
    await rm(dir, { recursive: true, force: true });
  });

  it("picks the newest .jsonl by mtime under the encoded cwd dir", async () => {
    const { mkdir, writeFile: wf } = await import("node:fs/promises");
    const cwdDir = join(dir, "sessions", encodeCwd("/proj"));
    await mkdir(cwdDir, { recursive: true });
    const older = join(cwdDir, "1_aaa.jsonl");
    const newer = join(cwdDir, "2_bbb.jsonl");
    const noise = join(cwdDir, "readme.txt");
    await wf(older, msgLine("user", 1, "old") + "\n");
    await wf(newer, msgLine("user", 2, "new") + "\n");
    await wf(noise, "ignore me");
    // pin mtimes: older=100s ago, newer=10s ago
    const now = Date.now() / 1000;
    await utimes(older, now - 100, now - 100);
    await utimes(newer, now - 10, now - 10);

    const ref = resolveCurrentSessionFile("/proj");
    expect(ref?.path).toBe(newer);
    expect(ref?.size).toBeGreaterThan(0);
  });

  it("returns null when the cwd dir has no transcripts", async () => {
    const ref = resolveCurrentSessionFile("/nope-empty");
    expect(ref).toBeNull();
  });
});

// keep an explicit reference so unused-import lint of the type stays satisfied
export type _KeepFileIndex = FileIndex;
