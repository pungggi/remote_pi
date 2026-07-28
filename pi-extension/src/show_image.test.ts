/**
 * Plan/114 — unit tests for the `show_image` tool's validation + metadata.
 *
 * These run the extension factory against a tool-capturing mock and invoke the
 * captured `show_image` tool's `execute` directly. With no paired peer,
 * `_anyPeerActive()` is false so every result reports `shown:false` — but the
 * validation decisions (MIME whitelist, size cap, dimension read) and the
 * metadata-only tool_result shape (NO base64) are fully exercised here. The
 * live broadcast-to-peer path is covered by an integration test in
 * `extension.test.ts` (mirrors the `agent_chunk broadcasts` test).
 */
import { describe, expect, test, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionFactory } from "@earendil-works/pi-coding-agent";

const indexModule = await import("./index.js");
const extension = indexModule.default as ExtensionFactory;

// A captured tool definition — mirrors the subset of the SDK's
// `ToolDefinition` that `registerTool` receives.
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

function captureShowImageTool(): CapturedTool {
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
  const tool = tools.find((t) => t.name === "show_image");
  if (!tool) throw new Error("show_image tool was not registered");
  return tool;
}

// Well-known 67-byte 1×1 RGB PNG (IHDR width/height = 1 at offsets 16/20).
const PNG_1x1 = Buffer.from(
  "89504e470d0a1a0a0000000d4948445200000001000000010802000000907753de" +
  "0000000c4944415408d763f8cfc0000000030001cebeb32b0000000049454e44ae426082",
  "hex",
);

// Minimal valid JPEG: SOI + APP0(JFIF) + SOF0(height=2,width=3) + EOI.
// First 3 bytes FF D8 FF satisfy the magic-byte sniff; SOF0 carries the dims.
const JPEG_2x3 = Buffer.from([
  0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01,
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
  0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x02, 0x00, 0x03, 0x01, 0x01, 0x11, 0x00,
  0xff, 0xd9,
]);

function tmpDir(): string {
  return mkdtempSync(join(tmpdir(), "pi-show-image-"));
}

/** Asserts the tool_result carries NO base64 image data anywhere (plan/49
 *  discipline: bytes never enter the model context). */
function assertNoBase64Payload(result: {
  content?: { text?: string }[];
  details?: Record<string, unknown>;
}, pngData: string): void {
  const json = JSON.stringify(result);
  expect(json).not.toContain(pngData);
  if (result.details) {
    expect(result.details).not.toHaveProperty("data");
    expect(result.details).not.toHaveProperty("image");
  }
}

describe("show_image tool (plan/114)", () => {
  let dir: string;
  beforeEach(() => { dir = tmpDir(); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  test("valid PNG → metadata only (mime/dims/bytes), no base64 in result", async () => {
    const path = join(dir, "pixel.png");
    writeFileSync(path, PNG_1x1);
    const pngData = PNG_1x1.toString("base64");

    const tool = captureShowImageTool();
    const result = await tool.execute("call-1", { path });

    expect(result.details).toMatchObject({
      shown: false,
      path,
      mime: "image/png",
      width: 1,
      height: 1,
      bytes: PNG_1x1.length,
      reason: expect.stringContaining("no active peer"),
    });
    assertNoBase64Payload(result, pngData);
    // The textual content explains it was not displayed (no peer), not the image.
    expect(result.content?.[0]?.text).not.toContain(pngData);
  });

  test("valid JPEG → sniffs mime from magic bytes + reads SOF0 dims", async () => {
    const path = join(dir, "photo.jpeg");
    writeFileSync(path, JPEG_2x3);

    const tool = captureShowImageTool();
    const result = await tool.execute("call-2", { path });

    expect(result.details).toMatchObject({
      mime: "image/jpeg",
      width: 3,
      height: 2,
    });
  });

  test("unsupported file type (.txt) → shown:false with error, no base64", async () => {
    const path = join(dir, "notes.txt");
    writeFileSync(path, "this is not an image");

    const tool = captureShowImageTool();
    const result = await tool.execute("call-3", { path });

    expect(result.details?.shown).toBe(false);
    expect(typeof result.details?.error).toBe("string");
    expect(result.details?.error as string).toContain("unsupported image type");
  });

  test("nonexistent path → shown:false with read error", async () => {
    const tool = captureShowImageTool();
    const result = await tool.execute("call-4", { path: join(dir, "nope.png") });

    expect(result.details?.shown).toBe(false);
    expect(result.details?.error as string).toContain("cannot read");
  });

  test("file over 4 MiB cap → shown:false 'too large', rejected before decode", async () => {
    const path = join(dir, "huge.png");
    // 5 MiB of zeros — size check fires before mime/decode, so content is irrelevant.
    writeFileSync(path, Buffer.alloc(5 * 1024 * 1024));

    const tool = captureShowImageTool();
    const result = await tool.execute("call-5", { path });

    expect(result.details?.shown).toBe(false);
    expect(result.details?.error as string).toContain("too large");
  });

  test("missing path argument → shown:false 'missing image path'", async () => {
    const tool = captureShowImageTool();
    const result = await tool.execute("call-6", { path: "  " });

    expect(result.details?.shown).toBe(false);
    expect(result.details?.error as string).toContain("missing image path");
  });
});
