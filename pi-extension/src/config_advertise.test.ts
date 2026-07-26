import { describe, test, expect, vi, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { tmpdir } from "node:os";

/**
 * `resolveAdvertisedRelayUrl` reads `~/.pi/piper/config.json`, so each test
 * needs its own home. `homedir` is read when config.ts computes CONFIG_DIR at
 * module load, which means the mock has to be installed before the import and
 * the home has to stay fixed for the whole file — per-test isolation comes
 * from rewriting the file underneath it instead.
 *
 * ESM namespaces cannot be spied on, so `node:os` is stubbed the way
 * lan.test.ts does it.
 */
const HOME = fs.mkdtempSync(path.join(tmpdir(), "remote-pi-config-"));
const CONFIG_FILE = path.join(HOME, ".pi", "piper", "config.json");

vi.mock("node:os", async (importOriginal) => {
  const orig = await importOriginal<typeof import("node:os")>();
  const patched = { ...orig, homedir: () => HOME };
  // config.ts uses `import os from "node:os"`, so the default export has to be
  // patched too — a named-only mock silently leaves `os.homedir()` real and
  // the tests then read the developer's actual ~/.pi/piper/config.json.
  return { ...patched, default: patched };
});

const { resolveAdvertisedRelayUrl, resolveRelayUrl } = await import("./config.js");

/** Stands in for `lan.ts`'s loopback→LAN rewrite without touching interfaces. */
const rewrite = (url: string): string | null =>
  url.includes("127.0.0.1") ? url.replace("127.0.0.1", "192.168.1.42") : url;

/** The rewrite on a machine with no LAN address at all. */
const noLan = (url: string): string | null =>
  url.includes("127.0.0.1") ? null : url;

function writeConfig(cfg: Record<string, string>): void {
  fs.mkdirSync(path.dirname(CONFIG_FILE), { recursive: true });
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg));
}

beforeEach(() => {
  fs.rmSync(CONFIG_FILE, { force: true });
  delete process.env["REMOTE_PI_ADVERTISE"];
  delete process.env["REMOTE_PI_RELAY"];
});

afterEach(() => {
  delete process.env["REMOTE_PI_ADVERTISE"];
  delete process.env["REMOTE_PI_RELAY"];
});

describe("resolveAdvertisedRelayUrl", () => {
  test("defaults to the relay URL rewritten for the phone", () => {
    // plan/102: loopback relay, QR carries this machine's LAN address.
    expect(resolveAdvertisedRelayUrl(rewrite)).toBe("http://192.168.1.42:3000");
  });

  test("returns null when the relay is loopback and there is no LAN address", () => {
    // Wi-Fi down or only virtual interfaces — the caller must emit a QR
    // without `r` rather than advertise something unreachable.
    expect(resolveAdvertisedRelayUrl(noLan)).toBeNull();
  });

  test("config `advertise` overrides the rewrite", () => {
    writeConfig({ advertise: "http://100.81.166.99:3000" });
    expect(resolveAdvertisedRelayUrl(rewrite)).toBe("http://100.81.166.99:3000");
  });

  test("REMOTE_PI_ADVERTISE beats the config file", () => {
    writeConfig({ advertise: "http://from-config:3000" });
    process.env["REMOTE_PI_ADVERTISE"] = "http://from-env:3000";
    expect(resolveAdvertisedRelayUrl(rewrite)).toBe("http://from-env:3000");
  });

  test("coerces ws(s):// to the canonical http(s):// form", () => {
    process.env["REMOTE_PI_ADVERTISE"] = "wss://overlay.test";
    expect(resolveAdvertisedRelayUrl(rewrite)).toBe("https://overlay.test");
  });

  test("an overridden advertise address does not move this process off loopback", () => {
    // The whole point of the split: the phone dials the overlay, this process
    // keeps the loopback route, so a stopped VPN daemon cannot take the local
    // connection down with it.
    writeConfig({ advertise: "http://100.81.166.99:3000" });
    expect(resolveRelayUrl().url).toBe("http://127.0.0.1:3000");
    expect(resolveRelayUrl().source).toBe("default");
    expect(resolveAdvertisedRelayUrl(rewrite)).toBe("http://100.81.166.99:3000");
  });

  test("a configured non-loopback relay is advertised as-is when nothing overrides", () => {
    writeConfig({ relay: "https://relay.example.com" });
    expect(resolveAdvertisedRelayUrl(rewrite)).toBe("https://relay.example.com");
  });
});
