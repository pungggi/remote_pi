# Plan 112 — Worktree tracking (list / reopen / remove)

## Context

Plan 108's "Open terminal" now spawns a **throwaway git worktree** off the base
project (branch `work/<stamp>`, sibling `worktrees/<stamp>` folder) and opens a
terminal running `pi` inside it. Today that worktree is fire-and-forget: the
user has no way to see, reopen, or clean up the worktrees they created.

This plan makes the **pi-extension the source of truth** for a worktree
registry, and exposes list / reopen / remove to the app. The app's session-info
ℹ dialog gains a **"Worktrees" section** so the user can reopen an existing
worktree or delete it; the quick-action "Open terminal" stays a fast
one-tap **new worktree**.

No relay change — typed-action request/response envelopes forward verbatim
(same channel as git status / open terminal).

## Design

### Source of truth

`~/.pi/piper/worktrees.json` (mirrors `daemon/registry.ts`'s `daemons.json`
convention). Each entry:

```jsonc
{
  "id": "20260728-002112",     // == stamp == folder name == branch suffix
  "base": "C:/.../remote_pi",  // base repo path
  "path": "C:/.../worktrees/20260728-002112",
  "branch": "work/20260728-002112",
  "created_at": "2026-07-28T00:21:12.000Z"
}
```

`listWorktrees()` **reconciles** against the filesystem: drops entries whose
`path/.git` no longer exists (manually deleted / pruned) and persists the
cleanup. Survives app reinstall; never drifts from reality.

### Protocol (app `protocol.dart` + ext `types.ts`)

Extend existing:
```
OpenTerminalRequest  += worktreePath?: String      // reopen existing (skip creation)
OpenTerminalResult   += worktree?: WireWorktree     // the newly-created entry (absent on reopen/fail)
```

New (mirroring `git_status_request`/`_result`):
```
ClientMessage +=
  | ListWorktreesRequest   { type, id, base?: String? }
  | RemoveWorktreeRequest  { type, id, worktreeId }

ServerMessage +=
  | ListWorktreesResult    { type, in_reply_to, ok, worktrees: WireWorktree[] }
  | RemoveWorktreeResult   { type, in_reply_to, ok, message }
```

Codec: add `list_worktrees_result` + `remove_worktree_result` to ext
`SERVER_TYPES`.

### pi-extension

- **`src/actions/worktree_registry.ts` (NEW)** — `addWorktree`,
  `listWorktrees(base?)` (reconcile), `forgetWorktree(id)`. `~/.pi/piper/worktrees.json`.
- **`open_terminal.ts`** — `createWorktree` records to the registry and returns
  the `WireWorktree` entry. `handleOpenTerminal` honors `worktree_path` (reopen:
  skip creation, just open terminal). Add `handleListWorktrees`,
  `handleRemoveWorktree` (runs `git worktree remove` + `git branch -D`, then
  `forgetWorktree`).
- **`index.ts`** — dispatch cases for the two new requests.

### App

- **`protocol.dart`** — mirror all new types + `WireWorktree` class.
- **`actions_repository.dart`** — `openTerminal({worktreePath?})`,
  `listWorktrees()`, `removeWorktree(id)`; `_onMessage` cases.
- **`sync_service.dart`** — ignore-group for the two new result types.
- **Session-info ℹ dialog** (`chat_page.dart`) — new **"Worktrees"** section:
  a `FutureBuilder<List<WireWorktree>>` (filtered by `room.cwd` as base) listing
  each worktree (branch + relative age), **tap → reopen** (open terminal at the
  worktree path), **trailing trash → remove** (confirm dialog). A refresh after
  each open/remove.

## Steps

1. ext `types.ts` — `WireWorktree`, extend open_terminal req/res, add 2 new
   req/res pairs.
2. ext `codec.ts` — 2 new server types.
3. ext `worktree_registry.ts` — load/save/add/list(reconcile)/forget.
4. ext `open_terminal.ts` — record + return entry; reopen path; 2 new handlers.
5. ext `index.ts` — dispatch. `npx tsc` (rebuild dist — gotcha).
6. app `protocol.dart` — mirror types + fromJson.
7. app `actions_repository.dart` — methods + onMessage.
8. app `sync_service.dart` — ignore-group.
9. app ℹ dialog — Worktrees section.
10. `dart analyze lib test` clean; build APK; verify on device.

## DoD

Tapping "Open terminal" creates a tracked worktree; the ℹ dialog lists it;
tap reopens (terminal in the worktree, no new worktree); trash removes it
(`git worktree remove` + branch delete + registry prune). Stale worktrees
(deleted on disk) auto-drop from the list. Committed + pushed; dist rebuilt.

## Next

- **112b** — worktree name prompt (custom branch name instead of timestamp).
- **112c** — show uncommitted-changes indicator per worktree row.
