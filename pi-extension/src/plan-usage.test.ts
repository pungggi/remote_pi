import { describe, test, expect, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  decodeZaiWindow,
  parseZaiQuotaBody,
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
