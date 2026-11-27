import type { AckResult } from "./peer.js";

/**
 * Issue #140 — the timing of a cross-PC refusal, in one dependency-free
 * place.
 *
 * The relay hands a cross-PC envelope to every connection the target PC has,
 * and every local broker that receives one answers for its own peers. A PC
 * should have exactly one broker (the election now keeps it that way), but
 * while it has more, the broker that knows the target says `received` and the
 * others `denied`. A sender that kept the first answer reported a delivered
 * message as refused.
 *
 * Both ends now give the `received` room to arrive first. The module has no
 * runtime imports so the thin entry (plan/143) can print the numbers without
 * pulling in the mesh.
 */

/**
 * Receiver side: how long a bridge that does not own the target holds back
 * its `denied`. A sender of any version keeps the first answer it gets, so
 * this alone already protects older senders. Far beyond the spread between
 * two answers that left the same PC through the same relay, far inside the
 * 5 s ACK deadline.
 */
export const CROSS_PC_DENIED_DELAY_MS = 500;

/**
 * Sender side: how long a cross-PC `denied` waits before it may settle the
 * send. A `received` inside the grace wins. Only a send that really ends as
 * `denied` pays for it.
 */
export const CROSS_PC_DENIED_GRACE_MS = 300;

/**
 * Tool text for a cross-PC `denied` that outlived the grace. Says what is
 * known and no more: these brokers denied the address, and none confirmed it
 * in time. That makes the address most likely wrong for that PC, and only
 * rarely a peer that was unreachable for a moment, so the advice covers both
 * without inviting a blind resend (the first message may have arrived).
 */
export function describeUnconfirmedDenial(to: string, ack: AckResult): string {
  const answers = ack.answers ?? [];
  const pids = answers.map((answer) => answer.pid).filter((pid): pid is number => pid !== undefined);
  const everyPid = answers.length > 0 && pids.length === answers.length;
  const who = everyPid
    ? (pids.length === 1 ? `pid ${pids[0]}` : `${pids.length} brokers (pid ${pids.join(", pid ")})`)
    : (answers.length > 1 ? `${answers.length} brokers` : "its broker");
  return `Delivery to "${to}" was NOT confirmed: ${who} on that PC denied the address, ` +
    `and none confirmed it within ${CROSS_PC_DENIED_GRACE_MS} ms. ` +
    `Most likely the address is not on that PC: run list_peers and use the address it ` +
    `prints verbatim. If list_peers shows it, wait for the reply before sending again.`;
}
