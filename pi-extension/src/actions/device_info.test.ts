/**
 * Plan/173 A2 — `device_info_request`: host class, terminal kind and the
 * agents this device can start.
 */
import { describe, expect, test, vi } from "vitest";

vi.mock("../termux.js", () => ({ isTermux: vi.fn(() => false) }));
vi.mock("./agent_models.js", () => ({ probeAgy: vi.fn() }));
vi.mock("../version.js", () => ({ readPackageVersion: vi.fn(() => "0.11.0-test") }));

import { handleDeviceInfo, describeDevice, devicePlatformFor } from "./device_info.js";
import { probeAgy } from "./agent_models.js";
import { isTermux } from "../termux.js";
import type { ServerMessage } from "../protocol/types.js";

function fakeSender() {
  const sent: ServerMessage[] = [];
  return { send: (m: ServerMessage) => sent.push(m), sent };
}

describe("devicePlatformFor", () => {
  test("Termux wins over the platform it reports (node says linux/android there)", () => {
    expect(devicePlatformFor(true, "linux")).toBe("android");
    expect(devicePlatformFor(true, "android" as NodeJS.Platform)).toBe("android");
  });

  test("the desktop platforms map one to one, the rest is other", () => {
    expect(devicePlatformFor(false, "win32")).toBe("windows");
    expect(devicePlatformFor(false, "darwin")).toBe("macos");
    expect(devicePlatformFor(false, "linux")).toBe("linux");
    expect(devicePlatformFor(false, "freebsd" as NodeJS.Platform)).toBe("other");
  });
});

describe("describeDevice", () => {
  test("a Termux host with agy: android, tmux, both agents", async () => {
    vi.mocked(probeAgy).mockResolvedValue(true);
    const d = await describeDevice({
      termux: true,
      platform: "android" as NodeJS.Platform,
      label: "localhost",
      terminal: "tmux",
      version: "0.11.0",
    });
    expect(d).toEqual({
      ok: true,
      host: { platform: "android", label: "localhost", terminal: "tmux" },
      agents: ["pi", "agy"],
      version: "0.11.0",
    });
  });

  test("a PC without agy offers Pi only", async () => {
    vi.mocked(probeAgy).mockResolvedValue(false);
    const d = await describeDevice({
      termux: false,
      platform: "win32",
      label: "DESKTOP",
      terminal: "wt",
      version: "0.11.0",
    });
    expect(d).toMatchObject({ ok: true, agents: ["pi"], host: { platform: "windows", terminal: "wt" } });
  });

  test("a probe that throws leaves AGY unlisted and does not fail the answer", async () => {
    vi.mocked(probeAgy).mockRejectedValue(new Error("spawn failed"));
    const d = await describeDevice({
      termux: false,
      platform: "linux",
      label: "x",
      terminal: "none",
      version: "1",
    });
    expect(d).toMatchObject({ ok: true, agents: ["pi"] });
  });

  test("defaults come from the real detection functions", async () => {
    vi.mocked(isTermux).mockReturnValue(false);
    vi.mocked(probeAgy).mockResolvedValue(false);
    const d = await describeDevice({ version: "9.9.9" });
    expect(d.ok).toBe(true);
    if (d.ok) {
      expect(d.host.platform).toBe(process.platform === "win32" ? "windows" : process.platform === "linux" ? "linux" : "macos");
      expect(["wt", "window", "none"]).toContain(d.host.terminal);
      expect(d.host.label.length).toBeGreaterThan(0);
    }
  });
});

describe("handleDeviceInfo", () => {
  test("replies device_info_result with the device's facts", async () => {
    vi.mocked(probeAgy).mockResolvedValue(true);
    const s = fakeSender();
    await handleDeviceInfo(s as never, { type: "device_info_request", id: "01J" }, {
      termux: true,
      platform: "linux",
      label: "phone",
      terminal: "tmux",
      version: "0.11.0",
    });
    expect(s.sent).toEqual([{
      type: "device_info_result",
      in_reply_to: "01J",
      ok: true,
      host: { platform: "android", label: "phone", terminal: "tmux" },
      agents: ["pi", "agy"],
      version: "0.11.0",
    }]);
  });

  test("a device that cannot describe itself answers ok:false with the reason", async () => {
    const s = fakeSender();
    await handleDeviceInfo(s as never, { type: "device_info_request", id: "01K" }, {
      termux: false,
      platform: "win32",
      version: "0.11.0",
      // Read inside describeDevice, so the throw happens in ITS try block.
      get terminal(): "wt" | "window" | "tmux" | "none" {
        throw new Error("launcher lookup failed");
      },
    });
    expect(s.sent).toEqual([{
      type: "device_info_result",
      in_reply_to: "01K",
      ok: false,
      agents: [],
      version: "0.11.0",
      message: "launcher lookup failed",
    }]);
  });
});
