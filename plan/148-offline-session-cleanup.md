# Plan 148 — Offline session cleanup (worktree + branch from the app)

## Context

The Home list shows offline sessions (plan/140 durable directory), and the
user asked the obvious question: what good is SEEING them when you can't
MANAGE them? What exists today:

- **Revive chat** (plan/124): long-press offline tile → resume the existing
  conversation headless in its own cwd. Works.
- **Open terminal** (plan/108/120): long-press → new worktree + NEW branch
  on the PC, even while the room is offline (always-on device daemon).
  User decision (2026-10-23): keep it this way — a fresh, mergeable branch
  per terminal is the desired semantics. No change needed.
- **Delete** (plan/17): removes the phone-side record only. The PC-side
  worktree + branch survive.
- **`remove_worktree`** (plan/112): `git worktree remove` + `git branch -D`
  + registry prune. Fully wired end-to-end (extension handler, app protocol,
  `ActionsRepository.removeWorktree`) — but its only UI is buried in the
  worktree manager sheet inside an OPEN chat. Unreachable from exactly the
  place where the clutter is visible: the offline session list.

**Gap:** one-tap cleanup of a dead session's worktree + branch, offered on
the offline tile, executed through the device daemon (works even though the
room itself is offline).

## User decision (2026-10-23)

- Scope: cleanup from the session list. Terminal-open stays as-is
  (new branch, mergeable) — explicitly NOT a reuse of the old branch.
- Safety: confirmation dialog showing the branch name (+ dirty state when
  known). On git failure nothing is removed; the error message surfaces and
  a force path may follow later.

## User decisions during implementation (2026-10-23)

The gating below was an agent draft, not user-locked. Two rules changed:

- **Keeper gate dropped**: keeper-held (archive) rooms ARE eligible. Keeping
  the gate would have hidden the entry for the most common dead session,
  because the supervisor's keeper holds exactly those rooms. Transcripts live
  in `~/.pi/agent/sessions/<cwd>`, NOT inside the worktree, so removing the
  folder keeps the history readable. Revive (plan/124) stops working
  afterwards, which is inherent to any cleanup.
- **"In use" means a LIVE session**: only another room that is online and
  points at the same folder blocks the entry. Two dead duplicates in the same
  worktree may be cleaned; the leftover tile is removed with the plan/17
  "Delete session (local only)" entry.

## Expected structure

All UI-side work lives in `app/lib/ui/home/` (menu + dialog + viewmodel);
the heavy lifting (matching, action) reuses existing plumbing:

- **Match:** fetch `listWorktrees` (live peer link — the daemon answers even
  for dead rooms) and match `entry.path == room.cwd`. Only a matching entry
  enables the menu item; a session whose cwd is the main checkout (or an
  unregistered folder) gets no cleanup option.
- **Gating:** offered only when the room is offline AND the folder is a
  registry match AND no other LIVE session owns that folder. Keeper mirrors
  count as offline, so they are eligible (see the implementation decisions).
- **Race guard:** the session may come back online between opening the menu
  and confirming the dialog. The action re-checks liveness at execute time and
  aborts with "nothing was removed" instead of deleting a live worktree.
- **Dialog:** branch name, base repo, folder path, and an explicit "files
  will be deleted" warning. Own widget in
  `app/lib/ui/home/widgets/cleanup_worktree_dialog.dart` so a widget test can
  pump it without a full Home tree.
- **Execute:** `removeWorktree(worktreeId)`; on `ok` also drop the
  phone-side room record (reuse the plan/17 delete path) so the tile
  disappears in the same frame. On `!ok` keep everything, snackbar the
  server message.
- **Path matching:** worktree `path` and room `cwd` come from different
  processes (git vs Pi), so separators and a trailing slash are normalized
  before comparing. Windows drive-letter paths compare case-insensitively,
  POSIX paths stay case-sensitive.

## Steps

1. [x] HomeViewModel: `refreshWorktrees(epk, targetRoomId)` (routed like
   plan/108, dispatched to the device daemon), `worktreeMatchFor(item)`,
   `canCleanupWorktree(item)`, `cleanupWorktree(...)`.
2. [x] `home_page.dart` long-press sheet: cleanup entry under "Open terminal",
   rendered by a scoped `FutureBuilder` so the menu opens instantly and the
   entry appears when the registry lands. Red `folderX` icon.
3. [x] Cleanup dialog widget + wiring to the repository.
4. [x] Tests: gating matrix (offline/keeper/live/no-match/no-fetch/duplicate
   dead/duplicate live), execution (success removes the tile, git refusal
   keeps it, revive-race aborts, unreachable PC throws), dialog copy +
   confirm semantics.

### Acceptance criteria

- Long-press on an offline tile with a registry match offers cleanup;
  confirming removes worktree + branch on the PC (verified via
  `list_worktrees`) and the tile disappears.
- Tiles without a match and online rooms show no entry; keeper mirrors DO
  show it (user decision).
- Dirty worktree → `remove_worktree_result.ok == false` → nothing deleted,
  message shown, tile intact.
- Session revived while the dialog is open → abort, nothing deleted.
- `flutter analyze` clean; home + data test suites green.

## DoD

- [x] Viewmodel match + gating + orchestration
- [x] Menu entry + confirm dialog widget
- [x] Success/failure paths tested (11 new viewmodel tests, 2 dialog tests)
- [x] Changelog entries (app asset + root)
- [ ] Device review

## Next plans

- `--force` passthrough for dirty worktrees (`git worktree remove --force`).
- Batch mode: "clean every offline worktree whose branch is merged".
