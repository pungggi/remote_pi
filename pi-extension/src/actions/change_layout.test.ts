// change_layout handler tests — the name-resolution core (pure fs) plus the
// reply shaping for the two synchronous failure modes (unknown name, missing
// Cockpit CLI). The happy path shells out to the real Cockpit CLI and is
// covered by the resolver + CLI-invocation unit boundaries instead.
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import {
  listNamedLayouts,
  resolveNamedLayout,
  findCockpitCli,
  readCockpitEndpoint,
  cockpitChildEnv,
  orchestrateArgs,
  parseOrchestrateReply,
} from "./change_layout.js";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ckp-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("resolveNamedLayout", () => {
  test("resolves a layout at the root level", () => {
    writeFileSync(join(dir, "dev.ckp"), "panes: []\n");
    expect(resolveNamedLayout("dev", [dir])?.path).toBe(join(dir, "dev.ckp"));
  });

  test("resolves nested layouts up to the depth budget", () => {
    mkdirSync(join(dir, "proj"));
    writeFileSync(join(dir, "proj", "triage.ckp"), "panes: []\n");
    expect(resolveNamedLayout("triage", [dir])?.path).toBe(
      join(dir, "proj", "triage.ckp"),
    );
  });

  test("skips junk trees while descending", () => {
    mkdirSync(join(dir, "node_modules", "x", "y"), { recursive: true });
    writeFileSync(join(dir, "node_modules", "x", "y", "evil.ckp"), "panes: []\n");
    expect(resolveNamedLayout("evil", [dir])).toBeNull();
  });

  test("rejects traversal and path-shaped names", () => {
    expect(resolveNamedLayout("../etc/passwd", [dir])).toBeNull();
    expect(resolveNamedLayout("a/b", [dir])).toBeNull();
    expect(resolveNamedLayout("a\\b", [dir])).toBeNull();
    expect(resolveNamedLayout("  ", [dir])).toBeNull();
  });

  test("missing name yields null; roots searched in order", () => {
    const second = join(dir, "second");
    mkdirSync(second);
    writeFileSync(join(second, "only-here.ckp"), "panes: []\n");
    const empty = join(dir, "empty");
    mkdirSync(empty);
    expect(resolveNamedLayout("only-here", [empty])).toBeNull();
    expect(resolveNamedLayout("only-here", [empty, second])?.path).toBe(
      join(second, "only-here.ckp"),
    );
  });

  test("case-sensitive: .CKP does not match", () => {
    writeFileSync(join(dir, "UP.ckp"), "panes: []\n");
    expect(resolveNamedLayout("up", [dir])).toBeNull();
    expect(resolveNamedLayout("UP", [dir])?.path).toBe(join(dir, "UP.ckp"));
  });
});

describe("listNamedLayouts", () => {
  test("enumerates + sorts layouts across roots, first-wins on duplicates", () => {
    writeFileSync(join(dir, "b.ckp"), "panes: []\n");
    mkdirSync(join(dir, "sub"));
    writeFileSync(join(dir, "sub", "a.ckp"), "panes: []\n");
    const other = join(dir, "other-root");
    mkdirSync(other);
    writeFileSync(join(other, "c.ckp"), "panes: []\n");
    // duplicate name in a later root — first (dir) wins
    writeFileSync(join(other, "b.ckp"), "panes: []\n");
    const layouts = listNamedLayouts([dir, other]);
    expect(layouts.map((l) => l.name)).toEqual(["a", "b", "c"]);
  });
});

describe("findCockpitCli", () => {
  test("POSIX: falls back to the bare PATH name when no absolute candidate exists", () => {
    vi.spyOn(process, "platform", "get").mockReturnValue("linux" as never);
    // HOME-independent: the candidate dirs under the REAL homedir are
    // Windows-named (cockpit.exe), so on the mocked linux platform the
    // fallback must be the bare command — or an absolute POSIX candidate if
    // this machine happens to have one.
    const cli = findCockpitCli();
    expect(cli === "cockpit" || /\/cockpit$/.test(cli)).toBe(true);
    vi.restoreAllMocks();
  });
});

describe("readCockpitEndpoint (review fix: daemon is not a Cockpit terminal)", () => {
  const writeEndpoint = (name: string, doc: unknown) => {
    mkdirSync(join(dir, ".cockpit"), { recursive: true });
    writeFileSync(join(dir, ".cockpit", name), JSON.stringify(doc));
  };

  test("Windows shape: tcp port + token from status-endpoint.json", () => {
    writeEndpoint("status-endpoint.json", { port: 52341, token: "cafe" });
    expect(readCockpitEndpoint(dir)).toEqual({ transport: "tcp", port: 52341, token: "cafe" });
  });

  test("debug endpoint file is the secondary candidate", () => {
    writeEndpoint("status-endpoint-debug.json", { sock: "/tmp/s-debug.sock" });
    expect(readCockpitEndpoint(dir)).toEqual({ transport: "sock", sock: "/tmp/s-debug.sock" });
  });

  test("POSIX fallback: conventional status.sock when no endpoint file exists", () => {
    mkdirSync(join(dir, ".cockpit"), { recursive: true });
    writeFileSync(join(dir, ".cockpit", "status.sock"), "");
    expect(readCockpitEndpoint(dir)).toEqual({ transport: "sock", sock: join(dir, ".cockpit", "status.sock") });
  });

  test("malformed endpoint file is skipped; nothing at all → null", () => {
    writeEndpoint("status-endpoint.json", "not-json{");
    expect(readCockpitEndpoint(dir)).toBeNull();
  });
});

describe("cockpitChildEnv", () => {
  test("tcp endpoint → COCKPIT_STATUS_PORT (+token), base env preserved", () => {
    const env = cockpitChildEnv({ transport: "tcp", port: 52341, token: "cafe" }, { PATH: "x" });
    expect(env).toMatchObject({ PATH: "x", COCKPIT_STATUS_PORT: "52341", COCKPIT_STATUS_TOKEN: "cafe" });
  });

  test("sock endpoint → COCKPIT_STATUS_SOCK, no port vars", () => {
    const env = cockpitChildEnv({ transport: "sock", sock: "/tmp/s.sock" }, {} as NodeJS.ProcessEnv);
    expect(env).toMatchObject({ COCKPIT_STATUS_SOCK: "/tmp/s.sock" });
    expect(env["COCKPIT_STATUS_PORT"]).toBeUndefined();
  });
});

describe("orchestrateArgs (review fix: --json)", () => {
  test("passes --json and the path verbatim — no quoting, even with spaces", () => {
    const p = "C:\\Program Files\\proj\\my layout.ckp";
    expect(orchestrateArgs(p)).toEqual(["orchestrate", "--json", p]);
  });
});

describe("parseOrchestrateReply (review fix: --json shape)", () => {
  test("success: exit 0 + one {created, skipped} stdout line", () => {
    const r = parseOrchestrateReply(0, '{"created":["a"],"skipped":["b","c"]}\n', "");
    expect(r).toEqual({ ok: true, created: ["a"], skipped: ["b", "c"], message: "" });
  });

  test("success tolerates junk lines around the JSON", () => {
    const r = parseOrchestrateReply(0, 'banner\n{"created":[],"skipped":[]}\n', "");
    expect(r.ok).toBe(true);
    expect(r.created).toEqual([]);
  });

  test("non-string entries are filtered", () => {
    const r = parseOrchestrateReply(0, '{"created":["a",42,null],"skipped":[]}\n', "");
    expect(r.created).toEqual(["a"]);
  });

  test("app-reported failure: nonzero exit, message from stderr", () => {
    const r = parseOrchestrateReply(1, "", "cockpit: layout file not found\n");
    expect(r).toEqual({ ok: false, created: [], skipped: [], message: "cockpit: layout file not found" });
  });

  test("exit 3 (no terminal / connect refused) surfaces the CLI's stderr", () => {
    const r = parseOrchestrateReply(3, "", "cockpit: could not connect to app: x");
    expect(r.ok).toBe(false);
    expect(r.message).toContain("could not connect");
  });

  test("exit 0 but unparseable stdout → loud failure, not silent empty success", () => {
    const r = parseOrchestrateReply(0, "created: a, b\n", "");
    expect(r.ok).toBe(false);
    expect(r.message).toContain("created:");
  });
});
