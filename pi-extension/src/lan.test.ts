import { describe, test, expect, vi, afterEach } from "vitest";

/** Shapes a `node:os` NetworkInterfaceInfo well enough for detectLanIPv4. */
function iface(address: string, opts: { internal?: boolean; family?: "IPv4" | "IPv6" } = {}) {
  return {
    address,
    netmask: "255.255.255.0",
    family: opts.family ?? ("IPv4" as const),
    mac: "00:00:00:00:00:00",
    internal: opts.internal ?? false,
    cidr: `${address}/24`,
  };
}

// `networkInterfaces` is read at call time, so a mutable holder lets each test
// set the machine's interfaces. ESM namespaces cannot be spied on, so the
// module is stubbed the way storage.test.ts does it — before the real load.
let _interfaces: Record<string, ReturnType<typeof iface>[]> = {};
vi.mock("node:os", async (importOriginal) => {
  const orig = await importOriginal<typeof import("node:os")>();
  return { ...orig, networkInterfaces: () => _interfaces };
});

// Re-import after the mock is installed.
const { isPrivateIPv4, isLoopbackUrl, toPhoneReachableUrl, detectLanIPv4 } =
  await import("./lan.js");

afterEach(() => {
  _interfaces = {};
  vi.restoreAllMocks();
});

describe("isPrivateIPv4", () => {
  test("accepts the three RFC 1918 ranges", () => {
    expect(isPrivateIPv4("10.0.0.1")).toBe(true);
    expect(isPrivateIPv4("172.16.0.1")).toBe(true);
    expect(isPrivateIPv4("172.31.255.254")).toBe(true);
    expect(isPrivateIPv4("192.168.1.10")).toBe(true);
  });

  test("rejects the 172 addresses outside 16-31", () => {
    expect(isPrivateIPv4("172.15.0.1")).toBe(false);
    expect(isPrivateIPv4("172.32.0.1")).toBe(false);
  });

  test("rejects link-local, loopback and public addresses", () => {
    // 169.254/16 shows up when DHCP failed — routing to it would not work.
    expect(isPrivateIPv4("169.254.1.1")).toBe(false);
    expect(isPrivateIPv4("127.0.0.1")).toBe(false);
    expect(isPrivateIPv4("8.8.8.8")).toBe(false);
  });

  test("rejects malformed input", () => {
    expect(isPrivateIPv4("192.168.1")).toBe(false);
    expect(isPrivateIPv4("192.168.1.256")).toBe(false);
    expect(isPrivateIPv4("not-an-ip")).toBe(false);
    expect(isPrivateIPv4("")).toBe(false);
  });
});

describe("detectLanIPv4", () => {
  test("returns the private IPv4 of a non-internal interface", () => {
    _interfaces = {
      lo0: [iface("127.0.0.1", { internal: true })],
      en0: [iface("192.168.1.42")],
    };
    expect(detectLanIPv4()).toBe("192.168.1.42");
  });

  test("prefers 192.168/16 over a Docker/VPN 10/8 or 172.16/12 address", () => {
    _interfaces = {
      docker0: [iface("172.17.0.1")],
      utun3: [iface("10.8.0.2")],
      en0: [iface("192.168.0.15")],
    };
    expect(detectLanIPv4()).toBe("192.168.0.15");
  });

  test("falls back to the first private address when no 192.168 exists", () => {
    _interfaces = { en0: [iface("10.1.2.3")] };
    expect(detectLanIPv4()).toBe("10.1.2.3");
  });

  test("skips IPv6, internal and link-local addresses", () => {
    _interfaces = {
      lo0: [iface("127.0.0.1", { internal: true })],
      en0: [iface("fe80::1", { family: "IPv6" }), iface("169.254.10.1")],
    };
    expect(detectLanIPv4()).toBeNull();
  });

  test("returns null when there are no interfaces at all", () => {
    _interfaces = {};
    expect(detectLanIPv4()).toBeNull();
  });
});

describe("isLoopbackUrl", () => {
  test("recognises the loopback spellings", () => {
    expect(isLoopbackUrl("http://127.0.0.1:3000")).toBe(true);
    expect(isLoopbackUrl("http://localhost:3000")).toBe(true);
    expect(isLoopbackUrl("http://[::1]:3000")).toBe(true);
  });

  test("is false for LAN and public hosts", () => {
    expect(isLoopbackUrl("http://192.168.1.10:3000")).toBe(false);
    expect(isLoopbackUrl("https://relay.example.com")).toBe(false);
  });

  test("is false for garbage rather than throwing", () => {
    expect(isLoopbackUrl("not a url")).toBe(false);
  });
});

describe("toPhoneReachableUrl", () => {
  test("swaps a loopback host for the LAN address, keeping scheme and port", () => {
    expect(toPhoneReachableUrl("http://127.0.0.1:3000", "192.168.1.42"))
      .toBe("http://192.168.1.42:3000");
    expect(toPhoneReachableUrl("http://localhost:3000", "10.0.0.5"))
      .toBe("http://10.0.0.5:3000");
  });

  test("leaves an already reachable relay untouched", () => {
    // The user pointed the extension at a real relay — that address is
    // already the one to advertise, LAN or not.
    expect(toPhoneReachableUrl("https://relay.example.com", "192.168.1.42"))
      .toBe("https://relay.example.com");
    expect(toPhoneReachableUrl("http://192.168.1.9:3000", "192.168.1.42"))
      .toBe("http://192.168.1.9:3000");
  });

  test("returns null for loopback with no LAN address", () => {
    // Emitting an unreachable `r` in the QR is worse than emitting none.
    expect(toPhoneReachableUrl("http://127.0.0.1:3000", null)).toBeNull();
  });

  test("passes a non-loopback string through untouched, even a malformed one", () => {
    // Not this function's job to validate: `resolveRelayUrl` already coerces
    // and `isValidRelayUrl` guards the user boundary. Only the loopback
    // rewrite is decided here.
    expect(toPhoneReachableUrl("http://", null)).toBe("http://");
  });
});
