/**
 * Plan/126 — unit tests for the `show_file` tool's kind detection, validation,
 * caps, and metadata-only result shape.
 *
 * Runs the extension factory against a tool-capturing mock and invokes the
 * captured `show_file` tool's `execute` directly. With no paired peer,
 * `_anyPeerActive()` is false so every result reports `shown:false` — but the
 * detection/cap/UTF-8 decisions and the metadata-only tool_result shape (NO
 * base64) are fully exercised. The live broadcast-to-peer path is covered by
 * an integration test in `extension.test.ts` (mirrors the `show_image
 * broadcasts` test).
 */
import { describe, expect, test, beforeEach, afterEach, afterAll } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { ExtensionAPI, ExtensionFactory } from "@earendil-works/pi-coding-agent";

// Plan/158 — pushes write a registry sidecar under PI_CODING_AGENT_DIR.
// Sandbox it per worker so tests never touch the real ~/.pi tree.
const savedAgentDir = process.env.PI_CODING_AGENT_DIR;
const tmpAgentDir = mkdtempSync(join(tmpdir(), "pi-show-file-agent-"));
process.env.PI_CODING_AGENT_DIR = tmpAgentDir;

const indexModule = await import("./index.js");
const extension = indexModule.default as ExtensionFactory;

afterAll(async () => {
  if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
  rmSync(tmpAgentDir, { recursive: true, force: true });
});

interface CapturedTool {
  name: string;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
  ) => Promise<{
    content?: { type: string; text?: string }[];
    details?: Record<string, unknown>;
  }>;
}

function captureShowFileTool(): CapturedTool {
  const tools: CapturedTool[] = [];
  const pi = {
    on: () => undefined,
    registerCommand: () => undefined,
    registerTool(t: CapturedTool) { tools.push(t); },
    registerShortcut: () => undefined,
    registerFlag: () => undefined, getFlag: () => undefined,
    registerMessageRenderer: () => undefined,
    sendMessage: () => undefined, sendUserMessage: () => undefined,
  } as unknown as ExtensionAPI;
  (extension as ExtensionFactory)(pi);
  const tool = tools.find((t) => t.name === "show_file");
  if (!tool) throw new Error("show_file tool was not registered");
  return tool;
}

// Minimal PDF: `%PDF-1.4` header is the magic the kind detector trusts by
// extension; the body is irrelevant (the viewer renders/paginates real PDFs).
const PDF_MINIMAL = Buffer.concat([
  Buffer.from("%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"),
  Buffer.from("1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF"),
]);

function tmpDir(): string {
  return mkdtempSync(join(tmpdir(), "pi-show-file-"));
}

/** Asserts the tool_result carries NO base64 content anywhere (plan/49/114
 *  discipline: bytes never enter the model context). */
function assertNoBase64Payload(
  result: { content?: { text?: string }[]; details?: Record<string, unknown> },
  data: string,
): void {
  const json = JSON.stringify(result);
  expect(json).not.toContain(data);
  if (result.details) {
    expect(result.details).not.toHaveProperty("data");
  }
}

describe("show_file tool (plan/126)", () => {
  let dir: string;
  // Plan/158 — registry sidecars accumulate across tests; purge per test so
  // fetch/history assertions never see a previous test's pushes.
  beforeEach(() => {
    dir = tmpDir();
    rmSync(join(tmpAgentDir, "sessions"), { recursive: true, force: true });
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("valid .md → kind markdown, metadata only, no base64 in result", async () => {
    const path = join(dir, "doc.md");
    const body = "# Title\n\nSome **markdown**.\n";
    writeFileSync(path, body);
    const data = Buffer.from(body).toString("base64");

    const tool = captureShowFileTool();
    const result = await tool.execute("call-1", { path });

    expect(result.details).toMatchObject({
      shown: false,
      kind: "markdown",
      path,
      mime: "text/markdown",
      bytes: Buffer.byteLength(body),
      reason: expect.stringContaining("no active peer"),
    });
    assertNoBase64Payload(result, data);
  });

  test("valid .txt → kind text", async () => {
    const path = join(dir, "notes.txt");
    writeFileSync(path, "plain text line\n");

    const tool = captureShowFileTool();
    const result = await tool.execute("call-2", { path });

    expect(result.details).toMatchObject({ kind: "text", mime: "text/plain" });
  });

  test("valid code extension (.dart) → kind text", async () => {
    const path = join(dir, "main.dart");
    writeFileSync(path, "void main() {}\n");

    const tool = captureShowFileTool();
    const result = await tool.execute("call-dart", { path });

    expect(result.details?.kind).toBe("text");
  });

  test("valid .pdf → kind pdf (10 MiB cap), metadata only", async () => {
    const path = join(dir, "report.pdf");
    writeFileSync(path, PDF_MINIMAL);
    const data = PDF_MINIMAL.toString("base64");

    const tool = captureShowFileTool();
    const result = await tool.execute("call-3", { path });

    expect(result.details).toMatchObject({
      kind: "pdf",
      mime: "application/pdf",
      bytes: PDF_MINIMAL.length,
    });
    assertNoBase64Payload(result, data);
  });

  test("valid .html → kind html", async () => {
    const path = join(dir, "page.html");
    writeFileSync(path, "<!doctype html><html><body><h1>Hi</h1></body></html>");

    const tool = captureShowFileTool();
    const result = await tool.execute("call-html", { path });

    expect(result.details?.kind).toBe("html");
    expect(result.details?.mime).toBe("text/html");
  });

  // Plan/144 — mermaid kind: .mmd/.mermaid auto-detect, text cap + UTF-8 rules
  // apply (mermaid source is text), metadata-only result.
  test("valid .mmd → kind mermaid, metadata only, no base64 in result", async () => {
    const path = join(dir, "flow.mmd");
    const body = "graph TD\n  A[Start] --> B{Ok?}\n  B -->|yes| C[Done]\n";
    writeFileSync(path, body);
    const data = Buffer.from(body).toString("base64");

    const tool = captureShowFileTool();
    const result = await tool.execute("call-mmd", { path });

    expect(result.details).toMatchObject({
      shown: false,
      kind: "mermaid",
      path,
      mime: "text/vnd.mermaid",
      bytes: Buffer.byteLength(body),
    });
    assertNoBase64Payload(result, data);
  });

  test("valid .mermaid → kind mermaid", async () => {
    const path = join(dir, "sequence.mermaid");
    writeFileSync(path, "sequenceDiagram\n  Alice->>Bob: hi\n");

    const tool = captureShowFileTool();
    const result = await tool.execute("call-mermaid-ext", { path });

    expect(result.details?.kind).toBe("mermaid");
  });

  test("explicit kind=mermaid override on unknown extension", async () => {
    const path = join(dir, "diagram.txt"); // .txt detects as text without override
    writeFileSync(path, "graph LR\n  A --> B\n");

    const tool = captureShowFileTool();
    const result = await tool.execute("call-mmd-force", { path, kind: "mermaid" });

    expect(result.details).toMatchObject({ kind: "mermaid", mime: "text/vnd.mermaid" });
  });

  test("binary content pushed as .mmd → shown:false 'not valid UTF-8'", async () => {
    const path = join(dir, "bad.mmd");
    writeFileSync(path, Buffer.from([0xff, 0xfe, 0x00, 0x01, 0x80, 0xc0]));

    const tool = captureShowFileTool();
    const result = await tool.execute("call-mmd-bin", { path });

    expect(result.details?.shown).toBe(false);
    expect(result.details?.error as string).toContain("not valid UTF-8");
  });

  test("explicit kind override forces rendering regardless of extension", async () => {
    const path = join(dir, "weird.dat");
    writeFileSync(path, "# this is actually markdown\n");

    const tool = captureShowFileTool();
    // Without override → unknown extension → rejected.
    const noKind = await tool.execute("call-a", { path });
    expect(noKind.details?.shown).toBe(false);
    expect(noKind.details?.error as string).toContain("unsupported/unknown");

    // With override → accepted as markdown.
    const forced = await tool.execute("call-b", { path, kind: "markdown" });
    expect(forced.details).toMatchObject({ shown: false, kind: "markdown", mime: "text/markdown" });
  });

  test("unknown extension without kind → shown:false 'unsupported/unknown'", async () => {
    const path = join(dir, "blob.xyz");
    writeFileSync(path, "whatever");

    const tool = captureShowFileTool();
    const result = await tool.execute("call-4", { path });

    expect(result.details?.shown).toBe(false);
    expect(result.details?.error as string).toContain("unsupported/unknown");
  });

  test("text file over 1 MiB cap → shown:false 'too large', rejected before broadcast", async () => {
    const path = join(dir, "big.txt");
    // 1.5 MiB of ASCII — size check fires for kind=text.
    writeFileSync(path, Buffer.alloc(Math.round(1.5 * 1024 * 1024), 0x41));

    const tool = captureShowFileTool();
    const result = await tool.execute("call-5", { path });

    expect(result.details?.shown).toBe(false);
    expect(result.details?.error as string).toContain("too large");
  });

  test("binary content pushed as .txt → shown:false 'not valid UTF-8'", async () => {
    const path = join(dir, "looks-like-text.txt");
    // Bytes that are NOT valid UTF-8: a lone 0xFF lead byte + raw bytes.
    writeFileSync(path, Buffer.from([0xff, 0xfe, 0x00, 0x01, 0x80, 0xc0]));

    const tool = captureShowFileTool();
    const result = await tool.execute("call-6", { path });

    expect(result.details?.shown).toBe(false);
    expect(result.details?.error as string).toContain("not valid UTF-8");
  });

  test("nonexistent path → shown:false with read error", async () => {
    const tool = captureShowFileTool();
    const result = await tool.execute("call-7", { path: join(dir, "nope.md") });

    expect(result.details?.shown).toBe(false);
    expect(result.details?.error as string).toContain("cannot read");
  });

  test("missing path argument → shown:false 'missing file path'", async () => {
    const tool = captureShowFileTool();
    const result = await tool.execute("call-8", { path: "  " });

    expect(result.details?.shown).toBe(false);
    expect(result.details?.error as string).toContain("missing file path");
  });

  test("not a regular file (directory) → shown:false 'not a regular file'", async () => {
    const tool = captureShowFileTool();
    const result = await tool.execute("call-dir", { path: dir });

    expect(result.details?.shown).toBe(false);
    expect(result.details?.error as string).toContain("not a regular file");
  });

  // Plan/114 review (carried over): failure paths must echo the agent-supplied
  // `rawPath` in details.path (never the resolved absolute form) so absolute
  // filesystem paths don't leak into model context.
  test("error never leaks the resolved absolute path into details.path", async () => {
    const tool = captureShowFileTool();
    const rel = join("definitely", "missing", "doc.md");
    const resolved = resolve(rel);

    const result = await tool.execute("call-leak", { path: rel });

    expect(result.details?.shown).toBe(false);
    expect(result.details?.path).toBe(rel);
    expect(JSON.stringify(result)).not.toContain(resolved);
  });

  test("result details never carry the file content / data field", async () => {
    const path = join(dir, "doc.md");
    const body = "# secret content that must not reach the model\n";
    writeFileSync(path, body);

    const tool = captureShowFileTool();
    const result = await tool.execute("call-nocontent", { path });

    expect(result.details).not.toHaveProperty("data");
    expect(result.details).not.toHaveProperty("content");
    expect(JSON.stringify(result)).not.toContain(body);
  });

  // Plan/126 review #1 — dotfiles (.env/.gitignore/.editorconfig/.npmrc) have
  // no real extension, so detection must fall back to the dot-stripped stem
  // against the extension + basename allowlists (not be rejected outright).
  test("common dotfiles detect as text (no kind= needed)", async () => {
    const tool = captureShowFileTool();
    for (const name of [".env", ".gitignore", ".editorconfig", ".npmrc"]) {
      const path = join(dir, name);
      writeFileSync(path, "some content\n");
      const result = await tool.execute(`dot-${name}`, { path });
      expect(result.details?.kind).toBe("text");
      expect(result.details?.mime).toBe("text/plain");
      expect(result.details?.shown).toBe(false); // no peer attached
      rmSync(path, { force: true });
    }
  });

  // Plan/162 — generic binary kind: save/share-only card, no viewer, no
  // UTF-8 gate, 50 MiB cap. Motivated by the jwl workflow (.jwlibrary
  // backups must reach the phone as raw bytes).
  describe("file kind (plan/162)", () => {
    const ZIPISH = Buffer.concat([
      Buffer.from([0x50, 0x4b, 0x03, 0x04]), // PK\x03\x04 zip magic
      Buffer.from("rest-of-the-archive"),
    ]);

    test(".jwlibrary auto-detects kind file (binary bytes, no UTF-8 gate)", async () => {
      const path = join(dir, "backup.jwlibrary");
      writeFileSync(path, ZIPISH);

      const tool = captureShowFileTool();
      const result = await tool.execute("call-jwl", { path });

      expect(result.details).toMatchObject({
        shown: false, // no peer in this harness
        kind: "file",
        path,
        mime: "application/octet-stream",
        bytes: ZIPISH.length,
      });
      // Binary skips the UTF-8 read: no "not valid UTF-8" rejection.
      expect(result.details?.error).toBeUndefined();
      // Metadata-only discipline still holds for binaries.
      assertNoBase64Payload(result, ZIPISH.toString("base64"));
    });

    test("archive/office extensions auto-detect kind file", async () => {
      const tool = captureShowFileTool();
      for (const name of ["pack.zip", "tool.apk", "sheet.xlsx", "book.epub"]) {
        const path = join(dir, name);
        writeFileSync(path, ZIPISH);
        const result = await tool.execute(`bin-${name}`, { path });
        expect(result.details?.kind).toBe("file");
        expect(result.details?.mime).toBe("application/octet-stream");
        rmSync(path, { force: true });
      }
    });

    test("explicit kind=file forces the binary card on an unknown extension", async () => {
      const path = join(dir, "payload.qtz");
      writeFileSync(path, ZIPISH);

      const tool = captureShowFileTool();
      // Without override → unknown extension → rejected.
      const noKind = await tool.execute("call-bin-a", { path });
      expect(noKind.details?.shown).toBe(false);
      expect(noKind.details?.error as string).toContain("unsupported/unknown");

      // With override → accepted as file.
      const forced = await tool.execute("call-bin-b", { path, kind: "file" });
      expect(forced.details).toMatchObject({
        kind: "file",
        mime: "application/octet-stream",
        bytes: ZIPISH.length,
      });
    });

    test("binary over 50 MiB cap → shown:false 'too large'", async () => {
      const path = join(dir, "huge.zip");
      // 51 MiB of zeros — size check fires for kind=file before any read.
      writeFileSync(path, Buffer.alloc(51 * 1024 * 1024));

      const tool = captureShowFileTool();
      const result = await tool.execute("call-bin-cap", { path });

      expect(result.details?.shown).toBe(false);
      expect(result.details?.error as string).toContain("too large");
      rmSync(path, { force: true });
    });
  });
});
