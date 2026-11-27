/**
 * Plan/173 stage A2 — `device_info_request`: what this device is and which
 * agents it can start.
 *
 * The app asks this before it shows the start sheet, so it can offer:
 *
 *   - the device's host class (`android` gets "Open in Termux", a PC gets
 *     "the terminal is on the PC"),
 *   - the agents this device can really start — Pi everywhere, AGY only where
 *     the `agy` CLI answers. A PC without `agy` on PATH offers Pi only; the
 *     phone offers AGY once stage C found a working route.
 *
 * Nothing is stored at pairing time. The answer is computed on every request,
 * so a device that gains or loses `agy` is described correctly the next time
 * the sheet opens. The only cache is the ten-minute `agy` probe (see
 * `./agent_models.ts`), because a cold CLI start on a phone is not free.
 *
 * Served by the device daemon like `list_projects_request`, so it works with
 * no live Pi session. Always replies.
 */

import { hostname } from "node:os";
import type { AgentKind, ClientMessage, DevicePlatform, WireDeviceHost } from "../protocol/types.js";
import type { ActionReplySender } from "./handlers.js";
import { terminalKindHere } from "./open_terminal.js";
import { probeAgy } from "./agent_models.js";
import { readPackageVersion } from "../version.js";
import { isTermux } from "../termux.js";

type DeviceInfoRequestMsg = Extract<ClientMessage, { type: "device_info_request" }>;

/** Host class from the two facts the extension can read without asking
 *  anyone: Termux's marker and Node's platform. */
export function devicePlatformFor(termux: boolean, platform: NodeJS.Platform): DevicePlatform {
  if (termux) return "android";
  if (platform === "win32") return "windows";
  if (platform === "darwin") return "macos";
  if (platform === "linux") return "linux";
  return "other";
}

export interface DeviceInfoDeps {
  platform?: NodeJS.Platform;
  /** `isTermux()`; injectable for tests. */
  termux?: boolean;
  /** `os.hostname()`, injectable for tests. */
  label?: string;
  /** `terminalKindHere()`, injectable for tests. */
  terminal?: WireDeviceHost["terminal"];
  version?: string;
  /** `probeAgy()`, injectable so tests never start agy. */
  probeAgy?: () => Promise<boolean>;
}

export type DeviceDescription =
  | { ok: true; host: WireDeviceHost; agents: AgentKind[]; version: string }
  | { ok: false; message: string; version: string };

/** Collect the device's facts. Never throws. */
export async function describeDevice(deps: DeviceInfoDeps = {}): Promise<DeviceDescription> {
  const version = deps.version ?? readPackageVersion();
  try {
    const host: WireDeviceHost = {
      platform: devicePlatformFor(deps.termux ?? isTermux(), deps.platform ?? process.platform),
      label: deps.label ?? hostname(),
      terminal: deps.terminal ?? terminalKindHere(),
    };
    const agents: AgentKind[] = ["pi"];
    // A failing probe (missing CLI, half-installed, slow first start) simply
    // leaves AGY unlisted; it must never take the whole answer down.
    let agy = false;
    try {
      agy = await (deps.probeAgy ?? probeAgy)();
    } catch {
      agy = false;
    }
    if (agy) agents.push("agy");
    return { ok: true, host, agents, version };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e), version };
  }
}

/** Replies with `device_info_result`. */
export async function handleDeviceInfo(
  sender: ActionReplySender,
  msg: DeviceInfoRequestMsg,
  deps: DeviceInfoDeps = {},
): Promise<void> {
  const d = await describeDevice(deps);
  sender.send(
    d.ok
      ? {
          type: "device_info_result",
          in_reply_to: msg.id,
          ok: true,
          host: d.host,
          agents: d.agents,
          version: d.version,
        }
      : {
          type: "device_info_result",
          in_reply_to: msg.id,
          ok: false,
          agents: [],
          version: d.version,
          message: d.message,
        },
  );
}
