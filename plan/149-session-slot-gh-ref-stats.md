# Plan 149: Home session slot (GitHub ref + activity stats)

## Context

Every tile in the Home list carries a 40px round avatar with the first
letter of the session name. It adds nothing: the letter comes from the
same string as the title next to it, so a list of `remote-pi` sessions
shows five identical `R`. The most expensive spot in the row is wasted,
and the list still has no answer to two questions a user asks while
scanning: **which session is this piece of work?** and **how much has
happened in it?**

User decision (2026-10-23): the slot becomes an information slot.

- **Storage slots**: the session must be able to store an Issue
  (number + URL) and a Pull Request (number + URL). Both are kept, the
  PR wins the display.
- **Display**: three lines inside the slot. With a ref: ref line, then
  activity numbers. Without a ref: the numbers mix (turns, user
  messages, unread).
- **Scope**: online AND offline/keeper sessions, so the offline list
  (plan/140) gets the same overview, not just the live one.
- **Fallback chain**: `gh_ref` → numbers mix → the old initial letter
  for legacy Pis that publish neither.

The ref is also the best cleanup signal plan/148 has: an open PR means
the worktree is alive, three turns with no ref means it is junk.

## Data source

- **`room_meta.gh_ref`**: new opaque meta blob, same pipeline as
  `run_done` (plan/132) and `context_usage` (plan/115): extension →
  `RoomMeta`/`RoomMetaPatch` (relay) → Dart protocol → `RoomInfo`.
- **`room_meta.stats`**: `{ turns, user_msgs }` counted inside the
  extension, pushed only at turn boundaries (same throttle idea as
  `working`), never per message.
- **Unread**: phone-local only. A `lastReadSeq` marker per
  `(epk, roomId)`; unread counts local message rows past that marker.
  Phone-local means it stays correct while the PC is off.
- **Persistence**: the PC rooms registry (plan/140) is the source of
  truth for `gh_ref` + `stats`; the app keeps a phone-side cache of the
  last known values so an offline tile still renders numbers. Keeper
  rooms already serve meta from the registry.
- **Not counted on the phone from synced messages**: `session_sync`
  returns only the latest 30 events (plan/111), so phone-side totals
  would be systematically too low.

## Expected structure

### Ingest (three ways, all optional)

- **Manual**: long-press sheet gains "Link Issue / PR" (URL or
  `owner/repo#123`). Works for old sessions, works offline (queued to
  the registry on reconnect).
- **`gh pr view`**: run against the session's worktree branch during
  the plan/107b git refresh. Authoritative, best-effort: if `gh` is
  missing or unauthed, nothing changes and nothing errors.
- **Message scan**: full `github.com/<owner>/<repo>/issues|pull/<n>`
  URLs and `owner/repo#123` produce a *suggestion* carrying its source.
  A bare `#123` is never enough on its own: plan text is full of issue
  numbers that belong to other repos.

### Display (`_SessionSlot` replaces `_Avatar`)

- Shape: rounded square, about 44px, three mono lines. Three readable
  lines do not fit inside a 40px circle.
- With ref (line 1, PR first, Issue only when there is no PR):
  `PR45` in accent colour, tap opens the URL.
- Line 2: turn count. Line 3: user messages and unread as `17·3`.
- Without ref: line 1 shows turns, so all three lines stay numbers.
- Unknown values render as `·` placeholders, keeping the row height
  stable instead of collapsing the slot.

## Steps

1. Extension: turn + user-message counters into `ext.myRoomMeta.stats`,
   throttled to turn boundaries; persist `stats` and `gh_ref` into the
   rooms registry entry so they survive a restart.
2. Extension: ingest handlers (`set_session_ref` for the manual path,
   `gh pr view` on git refresh, scan suggester) behind one precedence
   rule: PR > Issue, manual > gh > suggestion.
3. Relay: add `gh_ref` and `stats` to `RoomMeta` and `RoomMetaPatch`
   with the `Option<Option<_>>` clear semantics used by `git`.
4. App protocol: parse both fields into `RoomInfo`, merge into the
   phone cache for offline tiles (same pattern as the plan/140 keeper
   marker).
5. App UI: `_SessionSlot` widget with the fallback chain, tap-to-open
   for the ref, `lastReadSeq` marker written when a session is opened.
6. Plan/148 bridge: the cleanup confirmation dialog shows the stored
   ref; an open PR adds a warning line (still user-overridable).

### Acceptance criteria

- A session with `pr: {number: 45}` renders `PR45` on line 1; with only
  an issue it renders the issue number; with neither it renders the
  three numbers; with no meta at all the old initial letter renders.
- Tapping the ref opens the stored URL; long-press still opens the
  context sheet.
- Offline and keeper tiles show the last cached ref and numbers; no
  empty slot appears just because the PC is off.
- A message containing only `#123` never creates a ref; the same
  message with `owner/repo#123` produces a visible suggestion with its
  source, not a silent write.
- `gh pr view` failure (no binary, no auth, not a repo) changes nothing
  and surfaces no error.
- Counters do not push on every message inside a single turn; unread
  resets to 0 when the session is opened on this phone.
- `flutter analyze` clean, `flutter test` green, extension vitest and
  relay `cargo test` green.

## DoD

- [ ] Extension counters + ingest + registry persistence
- [ ] Relay `gh_ref` / `stats` fields
- [ ] Dart protocol + phone cache
- [ ] `_SessionSlot` widget + fallback chain + tap-to-open
- [ ] Unread marker read/write
- [ ] Plan/148 dialog bridge
- [ ] Tests: protocol parse, precedence, scan false-positive guard,
      fallback chain, offline cache, counter throttle
- [ ] Device review

## Next plans

- Ref lifecycle: refresh PR state (open/merged/closed) and badge the
  slot accordingly; clear a ref when the PR closes.
- Exact offline numbers on demand: count from the plan/128 file index
  via an RPC when the cached counters are known-stale.
- Batch cleanup (plan/148 follow-up) can filter on "no ref and under N
  turns" as the junk heuristic.
