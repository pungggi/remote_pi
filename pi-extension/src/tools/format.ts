/**
 * Tool-result + message-content formatting helpers — enrich tool args for
 * display, stringify tool results / message content, and build edit-preview
 * hunks.
 *
 * Extracted from src/index.ts (god-file split). Pure string/file utilities
 * with no runtime state and no host dependencies.
 *
 * Named without the historical '_' prefix — module API, not private helpers.
 */

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { ext } from "../extension-state.js";

type ToolArgs = Record<string, unknown>;
type DiffLine =
  | { kind: "context"; oldLine?: number; newLine?: number; text: string }
  | { kind: "remove"; oldLine?: number; text: string }
  | { kind: "add"; newLine?: number; text: string }
  | { kind: "ellipsis" };

export function enrichToolArgs(tool: string, args: unknown): ToolArgs {
  if (!args || typeof args !== "object") return {};
  const base = args as ToolArgs;

  switch (tool.toLowerCase()) {
    case "edit":
      return enrichEditToolArgs(base);
    default:
      return base;
  }
}

function enrichEditToolArgs(base: ToolArgs): ToolArgs {
  const filePath = stringArg(base, ["path", "file_path"]);
  const rawEdits = base["edits"];
  const edits = Array.isArray(rawEdits) ? rawEdits : [base];
  const text = readToolFile(filePath);
  const hunks: { lines: DiffLine[] }[] = [];
  let searchFrom = 0;
  for (const rawEdit of edits) {
    if (!rawEdit || typeof rawEdit !== "object") continue;
    const edit = rawEdit as ToolArgs;
    const oldText = stringArg(edit, ["oldText", "old_text", "old_string", "oldString"]);
    const newText = stringArg(edit, ["newText", "new_text", "new_string", "newString"]);
    if (!oldText && !newText) continue;

    const matchAt = oldText && text !== null ? text.indexOf(oldText, searchFrom) : -1;
    const fallbackAt = oldText && matchAt < 0 && text !== null ? text.indexOf(oldText) : matchAt;
    const startOffset = fallbackAt >= 0 ? fallbackAt : searchFrom;
    if (text === null) continue;
    const hunk = buildEditHunk(text, startOffset, oldText, newText);
    if (hunk.length > 0) hunks.push({ lines: hunk });
    searchFrom = startOffset + Math.max(oldText.length, 1);
  }

  return hunks.length === 0 ? base : { ...base, hunks };
}

function readToolFile(filePath: string): string | null {
  if (!filePath) return null;
  const cwd = ext.lastCtx && "cwd" in ext.lastCtx ? ext.lastCtx.cwd : process.cwd();
  const homePath = filePath.startsWith("~/") && process.env.HOME
    ? resolve(process.env.HOME, filePath.slice(2))
    : null;
  const candidates = [filePath, resolve(cwd, filePath), resolve(process.cwd(), filePath), homePath]
    .filter((p): p is string => typeof p === "string");
  for (const candidate of candidates) {
    try {
      return readFileSync(candidate, "utf8");
    } catch {
      // try next candidate
    }
  }
  return null;
}


function buildEditHunk(
  fileText: string,
  startOffset: number,
  oldText: string,
  newText: string,
): DiffLine[] {
  const context = 4;
  const fileLines = fileText.split("\n");
  const oldLines = splitPreviewLines(oldText);
  const newLines = splitPreviewLines(newText);
  const oldStart = lineNumberAt(fileText, startOffset);
  const newStart = oldStart;
  const startIndex = oldStart - 1;
  const beforeStart = Math.max(0, startIndex - context);
  const afterStart = startIndex + oldLines.length;
  const afterEnd = Math.min(fileLines.length, afterStart + context);
  const out: DiffLine[] = [];

  if (beforeStart > 0) out.push({ kind: "ellipsis" });
  for (let i = beforeStart; i < startIndex; i++) {
    out.push({ kind: "context", oldLine: i + 1, newLine: i + 1, text: fileLines[i] ?? "" });
  }
  let commonPrefix = 0;
  while (
    commonPrefix < oldLines.length &&
    commonPrefix < newLines.length &&
    oldLines[commonPrefix] === newLines[commonPrefix]
  ) {
    commonPrefix++;
  }

  let commonSuffix = 0;
  while (
    commonSuffix < oldLines.length - commonPrefix &&
    commonSuffix < newLines.length - commonPrefix &&
    oldLines[oldLines.length - 1 - commonSuffix] === newLines[newLines.length - 1 - commonSuffix]
  ) {
    commonSuffix++;
  }

  for (let i = 0; i < commonPrefix; i++) {
    out.push({ kind: "context", oldLine: oldStart + i, newLine: newStart + i, text: oldLines[i] ?? "" });
  }
  for (let i = commonPrefix; i < oldLines.length - commonSuffix; i++) {
    out.push({ kind: "remove", oldLine: oldStart + i, text: oldLines[i] ?? "" });
  }
  for (let i = commonPrefix; i < newLines.length - commonSuffix; i++) {
    out.push({ kind: "add", newLine: newStart + i, text: newLines[i] ?? "" });
  }
  for (let i = oldLines.length - commonSuffix; i < oldLines.length; i++) {
    const newLine = newStart + newLines.length - (oldLines.length - i);
    out.push({ kind: "context", oldLine: oldStart + i, newLine, text: oldLines[i] ?? "" });
  }
  for (let i = afterStart; i < afterEnd; i++) {
    const newLine = newStart + newLines.length + (i - afterStart);
    out.push({ kind: "context", oldLine: i + 1, newLine, text: fileLines[i] ?? "" });
  }
  if (afterEnd < fileLines.length) out.push({ kind: "ellipsis" });
  return out;
}

function lineNumberAt(text: string, offset: number): number {
  let line = 1;
  for (let i = 0; i < Math.max(0, offset); i++) if (text[i] === "\n") line++;
  return line;
}

function splitPreviewLines(text: string): string[] {
  if (!text) return [];
  const lines = text.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

function stringArg(args: ToolArgs, keys: string[]): string {
  for (const key of keys) {
    const value = args[key];
    if (typeof value === "string") return value;
  }
  return "";
}

export function stringifyContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((c) => {
      if (!c || typeof c !== "object") return "";
      const block = c as { type?: string; text?: unknown };
      return block.type === "text" ? String(block.text ?? "") : "";
    })
    .join("");
}

/**
 * Stringify a tool result consistently for BOTH the live `tool_execution_end`
 * broadcast AND the history mapper, so the app shows the same text live and on
 * re-sync. The SDK's `ToolExecutionEndEvent.result` is `any` — usually a
 * content-array of `{type:"text"}` blocks; `String()` on that yields the
 * "[object Object]" bug. Rules: string → as-is; content-array → join its text
 * (same as `stringifyContent`); any other object → readable JSON; other
 * primitives → `String()`; null/undefined → "". Never "[object Object]".
 */
export function stringifyToolResult(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return stringifyContent(value);
  if (value !== null && typeof value === "object") {
    // The LIVE `tool_execution_end` result is a WRAPPER object
    // `{ content: [{type:"text",...}], details:{} }` — not the bare
    // content-array the history path (`m.content`) carries. Unwrap `content`
    // (or a plain `text`) so live == re-sync; JSON is only the last fallback.
    const obj = value as { content?: unknown; text?: unknown };
    if (Array.isArray(obj.content)) return stringifyContent(obj.content);
    if (typeof obj.text === "string") return obj.text;
    try { return JSON.stringify(value); } catch { return ""; }
  }
  return value === null || value === undefined ? "" : String(value);
}
