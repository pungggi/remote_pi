# Plan 143 — Thin extension entry: near-zero static imports, lazy runtime (issue #61)

## Context

`pi-extension/src/index.ts` is a 5,504-line monolith with ~54 top-level
static imports. Pi loads extensions **sequentially** and awaits each factory
(`loadExtensionsInternal` in pi's `dist/core/extensions/loader.js`), so every
millisecond of our module-level import graph is added to pi startup.

Measured 2026-10-11 (Windows 11, warm cache):

| Measurement | Time |
|---|---|
| pi with all 16 packages | 9.4 s |
| pi `--no-extensions` | 0.5 s |
| remote_pi alone (baseline subtracted) | ~2.4 s |
| of which: bare `import('dist/index.js')` | ~1.9 s |

remote_pi is the single slowest extension in this setup.

### Verified dependency facts (2026-10-11, current `main`)

The issue's dep list is partially stale; the graph today is smaller but still
heavy. Checked against source:

- **`ws`** — static via `transport/relay_client.ts` (imported by index.ts and
  `session/mesh_node.ts`). Heavy: CJS interop.
- **`qrcode-terminal`** — static via `pairing/qr.ts` (imported by index.ts).
  Heavy: CJS, large QR tables.
- **`@noble/ed25519`** — static via `pairing/crypto.ts`, pulled by
  `transport/inner_sig.ts` (imported by index.ts).
- **~45 internal modules** — each a separate `dist/` file pi must stat, parse
  and execute (tsc emits one file per module; `main` is `dist/index.js`).
- **Already lazy, NOT in the static graph**: `@napi-rs/keyring` (made lazy in
  issue #113, see `pairing/storage.ts` `_loadAsyncEntry`); `croner` (only in
  `daemon/supervisor.ts` + `cron_registry.ts`, the supervisord bin graph);
  `zod` + `@modelcontextprotocol/sdk` (only in `mcp/mesh_server.ts`, spawned
  as a child process, never imported).
- **Already cheap**: `@earendil-works/pi-coding-agent` and `@earendil-works/pi-tui`
  value imports hit pi's own module cache (near-zero marginal cost).

### Foundation already in place

- **`extension-state.ts`** — all ~48 former module singletons live in one
  exported `ext` object with type-only imports (zero runtime deps). Its header
  explicitly anticipates a domain split.
- **`session/tools.ts`** (agent tools) — schemas + tiny execute bodies; imports
  are `typebox` + type-only. Thin already.
- **`session/local_config.ts`** — `node:fs` + `node:path` only.

## Expected structure

One new lazy boundary, not fifty. The whole current monolith body moves
**unchanged** to `src/main.ts`; `src/index.ts` becomes a thin registration
entry that dynamic-imports `main.js` at use sites.

```
src/index.ts    # thin entry (target: a few hundred lines)
                #   static imports ≈ { extension-state, session/tools,
                #                      session/local_config, typebox, node:* }
                #   - factory: registers commands, agent tools, event hooks
                #   - session_start gate (cheap checks) stays here
                #   - trivial *_ForTest accessors stay here (read/write ext)
                #   - heavy test hooks forwarded via dynamic import
                #   - if (_isDirectRun()) CLI bootstrap → dynamic import
src/main.ts     # the entire current monolith body, byte-identical where
                #   possible: helpers, _cmd*, lifecycle, pair flow, relay,
                #   mesh, session_sync. Exports named entry points.
```

**Why one boundary**: the ~200 module-level helpers reference each other and
the static imports directly; isolating the monolith as a single lazy unit is
the only mechanical, reviewable move. Fine-grained per-domain lazy loading is
future work (see Next plans) and is not needed to hit the 0.3 s target.

### Entry rules

- **Commands**: descriptions + `getArgumentCompletions` stay inline (cheap
  data). Every handler becomes `ext.lastCtx = ctx; const m = await
  import("./main.js"); await m._cmdX(...)`.
- **Agent tools**: `registerAgentTools(pi, () => ext.meshNode?.peer() ?? null)`
  stays static in the entry (already thin; schemas are cheap data).
- **Event hooks**: thin wrappers. Cheap state mutations (`ext.lastEventCtx`,
  waiting-for-input reset) run inline; heavy logic forwards to main via
  dynamic import. Ordering per event is preserved (one import per event fire;
  Node caches after the first).
- **`session_start`**: the existing gate (daemon / print-mode / cwd /
  `localConfigExists` / `effectiveAutoStartRelay`) runs in the entry using
  `session/local_config.ts` (node builtins only). Only when the gate passes:
  `void import("./main.js").then(m => m.autoInit(ctx))`. The relay connect
  lands a few hundred ms later in the background; accepted by the issue.
- **Factory invariant kept**: no processes, sockets, watchers or timers in the
  factory (pi docs forbid them; relay connect already lives in session_start).
- **No `export * from "./main.js"`** in the entry: a re-export is a static
  import and would defeat the whole point.

### Public surface compatibility

`dist/index.js` consumers (verified by grep):

- **Default export** — unchanged shape.
- **Light `*_ForTest` accessors** (read/write `ext`, one-liners) — stay in the
  entry; tests keep importing them from `./index.js` with zero churn.
- **Heavy test hooks** (`_connectForTest`, `_startRelayForTest`,
  `_checkSelfRevokeForTest`, ...) — move to main.ts; the entry forwards them
  as `export const _connectForTest = (ctx) => import("./main.js").then(m =>
  m._connectForTest(ctx))` so existing test destructures keep working. Tests
  exercise the full path anyway; loading main there is fine.
- **`session/room_keeper.ts`** dynamic-imports `../index.js` for
  `_mapAgentMessagesToEvents` (today: cycle avoidance). Retarget to
  `../main.js` so keeper sync does not pull the entry's forwarders.
- **`probeListPeers`, `routeClientMessage`, `_handleControl`,
  `_restartSupervisorCommand`, `CTRL_PREFIX`** — move to main.ts; entry
  forwards the ones with external callers (`probeListPeers` for
  `session/e2e.test.ts`), the rest are internal to main.

## Steps

### Step 0 — Baseline numbers

- Build (`pnpm --dir pi-extension build`) and record the three timings from
  the Context table on this machine, using the issue's fast-fail recipe:
  ```
  pi --offline --no-extensions -e <abs>/dist/index.js --provider x --model y -p hi
  ```
  vs the same without `-e` (baseline).
- **AC**: before/after table exists for the PR description; methodology
  identical for both runs.

### Step 1 — Mechanical move to `src/main.ts`

- Move the monolith body (everything except the new thin factory) to
  `src/main.ts`. Keep function bodies byte-identical; only imports/exports
  are touched. Write the new thin `src/index.ts` per "Entry rules".
- Retarget `session/room_keeper.ts` to `../main.js`.
- **AC**: `pnpm typecheck` green; `pnpm test` green (test files updated only
  where Step 1 requires: room_keeper retarget + any import of moved symbols).

### Step 2 — Verify the lazy boundary holds

- Add a vitest guard: import `./index.js` fresh, assert light accessors work
  and that `vi.mock("./transport/relay_client.js", ...)` factory **is never
  invoked** (proves relay_client was not loaded) until a heavy hook is called.
- **AC**: guard test green; `node -e "await import('.../dist/index.js')"`
  wall time well under 300 ms warm.

### Step 3 — No-behavior-change verification

- Full `pnpm test` (vitest) green, including `extension.test.ts`,
  `show_file/show_image/ping/e2e`.
- Manual smoke checklist (interactive pi in a configured dir + second session):
  - [ ] auto-start on session_start (`Relay: connected` footer without typing
        `/remote-pi`)
  - [ ] `/remote-pi pair` renders QR; phone connects
  - [ ] `/remote-pi stop` then `/remote-pi` reconnects
  - [ ] `agent_send` / `list_peers` between two local sessions
  - [ ] `remote-pi` bin: `devices`, `revoke <shortid>` (CLI bootstrap path)
  - [ ] daemon: `/remote-pi daemon start` via supervisor
- **AC**: issue's "no behavior change" criterion met; checklist in PR.

### Step 4 — Final measurement + docs

- Re-run Step 0 recipe; record after-numbers.
- **AC**: marginal startup cost ≤ 0.3 s (target from issue #61); numbers in
  the PR close the loop with the issue.

## DoD

- All issue #61 acceptance criteria met:
  - marginal `pi -e dist/index.js` cost ≤ 0.3 s
  - no behavior change (Step 3 checklist)
  - `pnpm typecheck` + `pnpm test` green
  - no new static imports in the entry beyond registration needs
- `src/index.ts` is a few hundred lines; `src/main.ts` contains the moved
  monolith with byte-identical bodies.

## Risks / notes

- **Test churn is bounded**: tests keep importing `./index.js` for the default
  export and light accessors; heavy hooks keep their names via forwarders.
  The one intentional retarget is room_keeper (cycle edge moves to main).
- **vitest mocks** apply to dynamic imports too, so `vi.mock` of internal
  modules keeps working inside main.ts.
- **tsc import elision**: the entry must use `import type` for anything from
  heavy modules; a single value import re-opens the static edge. The Step 2
  guard catches regressions.
- **`bin: remote-pi → dist/index.js`**: CLI invocations load main via the
  `_isDirectRun()` block; CLI startup was never the bottleneck.
- **Top-level await** in the entry's CLI block is safe under pi: the block is
  gated by `_isDirectRun()` (false when pi loads the module), so pi's awaited
  import never waits on it.

## Next plans

- **Domain split of `main.ts`** (lifecycle, relay, images, session_sync,
  commands): now unblocked and orthogonal to perf; do it as separate plans
  with tests moving per domain. Not required for issue #61.
- Optional micro-trim: split `pairing/qr.ts` into URI building (pure) and
  terminal rendering (qrcode-terminal) so `/remote-pi pair` loads lighter.
