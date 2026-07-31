/**
 * Image + document pipeline — the show_image / show_file tools, the received-
 * image preview renderer, and the context-filter helpers.
 *
 * Extracted from src/index.ts (god-file split). Reaches shared runtime state
 * via `ext` (extension-state.ts) and the pure codec helpers via ./codec.ts.
 * The two cross-cutting concerns it still needs from the host (broadcasting to
 * connected owners + "is any peer active?") are injected through
 * ImagePipelineDeps so this module has NO back-dependency on index.ts (which
 * would be an import cycle).
 *
 * Named without the historical `_` prefix — in a dedicated module these are
 * the module's API, not private helpers of a monolith.
 */

import { Type } from "typebox";
import { randomUUID } from "node:crypto";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import {
  chmodSync, existsSync, mkdtempSync, mkdirSync, readFileSync,
  statSync, unlinkSync, writeFileSync,
} from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { convertToPng } from "@earendil-works/pi-coding-agent";
import { Box, Container, Image, Text } from "@earendil-works/pi-tui";
import type { ClientMessage, ServerMessage } from "../protocol/types.js";
import type { ReceivedImageDetails } from "../extension-state.js";
import { ext } from "../extension-state.js";
import {
  RECEIVED_IMAGE_MAX_BYTES,
  decodeImagePayload,
  imageDimensions,
  imageExtension,
  mimeFromPathAndMagic,
  safeFilenameToken,
  safePreviewPath,
} from "./codec.js";

// ── Pipeline-owned constants (moved from index.ts) ────────────────────────────
const REMOTE_PI_RECEIVED_IMAGE_TYPE = "remote-pi:received-image";
const SHOW_IMAGE_MAX_BYTES = 4 * 1024 * 1024;
const SHOW_FILE_TEXT_MAX_BYTES = 1 * 1024 * 1024;
const SHOW_FILE_PDF_MAX_BYTES = 10 * 1024 * 1024;
const IMAGE_PREVIEW_MIME = "image/png";
const IMAGE_CACHE_PREFIX = "pi-app-";
export type ReceivedImagePreviewDelivery = "immediate" | "defer";

/** The user_message variant off the wire. */
type ClientUserMessage = Extract<ClientMessage, { type: "user_message" }>;

/** Cross-cutting concerns injected by the host (src/index.ts) to avoid a
 *  back-dependency / import cycle. */
export interface ImagePipelineDeps {
  /** Broadcast a ServerMessage to every connected owner. */
  broadcast: (msg: ServerMessage) => void;
  /** Is at least one paired owner currently connected? */
  anyPeerActive: () => boolean;
}

function imageCacheRootDir(): string {
  if (ext.imageCacheDir) {
    try { mkdirSync(ext.imageCacheDir, { recursive: true, mode: 0o700 }); } catch {}
    try { chmodSync(ext.imageCacheDir, 0o700); } catch {}
    return ext.imageCacheDir;
  }
  const dir = mkdtempSync(join(tmpdir(), IMAGE_CACHE_PREFIX));
  try { chmodSync(dir, 0o700); } catch {}
  ext.imageCacheDir = dir;
  return dir;
}

function cleanupPreviewFile(previewPath: string): void {
  try {
    if (existsSync(previewPath)) unlinkSync(previewPath);
  } catch {
    // best effort
  }
}

async function renderablePngPathFromImage(
  imageData: string,
  mime: string,
  previewPath: string,
): Promise<string | undefined> {
  if (mime === IMAGE_PREVIEW_MIME) return undefined;

  try {
    const converted = await convertToPng(imageData, mime);
    if (!converted || converted.mimeType !== IMAGE_PREVIEW_MIME || !converted.data) {
      return undefined;
    }

    const previewBytes = Buffer.from(converted.data, "base64");
    if (previewBytes.length === 0 || previewBytes.length > RECEIVED_IMAGE_MAX_BYTES) {
      return undefined;
    }

    try {
      writeFileSync(previewPath, previewBytes, { mode: 0o600 });
      try { chmodSync(previewPath, 0o600); } catch {}
      return previewPath;
    } catch {
      cleanupPreviewFile(previewPath);
    }
  } catch {
    cleanupPreviewFile(previewPath);
  }

  return undefined;
}

function sendReceivedImagePreviewNow(details: ReceivedImageDetails): void {
  if (!ext.pi) return;
  try {
    ext.pi.sendMessage<ReceivedImageDetails>({
      customType: REMOTE_PI_RECEIVED_IMAGE_TYPE,
      content: "",
      display: true,
      details,
    });
  } catch {
    // TUI preview is best-effort; skip on failure.
  }
}

export function shouldDeferReceivedImagePreview(): boolean {
  return ext.currentTurnId !== null || ext.myRoomMeta?.working === true;
}

function sendReceivedImagePreview(
  details: ReceivedImageDetails,
  delivery: ReceivedImagePreviewDelivery = "immediate",
): void {
  if (delivery === "defer" || shouldDeferReceivedImagePreview()) {
    ext.pendingReceivedImagePreviews.push(details);
    return;
  }
  sendReceivedImagePreviewNow(details);
}

export function flushPendingReceivedImagePreviews(): void {
  if (ext.pendingReceivedImagePreviews.length === 0) return;
  const pending = ext.pendingReceivedImagePreviews.splice(0);
  for (const details of pending) sendReceivedImagePreviewNow(details);
}

async function collectReceivedImagePreviews(msg: ClientUserMessage): Promise<ReceivedImageDetails[]> {
  if (!msg.images || msg.images.length === 0) return [];

  const previews: ReceivedImageDetails[] = [];
  const text = typeof msg.text === "string" ? msg.text : "";
  const dir = imageCacheRootDir();

  for (let i = 0; i < msg.images.length; i += 1) {
    const image = msg.images[i];
    const mime = typeof image?.mime === "string" ? image.mime : "unknown";

    if (!image || typeof image.data !== "string") {
      console.error(`[remote-pi] malformed image in message ${msg.id} index=${i}`);
      previews.push({
        messageId: msg.id,
        index: i,
        mime,
        ...(text ? { text } : {}),
        error: "malformed image payload",
        reason: "missing mime/data payload fields",
      });
      continue;
    }

    const decoded = decodeImagePayload(image.data, image.mime);
    if (!decoded.ok) {
      console.error(`[remote-pi] skipped image id=${msg.id} index=${i}: ${decoded.reason}`);
      previews.push({
        messageId: msg.id,
        index: i,
        mime: image.mime,
        ...(text ? { text } : {}),
        error: "invalid image payload",
        reason: decoded.reason,
      });
      continue;
    }

    const imgExt = imageExtension(image.mime);
    if (!imgExt) {
      console.error(`[remote-pi] unsupported image mime in message ${msg.id} index=${i}: ${image.mime}`);
      previews.push({
        messageId: msg.id,
        index: i,
        mime: image.mime,
        ...(text ? { text } : {}),
        error: "invalid image payload",
        reason: `unsupported mime: ${image.mime}`,
      });
      continue;
    }

    const filename = `${safeFilenameToken(msg.id)}-${i}.${imgExt}`;
    const path = join(dir, filename);

    try {
      writeFileSync(path, decoded.decoded, { mode: 0o600 });
      try { chmodSync(path, 0o600); } catch {}

      const previewPath =
        image.mime === IMAGE_PREVIEW_MIME
          ? undefined
          : await renderablePngPathFromImage(
              image.data,
              image.mime,
              safePreviewPath(dir, msg.id, i),
            );

      previews.push({
        messageId: msg.id,
        index: i,
        mime: image.mime,
        size: decoded.size,
        path,
        ...(previewPath ? { previewPath } : {}),
        ...(text ? { text } : {}),
      });
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      console.error(`[remote-pi] failed saving image id=${msg.id} index=${i}: ${detail}`);
      previews.push({
        messageId: msg.id,
        index: i,
        mime: image.mime,
        ...(text ? { text } : {}),
        path,
        error: "failed to save image",
        reason: detail,
      });
    }
  }

  return previews;
}

export async function emitReceivedImagePreviews(
  msg: ClientUserMessage,
  delivery: ReceivedImagePreviewDelivery = "immediate",
): Promise<void> {
  const previews = await collectReceivedImagePreviews(msg);
  for (const preview of previews) sendReceivedImagePreview(preview, delivery);
}

// ── Plan/114 — show_image tool (agent → user image) ───────────────────────
// The agent calls `show_image({path, caption?})` to push an image file from
// the repo to the paired mobile app (full-screen viewer). The handler reads
// + validates the file (MIME whitelist via magic bytes, hard 4 MiB cap),
// broadcasts an `agent_image` ServerMessage with inline base64 to every
// connected owner, and returns ONLY metadata to the model — the image bytes
// never enter the model context (same discipline as plan/49). The
// `agent_image` is a live broadcast (not a persisted SDK message and not
// added to `ext.messageBuffer`), so it naturally never reaches a provider request
// and is not replayed via `session_history` (gap noted in plan/114 risk #2).

interface ShowImageResult {
  shown: boolean;
  path: string;
  mime?: string;
  width?: number;
  height?: number;
  bytes?: number;
  reason?: string;
  error?: string;
}

/** Sniff the image MIME from magic bytes. Returns undefined for non-images or
 *  truncated headers. */
/** Build a `shown:false` tool_result for a failure. The `path` argument MUST be
 *  the agent-supplied `rawPath` (never the resolved `absPath`) so absolute
 *  filesystem paths never leak into model context — see plan/114 review. */
function showImageError(
  error: string,
  path: string,
): { content: { type: "text"; text: string }[]; details: ShowImageResult } {
  return {
    content: [{ type: "text", text: `show_image failed: ${error}` }],
    details: { shown: false, path, error },
  };
}

/** Core handler for the `show_image` tool: read, validate, broadcast, reply. */
function handleShowImage(
  params: { path: string; caption?: string },
  deps: ImagePipelineDeps,
): { content: { type: "text"; text: string }[]; details: ShowImageResult } {
  const rawPath = typeof params.path === "string" ? params.path.trim() : "";
  const caption = typeof params.caption === "string" ? params.caption.trim() : "";
  if (!rawPath) {
    return showImageError("missing image path", "");
  }

  let absPath: string;
  try {
    absPath = resolve(rawPath);
  } catch {
    return showImageError(`invalid path: ${rawPath}`, rawPath);
  }

  let size: number;
  let bytes: Buffer;
  try {
    const s = statSync(absPath);
    if (!s.isFile()) {
      return showImageError(`not a regular file: ${rawPath}`, rawPath);
    }
    if (s.size > SHOW_IMAGE_MAX_BYTES) {
      return showImageError(
        `file too large (${s.size} bytes; max ${SHOW_IMAGE_MAX_BYTES})`,
        rawPath,
      );
    }
    bytes = readFileSync(absPath);
    size = s.size;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return showImageError(`cannot read ${rawPath}: ${msg}`, rawPath);
  }

  const mime = mimeFromPathAndMagic(absPath, bytes);
  if (!mime) {
    return showImageError(
      `unsupported image type (use jpeg/png/webp/gif): ${rawPath}`,
      rawPath,
    );
  }

  const dims = imageDimensions(bytes, mime);
  const data = bytes.toString("base64");

  // Broadcast to every connected owner — the app opens the viewer. Best-effort:
  // when no peer is attached the image is dropped (surfaced to the agent below).
  // `in_reply_to` anchors the bubble to the current turn (empty when the tool
  // is invoked outside any turn — rare).
  deps.broadcast({
    type: "agent_image",
    id: `img_${randomUUID()}`,
    in_reply_to: ext.currentTurnId ?? "",
    image: { data, mime },
    path: rawPath,
    ...(caption ? { caption } : {}),
    ...(dims ? { width: dims.width, height: dims.height } : {}),
  });

  const shown = deps.anyPeerActive();
  const details: ShowImageResult = {
    shown,
    path: rawPath,
    mime,
    bytes: size,
    ...(dims ? { width: dims.width, height: dims.height } : {}),
    ...(!shown ? { reason: "no active peer (no paired device connected)" } : {}),
  };
  const text = shown
    ? `Showing image to user: ${rawPath} (${mime}${dims ? `, ${dims.width}×${dims.height}` : ""}, ${size} bytes).`
    : `Image prepared (${rawPath}) but no paired device is connected right now — it was not displayed.`;
  return { content: [{ type: "text", text }], details };
}

export function registerShowImageTool(pi: ExtensionAPI, deps: ImagePipelineDeps): void {
  const ShowImageParams = Type.Object({
    path: Type.String({
      description:
        "Path to an image file in the repo, relative to the session cwd (or absolute). " +
        "Supported: JPEG, PNG, WebP, GIF. Hard cap 4 MiB.",
    }),
    caption: Type.Optional(Type.String({
      description:
        "Optional caption shown as a subtitle under the image bubble. " +
        "The repo path is used as the full-screen viewer title.",
    })),
  });

  pi.registerTool<typeof ShowImageParams, ShowImageResult>({
    name: "show_image",
    label: "Show image to user",
    description:
      "Display an image file from the repo to the user on their paired mobile app " +
      "(opens a full-screen viewer with pinch-zoom). Use when the user asks to " +
      "see/show an image, or when you want to present a chart, screenshot, or " +
      "diagram. The image bytes go directly to the app out-of-band; this tool " +
      "returns only metadata (path, mime, dimensions, size) — never the image " +
      "data — so it does not bloat the model context.",
    promptSnippet:
      "show_image({path, caption?}): display an image file from disk to the user on their phone (full-screen viewer). Returns metadata only.",
    parameters: ShowImageParams,
    execute: async (_toolCallId, params) =>
      handleShowImage(params as { path: string; caption?: string }, deps),
  });
}

// ── Plan/126 — show_file tool (agent → user document: md/text/pdf/html) ───
// Mirrors `show_image` for non-image files. The agent calls
// `show_file({ path, caption?, kind?, allowNetwork? })`; the handler detects
// the kind (markdown/text/pdf/html) by extension (explicit `kind` overrides),
// validates per-kind size caps + UTF-8 for text kinds, broadcasts an
// `agent_file` ServerMessage with inline base64 to every connected owner, and
// returns ONLY metadata to the model (same context-hygiene discipline as
// plan/49/114). HTML carries an `allow_network` flag so the app knows whether
// the WebView sandbox should permit remote resources (default: blocked).

type ShowFileKind = "markdown" | "text" | "pdf" | "html";

interface ShowFileResult {
  shown: boolean;
  kind?: ShowFileKind;
  path: string;
  mime?: string;
  bytes?: number;
  reason?: string;
  error?: string;
}

/** Extensions rendered as plain text/code in the TextViewer. Anything not in
 *  this set (and not md/markdown/html/pdf) is rejected by `show_file` rather
 *  than guessed — the agent passes `kind=` to force a rendering when needed. */
const SHOW_FILE_TEXT_EXTENSIONS = new Set<string>([
  "txt", "log", "csv", "tsv", "json", "json5", "yaml", "yml", "toml", "ini",
  "conf", "cfg", "env", "properties", "xml", "svg",
  // code
  "dart", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rs", "go", "java",
  "kt", "kts", "swift", "c", "h", "cpp", "hpp", "cc", "hh", "cs", "rb", "php",
  "sh", "bash", "zsh", "fish", "ps1", "psm1", "bat", "cmd", "sql", "graphql",
  "gql", "lua", "pl", "r", "scala", "clj", "cljs", "edn", "ex", "exs", "erl",
  "hs", "ml", "fs", "nim", "v", "zig", "gradle", "groovy", "sass", "scss",
  "css", "less", "vue", "svelte", "proto", "makefile", "dockerfile",
]);

/** Basenames treated as text when there's no extension (case-insensitive). */
const SHOW_FILE_TEXT_BASENAMES = new Set<string>([
  "readme", "license", "licence", "authors", "contributors", "changelog",
  "makefile", "dockerfile", "gemfile", "rakefile", "procfile", "editorconfig",
  "gitignore", "gitattributes", "npmrc", "yarnrc",
]);

/** Lowercased extension (chars after the last `.`), or "" when none. */
function extOf(absPath: string): string {
  const base = absPath.toLowerCase().split(/[\\/]/).pop() ?? "";
  const dot = base.lastIndexOf(".");
  return dot <= 0 ? "" : base.slice(dot + 1);
}

/** MIME that matches each kind — used for the wire `mime` + save/share type. */
function mimeForFileKind(kind: ShowFileKind): string {
  switch (kind) {
    case "markdown": return "text/markdown";
    case "text": return "text/plain";
    case "html": return "text/html";
    case "pdf": return "application/pdf";
  }
}

/** Detect the viewer kind from the path. Extension first; then dotfile /
 *  extension-less basenames. A leading-dot file (`.env`, `.gitignore`,
 *  `.editorconfig`) has no real extension so `extOf` returns "" — fall back to
 *  the dot-stripped stem and the common-text basename allowlist
 *  (Makefile, Dockerfile, README, ...). PDF is accepted by extension regardless
 *  of magic bytes (a truncated/corrupt PDF still renders as an error in the
 *  viewer, which is more useful than refusing). Returns undefined when the
 *  name is unknown — the agent can pass `kind=` to force it. */
function detectFileKind(absPath: string): ShowFileKind | undefined {
  const ext = extOf(absPath);
  if (ext === "md" || ext === "markdown") return "markdown";
  if (ext === "html" || ext === "htm" || ext === "xhtml") return "html";
  if (ext === "pdf") return "pdf";
  if (SHOW_FILE_TEXT_EXTENSIONS.has(ext)) return "text";
  const base = (absPath.toLowerCase().split(/[\\/]/).pop() ?? "");
  // Dotfiles have an empty extension — strip the leading dot and match the
  // stem against the extension + basename allowlists (`.env`→`env`,
  // `.gitignore`→`gitignore`, `.editorconfig`→`editorconfig`).
  const stem = base.startsWith(".") ? base.slice(1) : base;
  if (SHOW_FILE_TEXT_EXTENSIONS.has(stem) ||
      SHOW_FILE_TEXT_BASENAMES.has(stem) ||
      SHOW_FILE_TEXT_BASENAMES.has(base)) {
    return "text";
  }
  return undefined;
}

/** Strict UTF-8 validity check. Node's `Buffer.toString("utf8")` silently
 *  replaces bad bytes with U+FFFD, so we validate ourselves to reject binary
 *  files pushed as a text/markdown/html kind (the viewer would show garbage). */
function isValidUtf8(bytes: Buffer): boolean {
  let i = 0;
  const len = bytes.length;
  while (i < len) {
    const b0 = bytes[i++];
    if (b0 < 0x80) continue; // ASCII
    let n: number;
    let min: number;
    if ((b0 & 0xe0) === 0xc0) { n = 1; min = 0x80; }
    else if ((b0 & 0xf0) === 0xe0) { n = 2; min = 0x800; }
    else if ((b0 & 0xf8) === 0xf0) { n = 3; min = 0x10000; }
    else return false; // invalid lead byte
    if (i + n > len) return false; // truncated sequence
    let cp = b0 & (0x7f >> n);
    for (let k = 0; k < n; k++) {
      const b = bytes[i++];
      if ((b & 0xc0) !== 0x80) return false; // not a continuation byte
      cp = (cp << 6) | (b & 0x3f);
    }
    if (cp < min) return false; // overlong encoding
    if (cp >= 0xd800 && cp <= 0xdfff) return false; // UTF-16 surrogate
    if (cp > 0x10ffff) return false; // out of range
  }
  return true;
}

/** Build a `shown:false` tool_result for a failure. As with `show_image`, the
 *  `path` argument MUST be the agent-supplied `rawPath` (never the resolved
 *  `absPath`) so absolute filesystem paths never leak into model context. */
function showFileError(
  error: string,
  path: string,
): { content: { type: "text"; text: string }[]; details: ShowFileResult } {
  return {
    content: [{ type: "text", text: `show_file failed: ${error}` }],
    details: { shown: false, path, error },
  };
}

/** Core handler for the `show_file` tool: detect kind, read, validate, cap,
 *  broadcast, reply. Bytes never reach the model context (metadata only). */
function handleShowFile(
  params: { path: string; caption?: string; kind?: ShowFileKind; allowNetwork?: boolean },
  deps: ImagePipelineDeps,
): { content: { type: "text"; text: string }[]; details: ShowFileResult } {
  const rawPath = typeof params.path === "string" ? params.path.trim() : "";
  const caption = typeof params.caption === "string" ? params.caption.trim() : "";
  const overrideKind = params.kind;
  const allowNetwork = params.allowNetwork === true;
  if (!rawPath) {
    return showFileError("missing file path", "");
  }

  let absPath: string;
  try {
    absPath = resolve(rawPath);
  } catch {
    return showFileError(`invalid path: ${rawPath}`, rawPath);
  }

  let size: number;
  try {
    const s = statSync(absPath);
    if (!s.isFile()) {
      return showFileError(`not a regular file: ${rawPath}`, rawPath);
    }
    size = s.size;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return showFileError(`cannot read ${rawPath}: ${msg}`, rawPath);
  }

  // Determine kind: explicit override wins; else detect by extension (path
  // only — no bytes needed, so this runs before the file is read into memory).
  const kind: ShowFileKind | undefined = overrideKind ?? detectFileKind(absPath);
  if (!kind) {
    return showFileError(
      `unsupported/unknown file type — pass kind= explicitly, or use a known extension ` +
        `(md/markdown, txt/json/yaml/dart/ts/py/... code, html/htm, pdf): ${rawPath}`,
      rawPath,
    );
  }

  // Per-kind size cap (PDF may be large; text-y kinds small). Checked from
  // stat size BEFORE reading the file, so an oversized file is rejected
  // without ever being loaded into memory (mirrors show_image).
  const cap = kind === "pdf" ? SHOW_FILE_PDF_MAX_BYTES : SHOW_FILE_TEXT_MAX_BYTES;
  if (size > cap) {
    return showFileError(
      `file too large (${size} bytes; max ${cap} for kind ${kind})`,
      rawPath,
    );
  }

  let bytes: Buffer;
  try {
    bytes = readFileSync(absPath);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return showFileError(`cannot read ${rawPath}: ${msg}`, rawPath);
  }

  // Text-y kinds must decode as valid UTF-8 (reject binary pushed as text).
  if (kind !== "pdf" && !isValidUtf8(bytes)) {
    return showFileError(
      `${kind} file is not valid UTF-8 (binary) — use show_image for images or pass a different path: ${rawPath}`,
      rawPath,
    );
  }

  const mime = mimeForFileKind(kind);
  const data = bytes.toString("base64");

  // Broadcast to every connected owner — the app opens the right viewer.
  // `allow_network` is carried only for HTML (ignored by the app otherwise).
  deps.broadcast({
    type: "agent_file",
    id: `doc_${randomUUID()}`,
    in_reply_to: ext.currentTurnId ?? "",
    kind,
    data,
    mime,
    path: rawPath,
    size,
    ...(caption ? { caption } : {}),
    ...(kind === "html" && allowNetwork ? { allow_network: true } : {}),
  });

  const shown = deps.anyPeerActive();
  const details: ShowFileResult = {
    shown,
    kind,
    path: rawPath,
    mime,
    bytes: size,
    ...(!shown ? { reason: "no active peer (no paired device connected)" } : {}),
  };
  const netNote = kind === "html" ? (allowNetwork ? ", network allowed" : ", network blocked") : "";
  const text = shown
    ? `Showing ${kind} file to user: ${rawPath} (${mime}${netNote}, ${size} bytes).`
    : `File prepared (${rawPath}) but no paired device is connected right now — it was not displayed.`;
  return { content: [{ type: "text", text }], details };
}

export function registerShowFileTool(pi: ExtensionAPI, deps: ImagePipelineDeps): void {
  const ShowFileParams = Type.Object({
    path: Type.String({
      description:
        "Path to a file in the repo, relative to the session cwd (or absolute). " +
        "Markdown (.md/.markdown), plain text or code (.txt/.json/.yaml/.dart/.ts/.py/...), " +
        "PDF (.pdf), or HTML (.html/.htm). Size caps: 1 MiB for text/markdown/html, 10 MiB for PDF.",
    }),
    caption: Type.Optional(Type.String({
      description:
        "Optional subtitle shown under the bubble. The repo path is used as the viewer title.",
    })),
    kind: Type.Optional(Type.Union(
      [Type.Literal("markdown"), Type.Literal("text"), Type.Literal("pdf"), Type.Literal("html")],
      { description: "Override auto-detection and force this viewer kind." },
    )),
    allowNetwork: Type.Optional(Type.Boolean({
      description:
        "HTML+JS only (kind=html). Default false: JavaScript runs but ALL network is blocked " +
        "(remote <script>/<img>/css, fetch, XHR, websockets) — a safe sandbox. Set true to allow " +
        "remote resources for trusted content. Ignored for non-html kinds.",
    })),
  });

  pi.registerTool<typeof ShowFileParams, ShowFileResult>({
    name: "show_file",
    label: "Show file to user",
    description:
      "Display a document file from the repo to the user on their paired mobile app — " +
      "Markdown, plain text/code, PDF, or HTML (with JavaScript). Each opens the right " +
      "full-screen viewer. Use when the user asks to see/read/open a file that is not an " +
      "image (use show_image for images). The file bytes go directly to the app out-of-band; " +
      "this tool returns only metadata (kind, path, mime, size) — never the content — so it " +
      "does not bloat the model context. For HTML, JavaScript always runs; network is blocked " +
      "unless you pass allowNetwork:true.",
    promptSnippet:
      "show_file({path, caption?, kind?, allowNetwork?}): display a Markdown/text/PDF/HTML file " +
      "from disk to the user on their phone (full-screen viewer). HTML runs JS; network blocked " +
      "unless allowNetwork. Returns metadata only.",
    parameters: ShowFileParams,
    execute: async (_toolCallId, params) =>
      handleShowFile(params as {
        path: string;
        caption?: string;
        kind?: ShowFileKind;
        allowNetwork?: boolean;
      }, deps),
  });
}

export function registerReceivedImageRenderer(pi: ExtensionAPI): void {
  pi.registerMessageRenderer<ReceivedImageDetails>(
    REMOTE_PI_RECEIVED_IMAGE_TYPE,
    (message, _options, theme) => {
      const details = (message.details ?? {}) as Partial<ReceivedImageDetails>;
      const path = typeof details.path === "string" ? details.path : "";
      const previewPath = typeof details.previewPath === "string" ? details.previewPath : "";
      const mime = typeof details.mime === "string" ? details.mime : "application/octet-stream";
      const inlineImagePath = previewPath.length > 0
        ? previewPath
        : (mime === IMAGE_PREVIEW_MIME ? path : "");
      const size = typeof details.size === "number" ? details.size : undefined;
      const index = typeof details.index === "number" ? details.index : undefined;
      const text = typeof details.text === "string" ? details.text.trim() : "";
      const messageId = typeof details.messageId === "string" ? details.messageId : "unknown";
      const error = typeof details.error === "string" ? details.error : undefined;
      const reason = typeof details.reason === "string" ? details.reason : undefined;

      const label = `📷 Photo from Android (${messageId}${index !== undefined ? ` #${index}` : ""})`;
      const lines = [
        theme.fg("customMessageLabel", label),
        theme.fg("customMessageText", `Saved: ${path || "(not saved)"}`),
      ];
      if (size !== undefined) lines.push(theme.fg("customMessageText", `Size: ${size} bytes`));
      if (mime) lines.push(theme.fg("customMessageText", `MIME: ${mime}`));
      if (error) lines.push(theme.fg("customMessageText", `Error: ${error}`));
      if (reason) lines.push(theme.fg("customMessageText", `Reason: ${reason}`));
      if (text) lines.push(theme.fg("customMessageText", `Text: ${text}`));

      const container = new Container();
      const metadata = new Box(1, 1, (line) => theme.bg("customMessageBg", line));
      metadata.addChild(new Text(lines.join("\n")));
      container.addChild(metadata);

      if (inlineImagePath && !error) {
        try {
          const imageData = readFileSync(inlineImagePath).toString("base64");
          if (imageData.length > 0) {
            const image = new Image(imageData, IMAGE_PREVIEW_MIME, {
              fallbackColor: (str) => theme.fg("customMessageText", str),
            });
            // Keep Kitty image rows out of Box padding/background so pi-tui can
            // preserve the empty reserved rows that make inline images visible.
            container.addChild(image);
          }
        } catch {
          // Keep the metadata-only fallback on any IO/terminal issue.
        }
      }

      return container;
    },
  );
}

function isReceivedImageContextMessage(message: unknown): boolean {
  return typeof message === "object"
    && message !== null
    && (message as { role?: unknown }).role === "custom"
    && (message as { customType?: unknown }).customType === REMOTE_PI_RECEIVED_IMAGE_TYPE;
}

export function filterReceivedImageMessagesFromContext<T>(messages: T[] | undefined): T[] {
  return Array.isArray(messages)
    ? messages.filter((message) => !isReceivedImageContextMessage(message))
    : [];
}

export function contentFromUserMessage(
  msg: ClientUserMessage,
): Parameters<ExtensionAPI["sendUserMessage"]>[0] {
  return msg.images && msg.images.length > 0
    ? [
        ...msg.images.map((img) => ({ type: "image" as const, data: img.data, mimeType: img.mime })),
        { type: "text" as const, text: msg.text },
      ]
    : msg.text;
}

