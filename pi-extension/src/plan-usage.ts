/**
 * Plan/156 — model subscription usage probes.
 *
 * Coding-plan subscriptions (z.ai GLM Coding Plan today) meter usage in
 * rolling windows, and the only place that state is visible today is the
 * provider's web dashboard. This module turns the provider's quota API
 * into a small normalized blob (`PlanUsage`) that main.ts publishes as
 * opaque `room_meta.plan_usage`, so the app can paint it on the grouped
 * Home header without knowing anything about provider APIs.
 *
 * Design rules:
 * - The API key NEVER leaves this module's input: only the normalized
 *   usage blob goes on the wire (and into logs — errors are message-only).
 * - Parsing is defensive: every field is optional-checked, unknown window
 *   shapes degrade to a generic label instead of throwing.
 * - Quota is best-effort decoration: a failing probe is swallowed by the
 *   caller (main.ts), never a red state for the session.
 */

import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

/** One decoded quota window. `kind` groups lanes (prompts vs MCP credits). */
export type PlanUsageWindow = {
  kind: "tokens" | "time";
  /** Stable short label: "5h", "wk", "mo"; generic fallback otherwise. */
  label: string;
  /** Used percent, clamped 0..100. */
  percent: number;
  /** Window length in minutes when decodable, else null. */
  minutes: number | null;
  /** Next reset, epoch ms. Null when absent or implausibly far out. */
  resetAt: number | null;
  used: number | null;
  limit: number | null;
};

/** Reset-card kind on the wire (app → pi). Matches z.ai's resetType. */
export type ResetCardKind = "five_hour" | "week";

/** Available reset cards per kind (plan/157). Counts only + earliest expiry
 * for the confirm dialog — the recordId NEVER leaves the extension (the
 * redemption picks a fresh card server-side at click time). */
export type ResetCardInventory = {
  fiveHour: { count: number; earliestExpire: string | null };
  week: { count: number; earliestExpire: string | null };
};

/** Normalized subscription usage for one provider account. */
export type PlanUsage = {
  provider: string;
  plan: string | null;
  fetchedAt: number;
  windows: PlanUsageWindow[];
  /** Omitted when the inventory call failed (quota still publishes). */
  resetCards?: ResetCardInventory;
};

/** Probe contract: turn an API key into a normalized PlanUsage. */
export type PlanUsageProbe = (key: string, signal?: AbortSignal) => Promise<PlanUsage>;

/** z.ai window-length units (CodexBar-compatible decode). */
const UNIT_MINUTES: Record<number, number> = {
  1: 1440, // days
  3: 60, // hours
  5: 1, // minutes
  6: 10080, // weeks
};

const UNIT_SUFFIX: Record<number, string> = { 1: "d", 3: "h", 5: "m", 6: "w" };

/** z.ai's monthly-MCP-credits marker: TIME_LIMIT with unit=5 number=1. */
const MCP_MONTHLY_MINUTES = 30 * 24 * 60;

function windowLabel(type: string, minutes: number | null, raw: { unit: number; number: number }): string {
  if (minutes === 300) return "5h";
  if (minutes === 10080) return "wk";
  if (minutes === MCP_MONTHLY_MINUTES) return "mo";
  const suffix = UNIT_SUFFIX[raw.unit];
  if (suffix && raw.number > 0) return `${raw.number}${suffix}`;
  return type === "TIME_LIMIT" ? "mcp" : "quota";
}

/** Clamp a used percentage from counts when the API supplies them —
 * counts beat the API's own `percentage` (it can lag or round). */
function decodePercent(raw: {
  percentage?: unknown;
  usage?: unknown;
  currentValue?: unknown;
  remaining?: unknown;
}): number {
  const usage = typeof raw.usage === "number" && Number.isFinite(raw.usage) ? raw.usage : null;
  const current =
    typeof raw.currentValue === "number" && Number.isFinite(raw.currentValue) ? raw.currentValue : null;
  const remaining =
    typeof raw.remaining === "number" && Number.isFinite(raw.remaining) ? raw.remaining : null;
  let percent = typeof raw.percentage === "number" && Number.isFinite(raw.percentage) ? raw.percentage : null;
  if (usage !== null && usage > 0) {
    let used: number | null = null;
    if (remaining !== null) used = Math.max(usage - remaining, current ?? usage - remaining);
    else if (current !== null) used = current;
    if (used !== null) percent = (Math.max(0, Math.min(usage, used)) / usage) * 100;
  }
  if (percent === null) percent = 0;
  return Math.max(0, Math.min(100, Math.round(percent)));
}

/** A reset further out than the window length + 1 min skew is a lie —
 * drop it (the 5h window is known to report far-future resets). */
function plausiblResetAt(nextResetTime: unknown, minutes: number | null, now: number): number | null {
  if (typeof nextResetTime !== "number" || !Number.isFinite(nextResetTime) || nextResetTime <= 0) return null;
  if (minutes !== null && nextResetTime > now + (minutes + 1) * 60_000) return null;
  return nextResetTime;
}

interface ZaiLimitEntry {
  type?: unknown;
  unit?: unknown;
  number?: unknown;
  percentage?: unknown;
  usage?: unknown;
  currentValue?: unknown;
  remaining?: unknown;
  nextResetTime?: unknown;
}

/** Decode one z.ai `limits[]` entry; null when the shape is unusable. */
export function decodeZaiWindow(raw: ZaiLimitEntry, now: number): PlanUsageWindow | null {
  if (!raw || typeof raw !== "object") return null;
  const type = typeof raw.type === "string" ? raw.type : null;
  if (!type) return null;
  const unit = typeof raw.unit === "number" && Number.isInteger(raw.unit) ? raw.unit : null;
  const number_ = typeof raw.number === "number" && Number.isInteger(raw.number) ? raw.number : null;
  let minutes: number | null = null;
  if (unit !== null && number_ !== null && number_ > 0 && UNIT_MINUTES[unit] !== undefined) {
    minutes = number_ * UNIT_MINUTES[unit]!;
  }
  // The monthly MCP-credits lane reports unit=5 number=1 (which would decode
  // as "1 minute"); treat the marker as 30 days like every other consumer.
  if (type === "TIME_LIMIT" && unit === 5 && number_ === 1) minutes = MCP_MONTHLY_MINUTES;
  return {
    kind: type === "TIME_LIMIT" ? "time" : "tokens",
    label: windowLabel(type, minutes, { unit: unit ?? -1, number: number_ ?? -1 }),
    percent: decodePercent(raw),
    minutes,
    resetAt: plausiblResetAt(raw.nextResetTime, minutes, now),
    used: typeof raw.currentValue === "number" && Number.isFinite(raw.currentValue) ? raw.currentValue : null,
    limit:
      typeof raw.usage === "number" && Number.isFinite(raw.usage)
        ? raw.usage
        : typeof raw.remaining === "number" && Number.isFinite(raw.remaining)
          ? raw.remaining
          : null,
  };
}

/** Parse a z.ai quota/limit response body into a PlanUsage. Throws on
 * API-level failures (non-2xx envelope) so the caller can swallow. */
export function parseZaiQuotaBody(body: unknown, now: number): PlanUsage {
  const root = body as { success?: unknown; code?: unknown; msg?: unknown; data?: unknown } | null;
  if (
    !root ||
    typeof root !== "object" ||
    root.success !== true ||
    root.code !== 200
  ) {
    const msg = root && typeof root.msg === "string" ? root.msg : "invalid response";
    throw new Error(`z.ai quota API error: ${msg}`);
  }
  const data = root.data as
    | { limits?: unknown; planName?: unknown; level?: unknown; plan?: unknown }
    | null;
  if (!data || typeof data !== "object" || !Array.isArray(data.limits)) {
    throw new Error("z.ai quota API error: missing data.limits");
  }
  const windows = (data.limits as ZaiLimitEntry[])
    .map((entry) => decodeZaiWindow(entry, now))
    .filter((w): w is PlanUsageWindow => w !== null);
  const plan =
    typeof data.planName === "string" && data.planName
      ? data.planName
      : typeof data.level === "string" && data.level
        ? data.level
        : typeof data.plan === "string" && data.plan
          ? data.plan
          : null;
  return { provider: "zai", plan, fetchedAt: now, windows };
}

function zaiMonitorBase(): string {
  const raw = process.env["REMOTE_PI_ZAI_MONITOR_BASE"];
  if (raw && /^https:\/\/[^\s/$.?#]/i.test(raw)) return raw.replace(/\/+$/, "");
  return "https://api.z.ai";
}

/** z.ai GLM Coding Plan probe — GET /api/monitor/usage/quota/limit, plus
 * the reset-card inventory in parallel (plan/157). Card-list failures are
 * swallowed (quota still publishes, `resetCards` omitted); quota failures
 * throw as before. */
export const zaiPlanUsageProbe: PlanUsageProbe = async (key, signal) => {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  try {
    const [quota, cards] = await Promise.all([
      fetch(`${zaiMonitorBase()}/api/monitor/usage/quota/limit`, {
        headers: { authorization: `Bearer ${key}`, accept: "application/json" },
        signal: signal ?? controller.signal,
      }).then(async (res) => {
        if (!res.ok) throw new Error(`z.ai quota API error: HTTP ${res.status}`);
        return parseZaiQuotaBody(await res.json(), Date.now());
      }),
      fetchZaiResetCards(key, signal ?? controller.signal).catch(() => null),
    ]);
    if (cards) quota.resetCards = cards;
    return quota;
  } finally {
    clearTimeout(timeout);
  }
};

/** Provider id → probe. Adding a provider = one entry here (plan/156). */
export const planUsageProbes: Record<string, PlanUsageProbe> = {
  zai: zaiPlanUsageProbe,
};

// ── Plan/157: z.ai Quota Reset Cards ─────────────────────────────────────────

interface ZaiResetCard {
  recordId?: unknown;
  available?: unknown;
  expireTime?: unknown;
}

function availableCards(raw: unknown): ZaiResetCard[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter(
    (c): c is ZaiResetCard =>
      !!c && typeof c === "object" && (c as ZaiResetCard).available === true,
  );
}

/** "YYYY-MM-DD HH:MM:SS" lexicographic sort = chronological (GLMeter rule):
 * burn the earliest-expiring card first so none dies unused. */
function earliestExpire(cards: ZaiResetCard[]): string | null {
  let earliest: string | null = null;
  for (const c of cards) {
    if (typeof c.expireTime === "string" && c.expireTime) {
      if (earliest === null || c.expireTime < earliest) earliest = c.expireTime;
    }
  }
  return earliest;
}

/** Parse a customer-package-reset/list body into the inventory. Throws on
 * API-level failures so the caller can swallow (probe) or surface
 * (redemption) them. */
export function parseZaiResetCardBody(body: unknown): ResetCardInventory {
  const root = body as { success?: unknown; code?: unknown; msg?: unknown; data?: unknown } | null;
  if (!root || typeof root !== "object" || root.success !== true || root.code !== 200) {
    const msg = root && typeof root.msg === "string" ? root.msg : "invalid response";
    throw new Error(`z.ai reset-card API error: ${msg}`);
  }
  const data = root.data as { fiveHourResets?: unknown; weekResets?: unknown } | null;
  if (!data || typeof data !== "object") {
    throw new Error("z.ai reset-card API error: missing data");
  }
  const fiveHour = availableCards(data.fiveHourResets);
  const week = availableCards(data.weekResets);
  return {
    fiveHour: { count: fiveHour.length, earliestExpire: earliestExpire(fiveHour) },
    week: { count: week.length, earliestExpire: earliestExpire(week) },
  };
}

/** Read-only inventory (dev-safe; only ever called with the user's key). */
export async function fetchZaiResetCards(key: string, signal?: AbortSignal): Promise<ResetCardInventory> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  try {
    const res = await fetch(`${zaiMonitorBase()}/api/biz/customer-package-reset/list?targetType=PERSONAL`, {
      headers: { authorization: `Bearer ${key}`, accept: "application/json" },
      signal,
    });
    if (!res.ok) throw new Error(`z.ai reset-card API error: HTTP ${res.status}`);
    return parseZaiResetCardBody(await res.json());
  } finally {
    clearTimeout(timeout);
  }
}

export type ResetCardRedemption = {
  ok: boolean;
  /** Cards of the kind still available after the attempt. */
  remaining: number;
  /** Human-readable failure reason (null on success). Message-only — the
   * API key never appears here. */
  message: string | null;
};

/** Redeem ONE reset card (plan/157). Only ever invoked from the explicit
 * app button flow (`plan_reset_card_request`) — NEVER from timers,
 * thresholds, or the agent shell.
 *
 * Fresh inventory → earliest-expiring available card of the kind → POST
 * `use` with a one-shot uuid requestId. NO auto-retry: a failed POST is
 * reported; the user re-confirms explicitly for another attempt. */
export async function redeemZaiResetCard(
  key: string,
  kind: ResetCardKind,
): Promise<ResetCardRedemption> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 20_000);
  try {
    const res = await fetch(`${zaiMonitorBase()}/api/biz/customer-package-reset/list?targetType=PERSONAL`, {
      headers: { authorization: `Bearer ${key}`, accept: "application/json" },
      signal: controller.signal,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status} on reset-card list`);
    const root = (await res.json()) as { success?: unknown; data?: unknown };
    if (root.success !== true || !root.data || typeof root.data !== "object") {
      throw new Error("reset-card list rejected");
    }
    const data = root.data as { fiveHourResets?: unknown; weekResets?: unknown };
    const cards = availableCards(kind === "week" ? data.weekResets : data.fiveHourResets);
    if (cards.length === 0) {
      return { ok: false, remaining: 0, message: `no available ${kind} reset card` };
    }
    // Earliest lexicographic expireTime (GLMeter rule); ties → lowest recordId.
    const pick = [...cards].sort((a, b) => {
      const ea = typeof a.expireTime === "string" ? a.expireTime : "";
      const eb = typeof b.expireTime === "string" ? b.expireTime : "";
      if (ea !== eb) return ea < eb ? -1 : 1;
      return (a.recordId ?? 0) > (b.recordId ?? 0) ? 1 : -1;
    })[0]!;
    const recordId = pick.recordId;
    if (typeof recordId !== "number" || !Number.isInteger(recordId)) {
      return { ok: false, remaining: cards.length, message: "reset card missing recordId" };
    }
    const use = await fetch(`${zaiMonitorBase()}/api/biz/customer-package-reset/use`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${key}`,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({
        targetType: "PERSONAL",
        resetType: kind === "week" ? "WEEK" : "FIVE_HOUR",
        recordId,
        requestId: randomUUID(),
      }),
      signal: controller.signal,
    });
    const useBody = (await use.json().catch(() => null)) as {
      success?: unknown;
      msg?: unknown;
    } | null;
    const remaining = cards.length - 1;
    if (!use.ok || !useBody || useBody.success !== true) {
      const msg = useBody && typeof useBody.msg === "string" ? useBody.msg : `HTTP ${use.status}`;
      return { ok: false, remaining: cards.length, message: msg };
    }
    return { ok: true, remaining, message: null };
  } catch (err) {
    return { ok: false, remaining: 0, message: err instanceof Error ? err.message : String(err) };
  } finally {
    clearTimeout(timeout);
  }
}

const ENV_KEY_NAMES: Record<string, string[]> = {
  zai: ["ZAI_API_KEY", "Z_AI_API_KEY"],
};

/** Home root override convention shared with piperHomeDir (rooms_registry):
 * tests point it at a sandbox so nothing reads the developer's real ~/.pi. */
function piHomeRoot(): string {
  return process.env["REMOTE_PI_HOME"] || homedir();
}

/**
 * Resolve a provider API key: env first (explicit override), then Pi's
 * own credential store `~/.pi/agent/auth.json` (shape `{type:"api", key}`).
 * Returns null when nothing is configured — the caller treats the whole
 * plan-usage feature as absent for that provider.
 */
export async function readProviderApiKey(
  providerId: string,
  authJsonPath?: string,
): Promise<string | null> {
  for (const name of ENV_KEY_NAMES[providerId] ?? []) {
    const value = process.env[name];
    if (value && value.trim()) return value.trim();
  }
  const path = authJsonPath ?? join(piHomeRoot(), ".pi", "agent", "auth.json");
  try {
    const raw = JSON.parse(await readFile(path, "utf8")) as Record<string, unknown>;
    const entry = raw[providerId] as { key?: unknown } | null;
    if (entry && typeof entry === "object" && typeof entry.key === "string" && entry.key.trim()) {
      return entry.key.trim();
    }
  } catch {
    // missing/unreadable/malformed auth.json — no key configured
  }
  return null;
}
