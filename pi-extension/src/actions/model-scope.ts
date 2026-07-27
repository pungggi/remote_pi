/**
 * Plan/109 — read pi's `enabledModels` (global `~/.pi/settings.json`) and
 * replicate the core's scope resolution, so the app's model pickers show the
 * same scoped set as `/scoped-models` without re-implementing the full
 * `resolveModelScope` (which needs `minimatch`, not a direct dep here).
 *
 * Matching mirrors `model-resolver.ts`:
 *   - a pattern matches `provider/modelId` OR the bare `modelId`
 *   - case-insensitive
 *   - `*` / `?` are glob wildcards
 *   - an optional `:thinking` suffix is stripped before matching
 *
 * When `enabledModels` is unset/empty, every model is in scope (pi falls back
 * to the whole catalogue) — matching `/scoped-models` behaviour.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

interface PiGlobalSettings {
  enabledModels?: string[];
}

/** Read pi's global settings.json (~/.pi/settings.json). Best-effort. */
function readGlobalSettings(): PiGlobalSettings {
  try {
    const file = path.join(os.homedir(), ".pi", "settings.json");
    const raw = fs.readFileSync(file, "utf8");
    const parsed = JSON.parse(raw) as PiGlobalSettings;
    return parsed && Array.isArray(parsed.enabledModels) ? parsed : {};
  } catch {
    return {};
  }
}

/** Cache the patterns for the process lifetime (settings change = pi restart). */
let _cached: string[] | null = null;

/** Read + cache `enabledModels` from pi's global settings.json. */
export function readEnabledModels(): string[] {
  if (_testOverride !== undefined) return _testOverride ?? [];
  if (_cached === null) _cached = readGlobalSettings().enabledModels ?? [];
  return _cached;
}

/** Test-only override for `enabledModels` (avoids reading the developer's real
 *  settings.json). `undefined` = read the file (production); `[]` = no scope;
 *  `[...]` = explicit patterns. */
let _testOverride: string[] | null | undefined = undefined;
export function setEnabledModelsForTest(patterns: string[] | null | undefined): void {
  _testOverride = patterns;
  _cached = null;
}

/** Force a re-read (used by tests / after a settings edit in the same run). */
export function resetEnabledModelsCacheForTest(): void {
  _cached = null;
}

/** Convert a minimatch-style glob to a RegExp (`*`→.*, `?`→., rest escaped). */
function globToRegExp(pattern: string): RegExp {
  let re = "^";
  for (const ch of pattern) {
    if (ch === "*") re += ".*";
    else if (ch === "?") re += ".";
    else re += ch.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`${re}$`, "i");
}

/**
 * Does `(provider, modelId)` match any `patterns` entry? `patterns` undefined
 * or empty → true (no scope configured → everything in scope).
 */
export function modelInScope(provider: string, modelId: string, patterns?: string[] | null): boolean {
  if (!patterns || patterns.length === 0) return true;
  const fullId = `${provider}/${modelId}`;
  const fullLower = fullId.toLowerCase();
  const idLower = modelId.toLowerCase();
  return patterns.some((raw) => {
    // Strip an optional ":thinking" suffix (e.g. "anthropic/*:high").
    const p = raw.includes(":") ? raw.slice(0, raw.lastIndexOf(":")) : raw;
    if (!p) return false;
    if (!p.includes("*") && !p.includes("?")) {
      const pl = p.toLowerCase();
      return pl === fullLower || pl === idLower;
    }
    const re = globToRegExp(p);
    return re.test(fullId) || re.test(modelId);
  });
}
