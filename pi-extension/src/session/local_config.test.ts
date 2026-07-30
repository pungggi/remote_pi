import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadLocalConfig, localConfigExists, saveLocalConfig } from "./local_config.js";

const ENV = "REMOTE_PI_DIRECT_CONFIG";

function makeCwd(): string {
  return mkdtempSync(join(tmpdir(), "rp-localcfg-"));
}

/** Write a config.json into <cwd>/.pi/remote-pi/. */
function writeFileConfig(cwd: string, obj: unknown): void {
  const dir = join(cwd, ".pi", "remote-pi");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "config.json"), JSON.stringify(obj));
}

describe("loadLocalConfig — file vs REMOTE_PI_DIRECT_CONFIG", () => {
  let cwd: string;

  beforeEach(() => {
    cwd = makeCwd();
    delete process.env[ENV];
  });
  afterEach(() => {
    delete process.env[ENV];
    rmSync(cwd, { recursive: true, force: true });
  });

  test("reads the on-disk file when env is unset", () => {
    writeFileConfig(cwd, { agent_name: "fromfile", auto_start_relay: false });
    expect(loadLocalConfig(cwd)).toEqual({ agent_name: "fromfile", auto_start_relay: false });
  });

  test("empty config when neither env nor file present", () => {
    expect(loadLocalConfig(cwd)).toEqual({});
  });

  test("inline env takes precedence over the file", () => {
    writeFileConfig(cwd, { agent_name: "fromfile", auto_start_relay: false });
    process.env[ENV] = JSON.stringify({ agent_name: "fromenv", auto_start_relay: true });
    expect(loadLocalConfig(cwd)).toEqual({ agent_name: "fromenv", auto_start_relay: true });
  });

  test("inline env works with no file on disk", () => {
    process.env[ENV] = JSON.stringify({ agent_name: "envonly" });
    expect(loadLocalConfig(cwd)).toEqual({ agent_name: "envonly" });
  });

  test("malformed env JSON falls back to the file", () => {
    writeFileConfig(cwd, { agent_name: "fromfile" });
    process.env[ENV] = "{not valid json";
    expect(loadLocalConfig(cwd)).toEqual({ agent_name: "fromfile" });
  });

  test("empty/whitespace env falls back to the file", () => {
    writeFileConfig(cwd, { agent_name: "fromfile" });
    process.env[ENV] = "   ";
    expect(loadLocalConfig(cwd)).toEqual({ agent_name: "fromfile" });
  });

  test("only known fields are surfaced (unknown keys dropped)", () => {
    process.env[ENV] = JSON.stringify({ agent_name: "a", auto_start_relay: true, session_name: "x", junk: 1 });
    expect(loadLocalConfig(cwd)).toEqual({ agent_name: "a", auto_start_relay: true });
  });

  test("non-object env (array/number) falls back to the file", () => {
    writeFileConfig(cwd, { agent_name: "fromfile" });
    process.env[ENV] = "[1,2,3]";
    expect(loadLocalConfig(cwd)).toEqual({ agent_name: "fromfile" });
  });
});

describe("loadLocalConfig — room_id override (plan/120)", () => {
  let cwd: string;

  beforeEach(() => {
    cwd = makeCwd();
    delete process.env[ENV];
  });
  afterEach(() => {
    delete process.env[ENV];
    rmSync(cwd, { recursive: true, force: true });
  });

  test("surfaces room_id from the file", () => {
    writeFileConfig(cwd, { agent_name: "dev", room_id: "device" });
    expect(loadLocalConfig(cwd)).toEqual({ agent_name: "dev", room_id: "device" });
  });

  test("surfaces room_id from inline env", () => {
    process.env[ENV] = JSON.stringify({ room_id: "device" });
    expect(loadLocalConfig(cwd)).toEqual({ room_id: "device" });
  });

  test("empty string room_id is dropped", () => {
    process.env[ENV] = JSON.stringify({ room_id: "" });
    expect(loadLocalConfig(cwd)).toEqual({});
  });
});


describe("loadLocalConfig — workspace / worktree removed (plan 38)", () => {
  // The fields were dropped: the mesh identity is `(cwd, nome)`, with `cwd`
  // subsuming folder + worktree disambiguation. A stale key from an old config
  // (or one the Cockpit still injects) must be silently ignored on read.
  let cwd: string;

  beforeEach(() => {
    cwd = makeCwd();
    delete process.env[ENV];
  });
  afterEach(() => {
    delete process.env[ENV];
    rmSync(cwd, { recursive: true, force: true });
  });

  test("ignores a stale workspace/worktree key from the file", () => {
    writeFileConfig(cwd, { agent_name: "app", workspace: "acme", worktree: "feat-login" });
    expect(loadLocalConfig(cwd)).toEqual({ agent_name: "app" });
  });

  test("ignores a stale workspace/worktree key from the inline env", () => {
    process.env[ENV] = JSON.stringify({ agent_name: "app", workspace: "acme", worktree: "feat-login" });
    expect(loadLocalConfig(cwd)).toEqual({ agent_name: "app" });
  });
});

describe("localConfigExists — honors env + file", () => {
  let cwd: string;

  beforeEach(() => {
    cwd = makeCwd();
    delete process.env[ENV];
  });
  afterEach(() => {
    delete process.env[ENV];
    rmSync(cwd, { recursive: true, force: true });
  });

  test("false when neither env nor file present", () => {
    expect(localConfigExists(cwd)).toBe(false);
  });

  test("true when only the file exists", () => {
    writeFileConfig(cwd, { agent_name: "a" });
    expect(localConfigExists(cwd)).toBe(true);
  });

  test("true when only the inline env is set", () => {
    process.env[ENV] = JSON.stringify({ agent_name: "a" });
    expect(localConfigExists(cwd)).toBe(true);
  });

  test("false when env is set but malformed and no file", () => {
    process.env[ENV] = "nope";
    expect(localConfigExists(cwd)).toBe(false);
  });
});

describe("saveLocalConfig — unaffected by env (still writes the file)", () => {
  let cwd: string;

  beforeEach(() => {
    cwd = makeCwd();
    delete process.env[ENV];
  });
  afterEach(() => {
    delete process.env[ENV];
    rmSync(cwd, { recursive: true, force: true });
  });

  test("auto_start_relay defaults to true on save", () => {
    saveLocalConfig(cwd, { agent_name: "saved" });
    delete process.env[ENV]; // ensure we read the file back, not any env
    expect(loadLocalConfig(cwd)).toEqual({ agent_name: "saved", auto_start_relay: true });
  });

  // Plan/120 regression: a worktree is created from INSIDE the device daemon,
  // which runs with REMOTE_PI_DIRECT_CONFIG={...,room_id:"device"}. saveLocalConfig
  // must merge against the on-disk file only — never the env — or room_id:"device"
  // leaks into the worktree's config.json and the new session joins the
  // phone-filtered "device" room (looks "not connected").
  test("never persists env-only fields (device daemon room_id must not leak)", () => {
    process.env[ENV] = JSON.stringify({
      agent_name: "device",
      auto_start_relay: true,
      room_id: "device",
    });
    saveLocalConfig(cwd, { agent_name: "ngTradr", auto_start_relay: true });
    delete process.env[ENV]; // read the file back, not the env
    const onDisk = loadLocalConfig(cwd);
    expect(onDisk).toEqual({ agent_name: "ngTradr", auto_start_relay: true });
    expect(onDisk.room_id).toBeUndefined();
  });
});
