# Plan 150 — Mesh delivery ownership and recovery

## Context

Upstream #216 showed that a second in-process extension factory can steal the global `pi` handle. Messages for session A can then land in session B, while A's queue stalls behind busy state that A cannot clear.

Upstream #204 adds wake confirmation and live-idle checks, but does not define session ownership. Upstream #189 retries missed bridge attachment; this fork needs a bounded retry budget instead of its unbounded timer chain.

## Invariants

- **Owner binding**: A mesh join captures the joining `pi`. Later factory calls cannot redirect its messages.
- **Per-session busy state**: Each `pi` owns its FIFO, lifecycle generation, idle context, and wake state.
- **No fabricated activity**: A requested wake does not prove that an agent run started. Only `agent_start` confirms it.
- **No duplicate content**: Accepted appends are never replayed after a failed or unconfirmed wake. Only an unsubmitted FIFO suffix is retried.
- **Replacement isolation**: Shutdown invalidates timers and drops the outgoing in-memory queue. A replacement starts with fresh delivery state.
- **Bounded bridge recovery**: Injected-relay attachment retries delayed leader/broker readiness with a fixed budget. A later attach or reconnect event starts a fresh budget. Owned-relay reconnect stays separate.

## Expected structure

- `pi-extension/src/session/mesh_delivery.ts`: per-session controller and registry.
- `pi-extension/src/extension-state.ts`: owns the registry and resets all controllers.
- `pi-extension/src/index.ts`: forwards the event's `pi` and context; disposes the matching owner.
- `pi-extension/src/main.ts`: captures the join owner, routes delivery through it, and keeps lifecycle events per session.
- `pi-extension/src/session/mesh_node.ts`: bounded injected-bridge attach retries.
- Focused controller, two-factory, replacement, FIFO, wake, and bridge tests.

## Steps and acceptance criteria

1. **Add per-session delivery controllers**
   - Idle FIFO batches append with `triggerTurn:false` and use one separate follow-up wake.
   - Busy delivery waits for `agent_end` plus live `ctx.isIdle()`.
   - Wake timeout never re-appends accepted content.
2. **Bind mesh ownership**
   - Two factory instances cannot redirect the joined session's messages.
   - One session's events cannot release another session's pending batch.
3. **Handle failures and replacement**
   - Synchronous partial append failure preserves the unsubmitted FIFO suffix.
   - Failed, late, and confirmed wakes behave deterministically.
   - Shutdown invalidates microtasks, idle checks, and wake timers.
4. **Retry bridge attachment**
   - Delayed leader and broker readiness recover without a reconnect event.
   - Retry stops after success, teardown, or budget exhaustion.
   - Owned-relay reconnect does not use the injected-bridge retry timer.
5. **Verify**
   - New focused tests pass.
   - Full extension suite, typecheck, and build pass.

## DoD

- [x] Per-session owner and busy state implemented.
- [x] #204 wake/idle/FIFO behavior ported around that owner.
- [x] Bounded #189 bridge reattach implemented and tested.
- [x] Full extension verification green: 60 files, 1113 passed, 22 skipped; typecheck + build.
- [x] Durable queue/ACK semantics remain a separate product decision.

## Next plans

- Revisit upstream #217 for opt-in busy-agent steering only after this correctness work is stable.
- Consider durable mesh delivery acknowledgements separately; this plan does not change the broker's `received` contract.
