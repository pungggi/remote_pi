/**
 * Pure image wire-format helpers — base64 validation, MIME sniffing from magic
 * bytes, extension/MIME mapping, dimension parsing, and payload decoding.
 *
 * Extracted from `src/index.ts` (god-file split, increment 1). Everything here
 * is stateless and side-effect free: no module-level mutable singletons, no
 * filesystem access. The stateful image pipeline (preview rendering, received-
 * image delivery, the `show_image`/`show_file` tool registrations) still lives
 * in `index.ts` and consumes these helpers.
 *
 * Named without the historical `_` prefix: in a dedicated module these ARE the
 * public API, not "private helpers" of a monolith.
 */

import { join } from "node:path";

// Upper bound on a decoded received-image payload. Shared with the stateful
// pipeline in index.ts (preview render + collect), so re-exported.
export const RECEIVED_IMAGE_MAX_BYTES = 10 * 1024 * 1024;

/** Is `code` a single valid base64 (RFC 4648 §4) alphabet character? */
export function isBase64Char(code: number): boolean {
  return (code >= 48 && code <= 57) // 0-9
    || (code >= 65 && code <= 90) // A-Z
    || (code >= 97 && code <= 122) // a-z
    || code === 43 // +
    || code === 47; // /
}

/** Strict RFC 4648 §4 base64: length a multiple of 4, valid alphabet, correct
 *  `=` padding. Rejects base64url (`-_`) and data URIs. */
export function isStrictBase64(data: string): boolean {
  if (data.length === 0 || data.length % 4 !== 0) return false;
  if (data.startsWith("=")) return false;

  const padding = data.endsWith("==") ? 2 : data.endsWith("=") ? 1 : 0;
  for (let i = 0; i < data.length; i += 1) {
    const code = data.charCodeAt(i);
    if (i >= data.length - padding) {
      if (code !== 61) return false;
      continue;
    }
    if (!isBase64Char(code)) return false;
  }

  return true;
}

/** File extension for a supported image MIME, or `undefined` if unsupported. */
export function imageExtension(mime: string): string | undefined {
  if (mime === "image/jpeg") return "jpg";
  if (mime === "image/png") return "png";
  if (mime === "image/webp") return "webp";
  if (mime === "image/gif") return "gif";
  return undefined;
}

/** Sanitise an arbitrary string into a filesystem-safe token. Falls back to
 *  `"message"` when the result would be empty. */
export function safeFilenameToken(value: string): string {
  return value
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "")
    || "message";
}

/** Deterministic preview-file path under `dir` for a given message + index. */
export function safePreviewPath(dir: string, messageId: string, index: number): string {
  return join(dir, `${safeFilenameToken(messageId)}-${index}.preview.png`);
}

/** Decode + size-validate an inbound base64 image payload. Returns the decoded
 *  bytes on success, or a human-readable reason on failure. Rejects data URIs,
 *  non-strict base64, unsupported MIME, and oversize payloads. */
export function decodeImagePayload(
  data: string,
  mime: string,
): { ok: true; decoded: Buffer; size: number } | { ok: false; reason: string } {
  if (!imageExtension(mime)) return { ok: false, reason: `unsupported mime: ${mime}` };
  if (data.startsWith("data:")) return { ok: false, reason: "data URI payloads are not supported" };
  if (!isStrictBase64(data)) return { ok: false, reason: "invalid base64 payload" };

  const padding = data.endsWith("==") ? 2 : data.endsWith("=") ? 1 : 0;
  const estimate = (data.length / 4) * 3 - padding;
  if (estimate > RECEIVED_IMAGE_MAX_BYTES) {
    return { ok: false, reason: `image too large (${estimate} bytes)` };
  }

  const decoded = Buffer.from(data, "base64");
  if (decoded.length === 0 || decoded.length > RECEIVED_IMAGE_MAX_BYTES) {
    return { ok: false, reason: `invalid decoded image size (${decoded.length} bytes)` };
  }

  return { ok: true, decoded, size: decoded.length };
}

/** Sniff an image MIME from magic bytes. Supports JPEG/PNG/GIF/WebP; returns
 *  `undefined` for anything else (including partial headers). */
export function sniffImageMime(bytes: Buffer): string | undefined {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "image/jpeg";
  }
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 &&
    bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a
  ) {
    return "image/png";
  }
  if (
    bytes.length >= 6 &&
    bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 &&
    bytes[3] === 0x38 && (bytes[4] === 0x37 || bytes[4] === 0x39) && bytes[5] === 0x61
  ) {
    return "image/gif";
  }
  if (
    bytes.length >= 12 &&
    bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50
  ) {
    return "image/webp";
  }
  return undefined;
}

/** Resolve MIME from the file extension, then trust magic bytes when present
 *  (extensions can lie). Rejects anything outside the image whitelist. */
export function mimeFromPathAndMagic(absPath: string, bytes: Buffer): string | undefined {
  const ext = absPath.toLowerCase().split(".").pop() ?? "";
  let byExt: string | undefined;
  switch (ext) {
    case "jpg": case "jpeg": byExt = "image/jpeg"; break;
    case "png": byExt = "image/png"; break;
    case "gif": byExt = "image/gif"; break;
    case "webp": byExt = "image/webp"; break;
    default: byExt = undefined;
  }
  const mime = sniffImageMime(bytes) ?? byExt;
  return mime && imageExtension(mime) ? mime : undefined;
}

/** Best-effort PNG/JPEG dimension read. WebP/GIF return undefined (the viewer
 *  doesn't need dims; InteractiveViewer sizes from the decoded bytes). */
export function imageDimensions(
  bytes: Buffer,
  mime: string,
): { width: number; height: number } | undefined {
  try {
    if (mime === "image/png" && bytes.length >= 24) {
      // IHDR: width (4 BE) at offset 16, height (4 BE) at offset 20.
      const width = bytes.readUInt32BE(16);
      const height = bytes.readUInt32BE(20);
      if (width > 0 && height > 0) return { width, height };
    }
    if (mime === "image/jpeg") {
      return jpegDimensions(bytes);
    }
  } catch {
    // best-effort — viewer works without dims
  }
  return undefined;
}

/** Scan JPEG segments for a SOF (Start Of Frame) marker and read its dims. */
export function jpegDimensions(bytes: Buffer): { width: number; height: number } | undefined {
  let i = 2; // skip SOI (FF D8)
  while (i + 1 < bytes.length) {
    if (bytes[i] !== 0xff) break;
    const marker = bytes[i + 1];
    // Standalone markers (no length payload): RSTn, TEM, SOI, EOI.
    if (marker === 0xd8 || marker === 0xd9 || marker === 0x01 ||
        (marker >= 0xd0 && marker <= 0xd7)) {
      i += 2;
      continue;
    }
    if (i + 3 >= bytes.length) break;
    const segLen = bytes.readUInt16BE(i + 2);
    const isSof = marker >= 0xc0 && marker <= 0xcf &&
      marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSof) {
      // [marker(2)] [len(2)] [precision(1)] [height(2 BE)] [width(2 BE)]
      if (i + 9 <= bytes.length) {
        const height = bytes.readUInt16BE(i + 5);
        const width = bytes.readUInt16BE(i + 7);
        if (width > 0 && height > 0) return { width, height };
      }
      return undefined;
    }
    if (segLen < 2) break; // malformed — avoid infinite loop
    i += 2 + segLen;
  }
  return undefined;
}
