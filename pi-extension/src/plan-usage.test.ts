import { describe, test, expect, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  decodeZaiWindow,
  parseZaiQuotaBody,
  parseZaiResetCardBody,
  fetchZaiResetCards,
  redeemZaiResetCard,
  readProviderApiKey,
  planUsageProbes,
} from "./plan-usage.js";

/** Fixed clock for the reset-plausibility tests. */
const NOW = 1_790_000_000_000;

/** Byte-for-byte shape of the real 2026-11-01 response from the user's
 * Max plan (values only redacted where account-specific). Nothing here is
 * a secret: percentages, windows, and reset epochs are display data. */
const LIVE_MAX_BODY = {
  code: 200,
  msg: "Operation successful",
  success: true,
  data: {
    limits: [
      {
        type: "TIME_LIMIT",
        unit: 5,
        number: 1,
        usage: 4000,
        currentValue: 0,
        remaining: 4000,
        percentage: 0,
        nextResetTime: NOW + 25 * 24 * 3600_000,
        usageDetails: [
          { modelCode: "search-prime", usage: 0 },
          { modelCode: "web-reader", usage: 0 },
          { modelCode: "zread", usage: 0 },
        ],
      },
      {
        type: "TOKENS_LIMIT",
        unit: 3,
        number: 5,
        percentage: 3,
        nextResetTime: NOW + 2 * 3600_000,
      },
      {
        type: "TOKENS_LIMIT",
        unit: 6,
        number: 1,
        percentage: 4,
        nextResetTime: NOW + 6 * 24 * 3600_000,
      },
    ],
    level: "max",
  },
};

afterEach(() => {
  delete process.env["ZAI_API_KEY"];
  delete process.env["Z_AI_API_KEY"];
});

describe("decodeZaiWindow", () => {
  test("decodes the monthly MCP-credits marker (TIME_LIMIT unit=5 number=1)", () => {
    const w = decodeZaiWindow(LIVE_MAX_BODY.data.limits[0]!, NOW);
    expect(w).not.toBeNull();
    expect(w!.kind).toBe("time");
    expect(w!.label).toBe("mo");
    expect(w!.minutes).toBe(30 * 24 * 60);
    expect(w!.percent).toBe(0);
    // 25 days out is plausible for a 30-day window → reset survives.
    expect(w!.resetAt).toBe(NOW + 25 * 24 * 3600_000);
    expect(w!.limit).toBe(4000);
  });

  test("decodes the 5-hour prompts window (TOKENS_LIMIT unit=3 number=5)", () => {
    const w = decodeZaiWindow(LIVE_MAX_BODY.data.limits[1]!, NOW);
    expect(w!.kind).toBe("tokens");
    expect(w!.label).toBe("5h");
    expect(w!.minutes).toBe(300);
    expect(w!.percent).toBe(3);
    expect(w!.resetAt).toBe(NOW + 2 * 3600_000);
  });

  test("decodes the weekly window (unit=6 → 10080 min)", () => {
    const w = decodeZaiWindow(LIVE_MAX_BODY.data.limits[2]!, NOW);
    expect(w!.label).toBe("wk");
    expect(w!.minutes).toBe(10080);
    expect(w!.percent).toBe(4);
  });

  test("counts beat the API percentage when usage/remaining exist", () => {
    const w = decodeZaiWindow(
      { type: "TIME_LIMIT", unit: 5, number: 1, usage: 100, remaining: 25, percentage: 90 },
      NOW,
    );
    // 75 of 100 actually used → 75%, not the API's lagging 90.
    expect(w!.percent).toBe(75);
  });

  test("clamps computed percentages into 0..100", () => {
    const over = decodeZaiWindow(
      { type: "TIME_LIMIT", unit: 5, number: 1, usage: 100, currentValue: 140, percentage: 0 },
      NOW,
    );
    expect(over!.percent).toBe(100);
    const under = decodeZaiWindow(
      { type: "TIME_LIMIT", unit: 5, number: 1, usage: 100, currentValue: -5, percentage: 0 },
      NOW,
    );
    expect(under!.percent).toBe(0);
  });

  test("drops implausibly far-future resets beyond the window length", () => {
    // 5h window claiming a reset a day away → the API lies; drop it.
    const w = decodeZaiWindow(
      { type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: 10, nextResetTime: NOW + 24 * 3600_000 },
      NOW,
    );
    expect(w!.resetAt).toBeNull();
    // Same entry with a plausible 4h reset keeps it.
    const ok = decodeZaiWindow(
      { type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: 10, nextResetTime: NOW + 4 * 3600_000 },
      NOW,
    );
    expect(ok!.resetAt).toBe(NOW + 4 * 3600_000);
  });

  test("unknown unit degrades to a generic label, minutes null", () => {
    const w = decodeZaiWindow(
      { type: "TOKENS_LIMIT", unit: 9, number: 2, percentage: 7, nextResetTime: NOW },
      NOW,
    );
    expect(w!.minutes).toBeNull();
    expect(w!.label).toBe("quota");
    expect(w!.percent).toBe(7);
    // Unknown length ⇒ no plausibility bound ⇒ reset survives.
    expect(w!.resetAt).toBe(NOW);
  });

  test("non-object / typeless entries are skipped (null)", () => {
    expect(decodeZaiWindow(null, NOW)).toBeNull();
    expect(decodeZaiWindow({ unit: 3, number: 5, percentage: 1 }, NOW)).toBeNull();
  });
});

describe("parseZaiQuotaBody", () => {
  test("full body → provider zai, plan level, all three windows", () => {
    const usage = parseZaiQuotaBody(LIVE_MAX_BODY, NOW);
    expect(usage.provider).toBe("zai");
    expect(usage.plan).toBe("max");
    expect(usage.fetchedAt).toBe(NOW);
    expect(usage.windows.map((w) => w.label)).toEqual(["mo", "5h", "wk"]);
  });

  test("prefers planName over level when both exist", () => {
    const usage = parseZaiQuotaBody(
      { ...LIVE_MAX_BODY, data: { ...LIVE_MAX_BODY.data, planName: "GLM Coding Pro" } },
      NOW,
    );
    expect(usage.plan).toBe("GLM Coding Pro");
  });

  test("API-level failure envelopes throw (caller swallows)", () => {
    expect(() => parseZaiQuotaBody({ success: false, code: 500, msg: "no plan" }, NOW)).toThrow(
      /no plan/,
    );
    expect(() => parseZaiQuotaBody({ success: true, code: 200, data: {} }, NOW)).toThrow(
      /missing data.limits/,
    );
  });
});

describe("readProviderApiKey", () => {
  test("env wins over auth.json (ZAI_API_KEY, then Z_AI_API_KEY)", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "remote-pi-plan-usage-"));
    try {
      const authPath = join(tmp, "auth.json");
      writeFileSync(authPath, JSON.stringify({ zai: { type: "api", key: "file-key" } }));
      process.env["ZAI_API_KEY"] = "env-key";
      expect(await readProviderApiKey("zai", authPath)).toBe("env-key");
      delete process.env["ZAI_API_KEY"];
      process.env["Z_AI_API_KEY"] = "env2-key";
      expect(await readProviderApiKey("zai", authPath)).toBe("env2-key");
      delete process.env["Z_AI_API_KEY"];
      expect(await readProviderApiKey("zai", authPath)).toBe("file-key");
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  test("missing/blank/malformed sources resolve to null (feature absent)", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "remote-pi-plan-usage-"));
    try {
      expect(await readProviderApiKey("zai", join(tmp, "absent.json"))).toBeNull();
      const blank = join(tmp, "blank.json");
      writeFileSync(blank, JSON.stringify({ zai: { type: "api", key: "  " } }));
      expect(await readProviderApiKey("zai", blank)).toBeNull();
      const corrupt = join(tmp, "corrupt.json");
      writeFileSync(corrupt, "{not json");
      expect(await readProviderApiKey("zai", corrupt)).toBeNull();
      expect(await readProviderApiKey("unknown-provider", join(tmp, "absent.json"))).toBeNull();
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });
});

describe("planUsageProbes registry", () => {
  test("zai is registered; a probe fetch failure rejects (never resolves null)", async () => {
    expect(typeof planUsageProbes["zai"]).toBe("function");
    // No key material anywhere near this test: point the probe at an
    // unreachable base and expect a rejection the caller will swallow.
    process.env["REMOTE_PI_ZAI_MONITOR_BASE"] = "https://127.0.0.1:1";
    await expect(planUsageProbes["zai"]("test-key")).rejects.toBeInstanceOf(Error);
    delete process.env["REMOTE_PI_ZAI_MONITOR_BASE"];
  });
});

// ── Plan/157: reset cards ───────────────────────────────────────────────

/** Byte-shape of the verified 2026-11-02 list response (recordIds and
 * expiries redacted to synthetic values — shape is what matters). */
const LIST_BODY = {
  code: 200,
  msg: "Operation successful",
  success: true,
  data: {
    fiveHourResets: [],
    weekResets: [
      { recordId: 9, available: true, expireTime: "2026-12-22 23:59:59" },
      { recordId: 10, available: true, expireTime: "2026-12-01 23:59:59" },
      { recordId: 11, available: false, expireTime: "2026-12-22 23:59:59" },
    ],
  },
};

type FetchCall = { url: string; init?: RequestInit };

/** Swap global fetch for a URL router; returns the restore fn + captured
 * calls (so tests can assert which POSTs actually happened). */
function mockFetch(routes: Record<string, unknown>): { calls: FetchCall[]; restore: () => void } {
  const calls: FetchCall[] = [];
  const orig = globalThis.fetch;
  globalThis.fetch = ((url: string | URL, init?: RequestInit) => {
    const u = String(url);
    calls.push({ url: u, init });
    const path = u.split("?")[0]!;
    for (const [suffix, body] of Object.entries(routes)) {
      if (path.endsWith(suffix)) {
        if (body instanceof Error) return Promise.reject(body);
        return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response);
      }
    }
    return Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({}) } as Response);
  }) as typeof fetch;
  return {
    calls,
    restore: () => {
      globalThis.fetch = orig;
    },
  };
}

/** Decode the captured JSON bodies of all POSTs to a URL suffix. */
function postedBodies(mock: { calls: FetchCall[] }, suffix: string): Array<Record<string, unknown>> {
  return mock.calls
    .filter((c) => c.url.endsWith(suffix) && c.init?.method === "POST")
    .map((c) => JSON.parse(String(c.init?.body)) as Record<string, unknown>);
}

describe("parseZaiResetCardBody (plan/157)", () => {
  test("counts available cards only + earliest expiry", () => {
    const inv = parseZaiResetCardBody(LIST_BODY);
    expect(inv.fiveHour).toEqual({ count: 0, earliestExpire: null });
    expect(inv.week).toEqual({ count: 2, earliestExpire: "2026-12-01 23:59:59" });
  });

  test("API-level failure envelopes throw; missing data throws", () => {
    expect(() => parseZaiResetCardBody({ success: false, code: 500, msg: "denied" })).toThrow(
      /denied/,
    );
    expect(() => parseZaiResetCardBody({ success: true, code: 200 })).toThrow(/missing data/);
  });
});

describe("fetchZaiResetCards (plan/157)", () => {
  test("GET list → inventory", async () => {
    const mock = mockFetch({ "customer-package-reset/list": LIST_BODY });
    try {
      const inv = await fetchZaiResetCards("test-key");
      expect(inv.week.count).toBe(2);
      expect(mock.calls).toHaveLength(1);
      expect(mock.calls[0]!.url).toContain("customer-package-reset/list?targetType=PERSONAL");
    } finally {
      mock.restore();
    }
  });
});

describe("redeemZaiResetCard (plan/157)", () => {
  test("picks the earliest-expiring available card; POSTs use with fresh requestId", async () => {
    const mock = mockFetch({
      "customer-package-reset/list": LIST_BODY,
      "customer-package-reset/use": { success: true, code: 200 },
    });
    try {
      const r1 = await redeemZaiResetCard("test-key", "week");
      expect(r1).toEqual({ ok: true, remaining: 1, message: null });
      const uses = postedBodies(mock, "customer-package-reset/use");
      expect(uses).toHaveLength(1);
      expect(uses[0]).toMatchObject({
        targetType: "PERSONAL",
        resetType: "WEEK",
        recordId: 10, // 2026-12-01 expires before 2026-12-22
      });
      const requestId = uses[0]!["requestId"];
      expect(typeof requestId).toBe("string");
      expect(requestId).toMatch(/^[0-9a-f-]{36}$/i);

      // Second redemption → NEW requestId (one-shot idempotency rule).
      await redeemZaiResetCard("test-key", "week");
      const uses2 = postedBodies(mock, "customer-package-reset/use");
      expect(uses2).toHaveLength(2);
      expect(uses2[1]!["requestId"]).not.toBe(requestId);
    } finally {
      mock.restore();
    }
  });

  test("five_hour maps to resetType FIVE_HOUR", async () => {
    const mock = mockFetch({
      "customer-package-reset/list": {
        success: true,
        code: 200,
        data: {
          fiveHourResets: [{ recordId: 5, available: true, expireTime: "2026-12-01 00:00:00" }],
          weekResets: [],
        },
      },
      "customer-package-reset/use": { success: true, code: 200 },
    });
    try {
      const r = await redeemZaiResetCard("test-key", "five_hour");
      expect(r.ok).toBe(true);
      expect(postedBodies(mock, "customer-package-reset/use")[0]).toMatchObject({
        resetType: "FIVE_HOUR",
        recordId: 5,
      });
    } finally {
      mock.restore();
    }
  });

  test("no available card of the kind → failure, and NO use POST happens", async () => {
    const mock = mockFetch({
      "customer-package-reset/list": {
        success: true,
        code: 200,
        data: {
          fiveHourResets: [{ recordId: 3, available: false, expireTime: "2026-12-01 00:00:00" }],
          weekResets: [],
        },
      },
      "customer-package-reset/use": { success: true, code: 200 },
    });
    try {
      const r = await redeemZaiResetCard("test-key", "five_hour");
      expect(r.ok).toBe(false);
      expect(r.message).toMatch(/no available five_hour reset card/);
      expect(postedBodies(mock, "customer-package-reset/use")).toHaveLength(0);
    } finally {
      mock.restore();
    }
  });

  test("provider rejects the use call → ok:false with message, count intact", async () => {
    const mock = mockFetch({
      "customer-package-reset/list": LIST_BODY,
      "customer-package-reset/use": { success: false, code: 400, msg: "card expired" },
    });
    try {
      const r = await redeemZaiResetCard("test-key", "week");
      expect(r).toEqual({ ok: false, remaining: 2, message: "card expired" });
    } finally {
      mock.restore();
    }
  });

  test("list fetch fails → ok:false, never throws", async () => {
    const mock = mockFetch({ "customer-package-reset/list": new Error("ECONNRESET") });
    try {
      const r = await redeemZaiResetCard("test-key", "week");
      expect(r.ok).toBe(false);
      expect(r.message).toMatch(/ECONNRESET/);
    } finally {
      mock.restore();
    }
  });
});

describe("zaiPlanUsageProbe reset-card merge (plan/157)", () => {
  test("quota + inventory both succeed → resetCards present", async () => {
    const mock = mockFetch({
      "quota/limit": LIVE_MAX_BODY,
      "customer-package-reset/list": LIST_BODY,
    });
    try {
      const usage = await planUsageProbes["zai"]("test-key");
      expect(usage.windows).toHaveLength(3);
      expect(usage.resetCards).toEqual({
        fiveHour: { count: 0, earliestExpire: null },
        week: { count: 2, earliestExpire: "2026-12-01 23:59:59" },
      });
    } finally {
      mock.restore();
    }
  });

  test("inventory failure is swallowed → quota still publishes, field omitted", async () => {
    const mock = mockFetch({ "quota/limit": LIVE_MAX_BODY });
    try {
      const usage = await planUsageProbes["zai"]("test-key");
      expect(usage.windows).toHaveLength(3);
      expect(usage.resetCards).toBeUndefined();
    } finally {
      mock.restore();
    }
  });
});
