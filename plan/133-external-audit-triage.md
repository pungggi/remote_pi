# Plan 133 — External audit triage (ydtb 2026-07-13 review vs our tree)

**Status:** proposed · **Source:** [`review/forks-2026-08-27.md`](../review/forks-2026-08-27.md) ·
**Audit:** [yourdigitaltoolbox/remote_pi `audit/2026-07-13-code-review.md`](https://github.com/yourdigitaltoolbox/remote_pi/blob/main/audit/2026-07-13-code-review.md) (their issues #4–#10)

## Context

A third-party fork commissioned a serious code review of `pi-extension` at
their v0.5.5 (2026-07-13): 4 subsystem readers + a crypto pass, findings
filed with file:line evidence. We share most of that code's ancestry. The
audit's trust theme — *the relay is trusted to assert identity fields it
should not be trusted for* — is the same theme our plan/130 attacked
independently two days later (2026-08-14 review, shipped in PRs #24/#25).

The audit is against **their** fork: it includes machinery we don't have
(relay-exposure leases — their H2 is N/A here) and predates both our v2
signatures and upstream's 0.7 refactor. Every finding below needs a verdict
against **our 0.8.0 tree** before any fix.

Initial verification already done (evidence in brackets):

| Their finding | Verdict here | Evidence |
|---|---|---|
| C1 relay forges app→Pi frames (`approve_tool` → RCE) | **closed, stronger than their fix** | plan/130: inner `sig`/`sig2` (dest-bound v2), replay window + seen-id LRU, dual-sign transition, ratchet warm-await |
| C2 `pair_request` unsigned (QR token only) | **likely closed** — proof-of-possession via v2 sig bound to the claimed epk; `signing: true` persisted on signed pairs | `index.ts:2192` `_handlePairRequest` + auto-listener v2 check. Step 1 must confirm the listener verifies the sig against the *claimed* epk (not a known-peer map), and reason about the unsigned-transition window for **first** pairing |
| C3 relay forges `from:"broker"` envelopes via `from_pc:"_relay"` | **open?** — plan/130 signed app↔Pi frames, not the cross-PC `broker_remote` inject path | `session/broker_remote.ts` `_relay` branch |
| H1 `siblings.ts` skips owner-slot check (`sha256(ownerPk)` mismatch unverified) | **open?** — one-line fix per audit | `mesh/siblings.ts` vs `self_revoke.ts` which does check |
| H2 lease workspace scoping | **N/A** — their feature, not ours |
| H3 child stdin EPIPE crashes supervisor | **open** — writes with no error handler on `stdin` | `daemon/rpc_child.ts:335-338, 399-408` |
| H4 Windows control pipe squattable / silent DoS | **partially open** — DACL claim unverified; exit 0 on already-running confirmed | `daemon/supervisor.ts:249` claim, `bin/supervisord.ts:89-91` `process.exit(0)` |
| M3 leader-election stale-socket unlink race (split-brain) | **open** — check-then-unlink without inode recheck | `session/leader_election.ts:111-114` `_removeStaleSock` |
| M4 `Broker.close()` hangs with unregistered connections | **open?** | `session/broker.ts:283-286` |
| M7 supervisor gaps (backoff not cancelled on stop; restart budget never resets; control-buffer double-run) | **open?** | `daemon/supervisor.ts` |
| Lows: `peers.json` 0644 non-atomic · NUL ctrl channel accepts app-sourced renames · relay URL userinfo leaks to logs · predictable `remote-pi-mcp-<pid>.json` tmp · `_messageBuffer` unbounded (inline images) · `PI_SUBAGENT_CHILD=""` fails open | **open?** each | `pairing/storage.ts`, `index.ts`, `cron_registry.ts`, `child_policy.ts` |

## Expected structure

No new modules. Fixes land in the touched files, each with a regression test.
Windows-specific fixes reuse the P/Invoke machinery from the PR #124 port
(`session/socket_owner_windows.ts` — `GetNamedPipeServerProcessId` lookup).

## Steps

### 1. Verdict pass — every row of the table above gets `fixed | open | N/A` with our file:line

Re-verify against `main` **after** the pending upstream sync (the audit's
line numbers are v0.5.5; upstream 0.7 moved code). Produce
`review/audit-triage-133.md` with one section per finding: quoted audit
claim, our evidence, verdict, proposed fix or explicit wontfix rationale.

**Acceptance:** no `open?` left in the table; C3 and H1 verified by reading
the actual verify path (not comments); C2's first-pairing transition window
reasoned about explicitly (who can pair, what a malicious relay can strip).

### 2. H4 — Windows supervisor pipe: verify the DACL claim, fix the silent-DoS exit

- **Verify** `supervisor.ts:249` ("libuv DACL already restricts to the
  user"): empirically on this machine — create the pipe name from a second
  process, check `Get-Acl \\.\pipe\…` / connect as another user if a test
  account exists; otherwise verify against libuv source (`uv_pipe_bind` →
  `CreateNamedPipeW` security attributes) and document.
- **Squatting ≠ ACL:** even a correct DACL doesn't stop *name squatting* by
  another user before our supervisor starts (names are machine-global,
  creation is first-wins). Today the probe-then-`exit(0)` path
  (`bin/supervisord.ts:89-91`) turns a squatter into a **silent permanent
  DoS** — Task Scheduler sees success and never retries.
- **Fix:** on `SupervisorAlreadyRunningError`, verify the existing listener
  is *ours*: reuse `socket_owner_windows.ts` to resolve the owning PID and
  compare the binary path against our own `process.execPath`/supervisord
  install. Owner mismatch → **non-zero exit with a loud one-line diagnostic**
  (name, owning PID, path). Keep `exit(0)` only for a verified-ours listener.
- POSIX parity: the 0700 dir gate already covers other users; same-owner
  squatting is same-privilege (document as accepted).

**Acceptance:** unit test with an injected fake listener: ours → exit 0
silent; foreign owner → non-zero + diagnostic names the squatter. Manual
note in `review/audit-triage-133.md` of the DACL experiment result.

### 3. H3 — `rpc_child` stdin: no unhandled `'error'`, no fire-and-forget writes

Attach an `'error'` handler on `child.stdin` that transitions the child to
`dead` (existing crash path), and give every `stdin.write` a callback that
maps EPIPE to the same transition instead of throwing.

**Acceptance:** test that kills the child between state check and write
flush; supervisor survives and reports the daemon dead (not crashed).

### 4. M3 + M4 — broker lifecycle races

- M3: `_removeStaleSock` rechecks with `lstatSync` immediately before
  `unlinkSync` AND after a failed bind treats "still held" as
  already-running (never unlinks twice, never unlinks a live leader's
  socket without a re-stat confirming it's still the stale inode — pin
  `dev`/`ino` from the failed-probe stat, like the daemon registry does).
- M4: `Broker.close()` destroys *unregistered* sockets too (track observer
  probes from `_tryObserverProbe`) and takes an overall timeout after which
  it force-destroys everything remaining.

**Acceptance:** regression tests: (a) two contenders, failed probe → no
unlink of a re-bound live socket; (b) `close()` resolves while an observer
probe socket is open (today it hangs — the test would time out).

### 5. C3 + H1 if verified open

- C3: the `from_pc:"_relay"` inject path must reject any envelope whose
  `from` is `"broker"` (or any local-trusted route) and only carry
  `transport_error`-typed bodies.
- H1: `discoverSiblings`/`discoverSelfLabel` check `sha256(header.ownerPk)`
  against the queried hash slot, exactly like `self_revoke.ts:228-234`.

**Acceptance:** tests with a relay that serves attacker-signed blobs at the
owner slot (reuse `make_mesh_siblings` fixtures) and a `_relay` envelope
claiming `from:"broker"`.

### 6. Lows sweep + upstream contributions

Fix the cheap lows in one pass (atomic `peers.json` write, redact userinfo,
`mkdtemp` for MCP tmp config, gate NUL-ctrl on non-`extension` sources,
bound `_messageBuffer`, fail `PI_SUBAGENT_CHILD=""` closed, cancel backoff
timer on stop / reset restart budget on healthy uptime). Anything that
isn't Piper-specific goes back upstream per `FORK.md`: branch from
`upstream/main`, cherry-pick, PR — our 100-series identity divergence must
not leak into those branches.

**Acceptance:** `review/audit-triage-133.md` final table all green/N-A;
upstream contribution branches listed.

## DoD

- `pi-extension`: `pnpm typecheck` + `pnpm test` green with the new
  regression tests (889+ baseline from plan/130).
- Every audit finding has a verdict with evidence; fixes merged on `main`
  via a work branch; `dist/` rebuilt.
- Upstream PRs opened for the non-Piper-specific fixes (C3, H1, H3, M3, M4,
  lows) — or an explicit note why not.

## Next plans

- 1xx: TLS on relay (wss + QR-pinned self-signed) — lionweb1989's
  `plan/59-app-relay-tls-wss.md` as blueprint; closes plan/130's deferred
  full-fix-2.
- 1xx: upstream-drift check workflow (leoliu0's `sync-upstream.yml`
  adapted to dry-run + report only).
