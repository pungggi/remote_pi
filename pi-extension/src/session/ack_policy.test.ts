/**
 * Issue #140 — what a sender concludes from a cross-PC `denied`, and the two
 * waits that make that conclusion sound. The wording is shared by the Pi tool
 * (`session/tools.ts`) and the MCP tool (`mcp/mesh_result.ts`), so it is pinned
 * here once.
 */
import { describe, expect, test } from "vitest";
import {
  CROSS_PC_DENIED_DELAY_MS,
  CROSS_PC_DENIED_GRACE_MS,
  describeUnconfirmedDenial,
} from "./ack_policy.js";
import type { AckResult } from "./peer.js";
import { formatMeshAckResult } from "../mcp/mesh_result.js";

const ADDRESS = "phone:/data/demo@demo";

function denied(answers: NonNullable<AckResult["answers"]>): AckResult {
  return { status: "denied", id: "id-1", target: "demo", answers };
}

describe("cross-PC refusal timing (issue #140)", () => {
  test("both waits together stay far inside the 5 s ACK deadline", () => {
    expect(CROSS_PC_DENIED_GRACE_MS).toBeGreaterThan(0);
    expect(CROSS_PC_DENIED_DELAY_MS).toBeGreaterThan(0);
    expect(CROSS_PC_DENIED_GRACE_MS + CROSS_PC_DENIED_DELAY_MS).toBeLessThan(2_000);
  });
});

describe("describeUnconfirmedDenial", () => {
  const tail =
    `and none confirmed it within ${CROSS_PC_DENIED_GRACE_MS} ms. ` +
    "Most likely the address is not on that PC: run list_peers and use the address it " +
    "prints verbatim. If list_peers shows it, wait for the reply before sending again.";

  test("names the one broker that denied by its pid", () => {
    expect(describeUnconfirmedDenial(ADDRESS, denied([{ status: "denied", pid: 4242 }])))
      .toBe(`Delivery to "${ADDRESS}" was NOT confirmed: pid 4242 on that PC denied the address, ${tail}`);
  });

  test("names every broker when several denied", () => {
    const text = describeUnconfirmedDenial(ADDRESS, denied([
      { status: "denied", pid: 4241 },
      { status: "denied", pid: 4242 },
    ]));
    expect(text).toContain("2 brokers (pid 4241, pid 4242) on that PC denied the address");
  });

  test("counts brokers that named no pid", () => {
    const text = describeUnconfirmedDenial(ADDRESS, denied([{ status: "denied" }, { status: "denied" }]));
    expect(text).toContain("2 brokers on that PC denied the address");
    expect(describeUnconfirmedDenial(ADDRESS, denied([{ status: "denied" }])))
      .toContain("its broker on that PC denied the address");
  });

  test("the MCP tool text carries the same wording and is an error", () => {
    const result = formatMeshAckResult(ADDRESS, denied([{ status: "denied", pid: 7 }]));
    expect(result.isError).toBe(true);
    expect(result.content[0]?.text).toBe(describeUnconfirmedDenial(ADDRESS, denied([{ status: "denied", pid: 7 }])));
  });

  test("a local or Relay refusal keeps its wording", () => {
    expect(formatMeshAckResult(ADDRESS, { status: "denied", id: "id-1" }).content[0]?.text)
      .toBe(`${ADDRESS} denied the message`);
    expect(formatMeshAckResult(ADDRESS, {
      status: "denied", id: "id-1", reason: "not_authorized", error: "transport_error: not_authorized",
    }).content[0]?.text).toContain("Relay did not authorize delivery");
  });
});
