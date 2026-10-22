# Plan 145 — Delivery ledger: sequenced frames, gap-driven replay, state-driven ask recovery

## Context

Recurring symptom class (latest: screenshot 2026-10-21 22:51): the phone shows
**"Waiting for your answer…"** with **no ask_user sheet and no recovery card**,
and separately: agent responses never arrive ("verschluckt"). Plans 137, 139,
140 and 141 each closed one hole (TTL, attach replay, route_error, mailbox,
run_done→sync, keeper). The class keeps coming back because every healer is a
**heuristic**: timers and indirect signals that guess a loss happened.

### Verified structural gaps (code inspection 2026-10-21, main @ dbf25ea1)

- **G1 — No delivery ledger.** `_broadcastToActive` (`pi-extension/src/main.ts:1087`)
  stamps no sequence number. The app cannot distinguish "quiet" from "lost".
  Each healer has a blind spot: `run_done→sync` only covers the *active* room
  and only fires when a turn *ends*; sync-on-online-edge needs the app to
  notice the edge first; relay `registry.forward` counts an mpsc accept as
  success, so the last few frames into a half-dead app socket vanish before
  the write failure kills the conn task (mailbox only kicks in afterwards).
- **G2 — The ask_user recovery card is event-derived, not state-derived.**
  `_needsAskRecovery` (`chat_viewmodel.dart`) requires a pending `ask_user`
  `ToolEvent` **in the local DB**. The tool-start frame and the
  `extension_ui_request` frame leave the extension milliseconds apart: one
  socket flap kills both (correlated loss). The pill stays on because room
  meta is durable state, but no sheet and no card render. Worse: the turn is
  blocked inside the tool, so `run_done` never fires, no online-edge happens,
  and no sync is ever triggered. That is exactly the screenshot deadlock.
- **G3 — Silent drops, zero telemetry.** `PeerChannel._handleFrame` swallows
  decode/cast errors with no counter. Every incident requires hand-stitching
  relay.log + `ext-<room>.log` + logcat.

### Root cause statement

The transport is best-effort and the healers are turn-bound. Any loss that
(a) happens mid-turn and (b) prevents the turn from ending is invisible to
every existing healer. The fix is to make loss **detectable** (sequence every
frame) and **healable on demand** (sender-side journal replay), plus to drive
the ask_user affordance from the one channel that already survives every
failure: durable room meta.

### Decisions (user interview 2026-10-21)

| # | Decision |
|---|---|
| 1 | **Full ledger + state card** in one plan (not app-only first). |
| 2 | **Journal replay by the extension** heals detected gaps; full `session_sync` is only the fallback for journal overflow / epoch change. |

## Expected structure

### Invariants

1. **Every owner-bound broadcast frame carries `(epoch, seq)`**: a per-room
   monotonically increasing `seq` and the session's `epoch`
   (`ext.sessionStartedAt`, already the restart detector). Stamped exactly
   once, at the single choke point `_broadcastToActive` (the bridge
   trampoline routes through it, so `extension_ui_request` is covered).
2. **Per-sender replies are NOT stamped**: `session_history`,
   `pendingRequests()` replays, attach-time queued state. They are answers to
   a query, not stream members.
3. **The app applies stamped frames strictly in seq order.** Ahead-of-gap
   frames are held (not applied): the ordered journal replay re-delivers
   them. No reorder buffer needed.
4. **The extension keeps a bounded in-memory journal** of stamped frames per
   room and replays from it when a client reports it is behind. Journal
   overflow or epoch mismatch degrades to a `sync_needed` nudge (today's full
   `session_sync` merge stays the SSOT backstop).
5. **Durable room meta drives the ask_user affordance.** The recovery card
   keys off `waiting_for_input`, not off a `ToolEvent` row.

### Wave 1 — pi-extension: stamp, journal, `report_seq` handler

- **Stamping**: `_broadcastToActive` assigns `msg.seq = ++ext.roomSeq` and
  `msg.epoch = ext.sessionStartedAt` (skip when `sessionStartedAt == null`).
  `roomSeq` resets per session start; `epoch` disambiguates across restarts.
  Wire keys: `seq`, `epoch` (both optional in the protocol types: old apps
  ignore them, old extensions don't send them; the app degrades to today's
  heuristic healers when unstamped).
- **Journal**: `ext.roomJournal`: ring of the last **2048 stamped frames**
  (~2000 chunk frames ≈ one heavy turn; memory-bound, per room, dropped on
  `_goIdle`/rebind). Journal membership == went through `_broadcastToActive`.
- **New ClientMessage `report_seq`**: `{ type: "report_seq", id, seq, epoch }`.
  Handled per sender channel, before the strict guards (same early-dispatch
  spot as `session_sync`):
  - `epoch != ext.sessionStartedAt` → reply `{ type: "sync_needed", reason:
    "epoch" }`.
  - `seq >= roomSeq` → no-op (client is current); update channel bookkeeping.
  - Journal covers `(seq, roomSeq]` → `sender.send()` each frame in order.
    Frames keep their **original** stamps (replays, not new stream members).
  - Journal's oldest `> seq + 1` → reply `sync_needed` (reason `"overflow"`).
  - Rate-limit replay bursts: max one per channel per 2 s; concurrent reports
    within a burst collapse to the latest.
- **`session_history` reply gains `current_seq: roomSeq`** so the app
  re-baselines atomically with the history merge. This closes the sync race:
  a frame broadcast during sync computation is either inside the snapshot
  (app drops its live copy via the seq rule) or after it (`seq ==
  current+1`, applies cleanly).
- **Log**: one `_relayLog` line per replay burst (`replay 12..47 to owner`)
  and per `sync_needed`.

**Acceptance (vitest)**: stamps are monotonic per room and reset on rebind;
unicast replies unstamped; `report_seq` replays exactly the missing range in
order; overflow → `sync_needed`; epoch mismatch → `sync_needed`; burst
rate-limit collapses; `session_history` carries `current_seq`. `pnpm --dir
pi-extension test` + typecheck green.

### Wave 2 — app: ordered apply, gap reports, state-driven card, telemetry

- **Parse** optional `seq`/`epoch` on every server message (keep them off the
  sealed-class equality: store in a side wrapper or a `ServerFrameMeta`
  carried alongside, so existing `==`/tests are untouched).
- **Per-room ledger state** in `SyncService` (persisted in the runtime box so
  process restarts don't re-baseline wrongly): `_epoch`, `_contig` (last
  contiguously applied seq).
- **Apply rule** for stamped frames:
  - `epoch != _epoch` → re-baseline (`_epoch = epoch`, `_contig = seq - 1`),
    process the frame, trigger the existing full-sync path (session restart
    detection already does this via `session_started_at`; the two signals
    agree).
  - `seq <= _contig` → duplicate (journal/mailbox replay): **drop**, count.
    This subsumes the id-LRU for stamped frames; the LRU stays for unstamped
    traffic. (`extension_ui_request` keeps its existing exemption semantics:
    *unicast* pendingRequests replays are unstamped and unaffected.)
  - `seq > _contig + 1` → gap: hold the frame in a small per-room pending map
    (cap 64, FIFO-evict counting drops), send `report_seq` (min spacing 1 s),
    count. Held frames apply in order as replays fill the hole; a held frame
    whose hole is declared overflow (`sync_needed`) flushes via the full sync.
  - `seq == _contig + 1` → apply, advance, then drain any newly-contiguous
    held frames.
- **`sync_needed`** → `requestSync()` (existing guards/retry).
- **Periodic tail report**: while the chat is open and online, send
  `report_seq(_contig)` every **15 s** (paused when backgrounded; also fired
  once on each online edge after the sync). This is the healer for the tail
  case: the blocked turn emits no further frames, but the next report tells
  the extension we're behind and it replays the sheet/chunk tail. Cancels on
  dispose.
- **`session_history` merge**: after applying the snapshot, set
  `_contig = max(_contig, current_seq)` under the epoch check.
- **State-driven ask recovery card** (`_needsAskRecovery` rewrite):
  `waitingForInput(meta, live room) && currentExtensionUiRequest == null &&
  connection == online`, 3 s debounce reusing `askRecoveryDelay`. The
  `ToolEvent`-in-DB requirement is **dropped** (it was the G2 failure). Card
  actions unchanged: Retry → `requestSync()` + immediate `report_seq`;
  Cancel question → existing cancel. Keep the old ToolEvent path as an
  *additional* trigger with zero delay removed... (no: single condition, one
  behavior, fewer states).
- **Telemetry**: per-room counters (`framesStamped`, `dupsDropped`,
  `gapsDetected`, `heldApplied`, `reportsSent`, `replaysReceived`,
  `syncNeeded`, `decodeDrops`) in `SyncService` + one counter in
  `PeerChannel._handleFrame`'s catch. Surface them in the session-info/debug
  area (plan/107's ℹ dialog or the plan/138 diagnostics page, whichever the
  app subproject already renders) and as `debugPrint` breadcrumbs
  (`[ledger] room=… gap 41→45, report sent`).

**Acceptance (flutter test)**: stamped parse tolerates missing fields;
in-order apply advances; gap holds + reports + ordered replay completes;
duplicate replay dropped without double-applying an `agent_chunk`; epoch
change re-baselines; `current_seq` merge; periodic report fires only while
open+online; recovery card shows with **no** ask_user ToolEvent present when
waiting meta is true, hides when the sheet arrives or waiting clears;
counters move. `dart analyze` clean, full suite green.

### Wave 3 — relay: eager dead-sender eviction (micro)

`registry.forward` already mailboxes when `tx.send` errors
(`registry.rs:284-307`). Remaining polish: when a send fails, **evict that
conn from the sender vec immediately** so the next frame mailboxes instead of
being offered to a known-dead channel (today it retries the dead tx on every
frame until the conn task's own cleanup runs).

**Acceptance (cargo test)**: a closed sender is evicted on first failed
forward; the following forward miss mailboxes. clippy clean.

### Wave 4 — docs + ops

- `PROTOCOL.md`: `seq`/`epoch` stamping rules, `report_seq`, `sync_needed`,
  the ordered-apply contract, journal bounds, and the "unicast answers are
  unstamped" rule.
- Ops note (same lesson as plan/137): long-lived TUI sessions keep the
  extension they loaded at startup. After rebuilding `dist/`, restart or
  reload those sessions or they keep emitting **unstamped** frames and the
  phone silently stays on heuristic healing.

## Implementation status (2026-10-21/22)

- **Wave 1 — DONE.** pi-extension: stamps at `_broadcastToActive` (skipped
  while no session started), 2048-ring journal (`REMOTE_PI_JOURNAL_MAX`),
  `report_seq` → ordered unicast replay (2 s/channel burst limit,
  collapse-to-latest), `sync_needed` (epoch|overflow),
  `session_history.current_seq`, ledger restart in `_resetSessionForNew`.
  New `src/delivery_ledger.test.ts` (14 tests). Typecheck clean; full suite
  green except two PRE-EXISTING mesh-timing flakes (fail identically on
  clean main: "session_start auto-init … auto-starts the mesh", "relay
  reconnect … stop cancels pending mesh join") — worth their own plan.
- **Wave 2 — DONE.** App: `ServerMessage` base lost `const` (mutable
  `ledgerSeq`/`ledgerEpoch` attached in `fromJson`; one ripple:
  `ExtensionUiRequest` dropped its `const` ctor, 4 test files adjusted).
  SyncService: ordered-apply gate (hold cap 64), 5 s hold escape → full
  sync, gap reports (1 s throttle), 15 s tail report (foreground-refcounted
  via `setChatForeground`, called from ChatViewModel ctor/dispose), history
  `current_seq` baseline, `sync_needed` → `requestSync`, `ledgerStats`
  telemetry. PeerChannel: `decodeDrops`/`unsupportedTypeDrops`. Recovery
  card is now state-driven (`_trackAskRecovery`: waiting meta ∧ no sheet ∧
  online, 3 s debounce). Session-info dialog shows a Ledger row.
  **Deviation from the plan text**: the cursor is in-memory only (NOT
  persisted in the runtime box) — a per-frame disk write was rejected; the
  adopt-first-frame rule + history `current_seq` baseline cover restarts.
  New `test/data/sync/sync_ledger_test.dart` (12 tests); the plan/137
  recovery tests were rewritten to the state-driven semantics (they must
  seed `RoomAnnounced` first — meta patches to unknown rooms are ignored).
  `flutter analyze` clean; full suite 845/845 green.
  Fixed during implementation: tracker heartbeat re-arm bug (a pending
  timer occupied the slot across an idle window, shifting the next
  window's debounce) → arm only while pending + cancel on inactive.
- **Wave 3 — DONE.** Relay already mailboxed on send-failure; added eager
  dead-sender eviction in `registry.forward` (+ `sender_count` test seam,
  `forward_evicts_dead_sender_eagerly`). Full cargo suite + clippy green.
- **Wave 4 — DONE.** PROTOCOL.md §"Ledger de entrega"; ops note included.
- **PENDING — on-device verification matrix (a)–(e).** Requires: rebuilt
  extension in the live session (`pnpm --dir pi-extension build`, then
  restart the TUI session) + new app build on the phone.

## Steps (com critério de aceite)

1. **Wave 1** ext. *Aceite*: vitest bullets above green.
2. **Wave 2** app (can start once the wire keys are fixed by Wave 1's types).
   *Aceite*: flutter bullets above green.
3. **Wave 3** relay micro-fix. *Aceite*: cargo bullets green.
4. **Wave 4** docs. *Aceite*: PROTOCOL.md renders the new frames; plan
   updated with implementation notes.
5. **On-device verification matrix**:
   - (a) Reproduce the screenshot: fire `ask_user`, flap the phone's network
     exactly when the sheet is due → pill on, card appears ≤ 3 s, periodic
     report replays the sheet ≤ 15 s without touching anything.
   - (b) Mid-turn airplane-mode 5 s during heavy chunk traffic → no
     duplicated/garbled text, gap counter ≥ 1, chat whole.
   - (c) Blocked `ask_user` + phone offline 30 min → reopen: sheet via
     mailbox/sync as today, no regression.
   - (d) Steering into a dead room still NACKs (route_error) and clears
     `steering…` (plan/137 behavior intact).
   - (e) Old extension (pre-145 dist) with new app: no crash, heuristic
     healers still work (graceful degradation).

## DoD

- [ ] Extension, relay, app suites green (`pnpm test`, `cargo test` + clippy,
      `flutter test` + analyze).
- [ ] Verification matrix (a)–(e) passes on device.
- [ ] The screenshot deadlock is closed twice: the state-driven card renders
      without any ToolEvent, and the periodic `report_seq` replays the lost
      sheet frame on top.
- [ ] Telemetry answers "was something lost, when, and did it heal" from the
      phone alone (no logcat stitching).
- [ ] PROTOCOL.md updated; ops note about restarting long-lived sessions
      recorded.

## Next plans

- **Foreign prompts as answerable cards** (already earmarked by plans
  134/137): with the ledger, `kind`/`title` from `ui_prompt_start` can ride
  room meta and render a generic prompt card on the phone.
- **Bidirectional ledger**: stamp app→pi client messages so a swallowed
  steering message is detectable the same way (today: echo timeout +
  route_error only).
- **Delta history sync**: `session_sync since=<seq>` serving from the journal
  + file index instead of a full page, if the 15 s report cadence ever makes
  full syncs hot.
- Retire heuristic healers that the ledger subsumes (run_done→sync for the
  active room is a candidate once the report path proves itself on device).

## Cross-session input (2026-10-22, from the `mermaid` worktree session)

Device-verified findings that touch this plan; written here so they survive
compaction in this session.

1. **Plan number collision — rename before committing.** The `mermaid` branch
   (PR #63, open) already commits `plan/144-mermaid-diagram-viewer.md`, and
   `plan/146-agent-file-history.md` exists on the same branch. Rename this
   file to `plan/145-delivery-ledger.md` (and code/test references) when you
   commit — otherwise the fork has two "plan/144"s with different meanings.
2. **Late-join `agent_file` loss confirmed on device, exactly your G1
   blind-spot analysis.** Observed: a phone joining mid-session sees the
   `show_file` tool call in history but no bubble — because `agent_file` is
   an extension broadcast that never enters Pi's `.jsonl` transcript, and
   your full-sync fallback replays only that transcript. Journal replay
   heals the in-window case; for overflow / epoch change / app reinstall the
   bubble is still gone → that residual gap is covered by `plan/146`
   (reference-only `agent_file` history records + `agent_file_fetch`
   re-fetch from the PC, user-approved decision: reference, not inline
   payload). **Suggested merge order: this plan first, 146 builds on top** —
   they share touchpoints (`_handleSessionSync`, `protocol/types.ts`,
   `sync_service.dart`), and 146's history merge should emit stamped-frame-
   compatible events.
3. **The `show_file` toolResult in the transcript is a plain string** (e.g.
   `"Showing mermaid file …"`) — you cannot derive file references from it
   during `session_history` assembly. That is why 146 adds an extension-side
   sidecar registry merged into the history timeline instead of parsing
   toolResults.
4. **User report confirming G2**: after a late join they saw the `ask_user`
   tool call in history with no sheet and no recovery card — matches the
   correlated-loss scenario in your Context (both frames lost, turn blocked
   inside the tool, no `run_done`, no sync trigger).
5. Minor: the app build/deploy loop used for ledger device verification is
   documented in the `mermaid` worktree (`.pi/scratch/STATE.md`) — wireless
   adb pairing pitfalls, `tailscale serve --bg <port>` fallback (note: new
   CLI syntax), logcat-driven gesture diagnostics pattern.
