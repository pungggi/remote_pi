# Plan 158 — Consolidated session cleanup ("Clean up session")

## Context

The Home list has no clear way to make a **past session disappear for good**.
Every existing path is partial:

- **Delete session (plan/17)** removes the phone-side record only. The PC-side
  registry entry survives, so the keeper re-announces the room and the tile
  reappears (the plan/17 dialog copy even admits it).
- **Delete worktree & branch (plan/148)** removes folder + branch + phone
  record, but the keeper still serves the room from `rooms.json` → the session
  reappears as an archive tile (the plan/148 dialog warns about exactly this).

Root cause (verified in `room_keeper.ts` `sweep()`): the keeper re-opens every
`rooms.json` entry each sweep; each keeper connect fires `room_announced`,
which re-persists the room on the phone. **The PC must forget the room** —
that is plan/148's "Next plans" `forget_room` item.

## User decisions (2026-11-06)

- **One consolidated entry**: the two menu items ("Delete session (local
  only)" + "Delete worktree & branch") are replaced by a single
  **"Clean up session…"** on offline tiles, with a dialog that itemizes what
  will be removed.
- **Chat history on the PC is opt-in, default OFF**: cleanup stops the session
  from SHOWING; transcripts survive as backup unless the user ticks the box.
- **Batch mode ships now**: "Clean up finished sessions…" sweeps every
  eligible offline session in one confirm.

## Expected structure

### PC side (pi-extension)

- **`rooms_registry.ts`**: `forgetRoom(roomId, path?)` — prune one entry,
  persist, return whether it existed. Same best-effort whole-file write as
  `upsertRoom`.
- **New `actions/forget_room.ts`** — `handleForgetRoom(sender, msg)`:
  - Reads the registry entry BEFORE pruning (needs `cwd` + `sessionId`).
  - `forgetRoom(room_id)` → `registry_removed`.
  - When `delete_history`: delete the room's transcripts under
    `sessionsRoot()/encodeCwd(entry.cwd)`:
    - **Known `sessionId`** (plan/152 entries): delete `*_<sessionId>.jsonl`
      exactly — no encoded-folder-collision risk.
    - **Unknown `sessionId`** (pre-plan/152): delete the whole encoded folder
      — it is the cwd's folder by construction; documented corner case.
    - Report the truth either way: `history_removed` +
      `history_note` ("deleted" / "kept: unknown session id" / "kept: not found").
  - Never touches a LIVE room by itself: the handler is deliberately
    stateless about liveness (the daemon cannot see relay presence). The
    app-side guard (plan/148, reused and extended) is the protection; the
    handler stays idempotent (retry answers ok:true with
    `registry_removed: false`).
  - Replies `forget_room_result { id, ok, registry_removed, history_removed?,
    history_note?, message? }`. Keeper release needs no RPC: the next sweep
    re-reads the registry and releases the pruned room as "stale" (≤60 s).
- **`protocol/types.ts` + `codec.ts`**: `forget_room_request { id, room_id,
  delete_history? }` / `forget_room_result`.
- **`main.ts`**: dispatch `forget_room_request` next to
  `remove_worktree_request` (device daemon path, same as plan/148).

### Phone side (app)

- **`protocol/protocol.dart`**: parse `forget_room_result`; expose
  `ForgetRoomResult`.
- **`ActionsRepository`**: `forgetRoom(roomId, {deleteHistory})`.
- **`HomeViewModel`**:
  - `cleanupSession(...)`: the consolidated function — route to peer
    (`_routeToPeer`), liveness guard (`_liveWorktreeOwner` semantics reused,
    extended to "any same-peer live session in the same cwd" even without a
    worktree), then:
    1. worktree tracked → `removeWorktree(worktree.id)` (unchecked box skips),
    2. `forgetRoom(roomId, deleteHistory: …)`,
    3. `deleteRoom(epk, roomId)` (plan/17 path) — always, on success.
    Failure modes: PC unreachable / git refusal → nothing deleted except what
    already succeeded; each step is idempotent so retry continues where it
    stopped.
  - `cleanupFinishedSessions(items, {deleteHistory})`: batch — groups items
    per peer, routes once per peer, executes the per-session cleanup
    sequentially, collects per-item results. One item's failure never aborts
    the batch.
  - `mayOfferCleanup` / `findWorktreeFor` reused as-is for tap-time validation.
- **`cleanup_session_dialog.dart`** (new, replaces `CleanupWorktreeDialog` on
  the Home path): itemized checkboxes —
  - ☑ Worktree folder + branch `<branch>` (row hidden when untracked),
  - ☐ Chat history on the computer (default OFF),
  - fixed rows: "The computer forgets this session (it won't reappear)" and
    "Phone copy removed",
  - keeps plan/148's open-PR warning when `ghRef` is linked.
- **`cleanup_batch_sheet.dart`** (new): eligible offline tiles (checkboxes,
  pre-checked; per-tile dirty/unknown hint after fetch), shared
  "delete history too" toggle, confirm → progress → per-tile ✓/✗ summary.
- **`home_page.dart`**:
  - Long-press sheet (offline): drop the two old entries, add one
    **"Clean up session…"** (`LucideIcons.eraser`-style icon).
  - App bar: batch entry — icon shown when at least one offline tile exists;
    the sheet refines eligibility at tap time (registry fetch per peer).
  - Keep the plan/17 "Delete session (local only)" for LIVE rooms? No — live
    rooms never offered delete anyway (disabled entry today). The consolidated
    entry fully replaces both offline entries; live rooms keep only
    Rename / Open terminal / Revive.

## Steps

1. [x] Extension: `forgetRoom` in `rooms_registry.ts` + unit tests (prune,
       missing id, corrupt file).
2. [x] Extension: `forget_room` action + handler + codec round-trip tests
       (history deleted by sessionId / whole folder / kept variants;
       registry entry missing → ok with note).
3. [x] App protocol: parse + repository call (+ parse tests).
4. [x] `HomeViewModel.cleanupSession` + tests (worktree path, no-worktree
       path, skip-worktree flag, history flag, git-refusal partial state,
       forget refusal, live-owner abort at root/nested/same-cwd, PC
       unreachable).
5. [x] `HomeViewModel.cleanupFinishedSessions` + `batchCleanupCandidates`
       + tests (worktree match refinement, live-room skip, unreachable PC
       reported, per-item isolation, summary shape).
6. [x] Dialog + batch sheet widgets + widget tests (itemized copy, PR
       warning, default-off history, batch eligibility + results).
7. [x] `home_page.dart` rewiring + removal of the old entries + batch
       app-bar action; `flutter analyze` clean (no new issues), full app
       suite (1026) + extension suite (1241) green.
8. [x] Changelog entries (root + app/assets).

### Acceptance criteria

- Long-press offline tile → "Clean up session…" → confirm: worktree + branch
  gone (when tracked), `rooms.json` entry pruned, keeper releases the room on
  its next sweep, tile gone and NEVER reappears (cold start, relay restart).
- History checkbox OFF (default): transcripts survive on the PC.
- Batch: every pre-checked offline tile with a tracked worktree is cleaned;
  failures are reported per tile without aborting the rest.
- Online rooms offer no cleanup entry; live-owner race aborts with
  "nothing was removed" (plan/148 semantics preserved).

## DoD

- [x] Steps 1–8 done, suites green on both sides.
- [x] Changelog entries.
- [ ] Device review (real resurrection test: clean a keeper-held session,
      restart relay + app, tile stays gone).

## Next plans

- `--force` passthrough for dirty worktrees (carried over from plan/148).
- Batch eligibility hint ("3 merged branches") fetched up front.
- PC-side `forget_room` for a whole PROJECT folder (remove every room under a
  cwd prefix) for after a repo is deleted locally.
