# 174 — One broker per host, and a cross-PC `denied` you can trust

**Issue:** [#140](https://github.com/pungggi/remote_pi/issues/140) · **PR:**
[#141](https://github.com/pungggi/remote_pi/pull/141) · **Status:** in review
(2026-11-27) · **Subproject:** `pi-extension`

## Context

`agent_send` from one PC to a session on another PC could come back `denied`
although the message was delivered and answered. On 2026-11-27 five of twelve
sends did, all before a clean boot.

The issue names the mechanism: the relay forwards a cross-PC envelope to every
live connection of the target PC, every local broker that receives one answers
for its own peers, and the sender kept the first answer. It left one question
open: **why the phone had more than one leader.**

### Answer: the election could orphan a live leader

A host is meant to have one local mesh with one broker, hosted by the leader
(`global_config.ts`: `LOCAL_SESSION_NAME = "local"`). Only the leader attaches
the relay bridge (`mesh_node.ts`), so two answering bridges mean two leaders.

`joinOrLead` (`leader_election.ts`) removed the socket file after **any**
failed probe. That is the "stale socket after a crash" path, and it had a
race:

1. The leader exits. Two followers lose their socket and re-elect 100 ms
   later, at the same moment.
2. Both find the stale file and are both refused (`ECONNREFUSED`).
3. The first clears the file and binds.
4. The second runs its own `lstat` + `unlink` a moment later and removes the
   **first one's fresh socket**.

The first leader keeps its clients and its relay bridge, but nothing can reach
it at the path any more. The host has two brokers, each answering from its
own roster.

This fits the evidence in the issue:

- **Steady state is fine.** After a boot there is exactly one leader, and
  every send is acknowledged `received`.
- **The false negatives belong to transitions**: a session respawn at
  11:41:05, two device-daemon restarts, the end of an interactive session.
- **The same connections gave both answers**, because the outcome is a race
  between two acks on different connections.
- **Ruled out**: a different `REMOTE_PI_HOME` (one socket after the boot, the
  daemon listed as a local peer of the `demo` session) and non-leaders
  answering (no bridge outside the leader).

A phone makes the window wider than microseconds: a process frozen between
its failed connect and its `lstat` (doze, a busy event loop) removes whatever
is at the path when it thaws.

## Decisions

1. **Fix the cause, then the symptom.** The election must not produce a second
   leader. The ACK changes stay because more than one broker per PC key is
   still possible (two homes, an unknown race), and because sender and target
   update at different times.
2. **A refusal is held back, not silenced.** The issue proposed that a bridge
   which does not know the target stays silent. Silence turns an unknown
   address into a 5 s `timeout`, which tells the agent less than `denied` does.
   A delayed `denied` keeps the information and cannot win against a
   `received`.
3. **Both ends wait**, for roll-out: the receiver delay alone protects an old
   sender (it keeps the first answer), the sender grace alone protects against
   an old target.
4. **Numbers**: 500 ms on the receiver, 300 ms on the sender. Together far
   beyond the spread between two answers that left the same PC through the
   same relay, far inside the 5 s ACK deadline.
5. **Only the owner of the path may close a broker.** libuv removes the
   socket file a server was bound to when the server closes, whatever lies at
   the path by then. So no unlink is needed on a clean leader exit, and a
   leader that lost the path must not close: it abandons its listener
   (`Broker.abandon()`) and leaves it open on an inode nothing can reach. One
   descriptor until exit, against deleting the successor's socket.
6. **Relay-side routing and the leader preference are follow-ups** (below).

## What changed

### A. Election (`leader_election.ts`, `cwd_lock.ts`)

- `probe(path)` reports why nothing answered: `refused` (`ECONNREFUSED`),
  `timeout`, or `error`. Only `refused` is read as "nobody listens there". A
  probe that timed out leaves the path alone and is repeated; after 20
  attempts the election fails and says which it was.
- `socketIdentity(path)` reads the socket file's `{dev, ino}` before the probe.
  `removeStaleSock(path, identity)` unlinks only that same socket.
- The leader's identity is returned with the election result.
- `acquireCwdLock` (`cwd_lock.ts`) had the same pattern for the per-folder
  lock and gets the same rule.

**Acceptance**

- [x] A removal with an identity leaves a socket another process bound in the
  meantime, and that socket stays reachable.
- [x] A rival that rebinds between the refused probe and the removal is
  followed, not orphaned (`afterProbe` test seam makes the interleaving
  deterministic).
- [x] A plain file at the path is never removed; the election gives up and
  says why.

### B. Safety nets (`peer.ts`, `broker.ts`)

- **Bind, then verify.** `register_ack` carries the broker's `instance`. A
  leader registers back through its own path; when another broker answers, it
  keeps that registration and follows it.
- **Path check.** Every 5 s a leader reads its path's identity (one `lstat`,
  POSIX). When the path no longer leads to its own socket it stands down. Its
  clients re-elect onto the new owner, and `MeshNode` takes the relay bridge
  down as after any leader loss.
- **Abandon, not close** (`broker.ts`). Closing a listening server makes
  libuv unlink whatever is at its path, so a leader that gives up its broker
  without owning the path abandons the listener instead. The same rule guards
  `leave()` and `rename()` of a leader that lost the path, and the election's
  own failure paths. CI caught this: the first stand-down closed the old
  server and removed the successor's socket.

**Acceptance**

- [x] A leader that hears another broker at its own path follows it, a
  message through the real broker arrives, and the real broker keeps its
  socket.
- [x] A leader whose path is taken away stands down within a few check
  intervals; its client is registered on the new broker, both were told that
  the broker changed, the successor still owns the path, and a newcomer
  follows it.
- [x] Several check intervals pass without a stand-down while the leader owns
  its socket.

(The stand-down cases run on ubuntu CI only; see DoD.)

### C. ACKs (`peer.ts`, `broker_remote.ts`, `tools.ts`, `mcp/mesh_result.ts`)

- **Receiver**: `denied` is held back `CROSS_PC_DENIED_DELAY_MS` and logged as
  `[broker_remote] event=ack_denied target=… id=… pid=…`. A detached bridge
  never sends a held-back refusal.
- **Sender**: a cross-PC `denied` opens a grace of `CROSS_PC_DENIED_GRACE_MS`.
  A `received` inside it wins. A `denied` that outlives it settles with
  `answers: [{ status, pid }]`.
- **Local and Relay refusals settle at once**, as before.
- **Tool text** (Pi and MCP): "Delivery to X was NOT confirmed: pid N on that
  PC denied the address, and none confirmed it within 300 ms. …" followed by
  the `list_peers` advice.
- Constants and wording live in `session/ack_policy.ts`, which has no runtime
  imports: the thin entry (plan/143) loads `tools.ts` and must not pull in the
  mesh.

**Acceptance**

- [x] `received` inside the grace wins over an earlier `denied`.
- [x] `denied` settles only after the grace and names every broker that
  denied; one grace per send; no timer left behind.
- [x] The bridge answers `received` at once with its pid; `denied` only after
  the delay; a detached bridge never.
- [x] Wording pinned once, for both tools.

### D. Docs

`CHANGELOG.md`, root `README.md`, `pi-extension/README.md`,
`skills/agent-network/SKILL.md`, `PROTOCOL.md`.

## DoD

- [x] Typecheck and the whole suite pass on Windows (1709 passed).
- [x] CI green on ubuntu (node 22 and 24) and windows, where the POSIX-only
  cases run.
- [x] AI review of the PR: five findings, two fixed (final error of the
  election, `unref` on the grace timer), three answered.
- [ ] Controlled reproduction on two PCs with real processes, as the issue
  asks: on PC B start session 1, then session 2; send continuously from PC A
  to session 2 while session 1 exits. Expect every send `received`, and at
  most one `broker.sock` owner at each moment.
- [ ] After the rollout: `grep ack_denied` on the phone finds nothing in
  steady state.

## Open

- **Residual races, and why they are covered.** Between the second `lstat` and
  the `unlink` there is still a window of microseconds, and an inode number can
  be reused. Bind-then-verify catches a takeover at start, the path check
  catches one later. A leader that stands down costs its clients one
  re-election, the same as a leader loss.
- **Probe timeout against a live leader.** A listener that accepts nothing
  (full backlog) no longer has its socket removed. The joiner retries and then
  fails with the reason. Before, it took the path over and orphaned that
  leader.

## Next plans

- **Relay-side routing** (the issue's "proper" fix). `pi_forward.rs` forwards
  to every connection of the target key. Track each connection's roster from
  the `peers_update` frames it sends, deliver a unicast only to connections
  that advertise the target, and fall back to the fan-out when none does. Own
  release and rollout (PC relay and phone relay).
- **The device daemon as preferred leader** (the issue's addition). Needs a
  decision before any code:
  - *Yield on request.* A peer marked `preferredLeader` (the daemon) asks the
    current leader to stand down when it joins. The leader uses the stand-down
    path of this plan.
  - *Head start.* With no listener, followers that are not preferred wait a
    short moment before they bind, so the preferred process wins the path.
  - *Effect on a phone.* The daemon is supervised and rarely restarts, so the
    end of an interactive session stops being a leader change. The daemon
    hosts every local message, and its restart becomes the one transition.
  - *To decide.* Whether the daemon should host the broker at all times, and
    what a second supervised daemon (another home) should do.
