# Plan 121 — Projects list: pick a repo, spawn a worktree terminal

## Context

**End goal (user):** from the phone, see a list of **projects** (git repos) on the
paired PC, and from any project create a **worktree** that opens in a terminal
running `pi`.

**Why it doesn't work today:** the app's Home list renders **rooms** — i.e. only
cwds that have (or very recently had) a live `pi` (`HomeList.items()` reads
`roomsByPeer` from the relay). A project with no running `pi` vanishes entirely
(not even offline), so there is nothing to tap to start a worktree. The
worktree-creation + terminal-open path already works end-to-end
(plan/108 createWorktree, plan/112 worktree registry, plan/120 offline dispatch
via the device daemon + the `wt.exe` visibility fix) — what's missing is a
**persistent, pi-independent list of projects** and a **project → new-worktree**
entry point.

**Key enabler:** the supervisor's always-on **device daemon** (room `"device"`,
plan/120) is reachable from the phone even when no project `pi` is running. It
already handles `open_terminal_request`. It can also serve a **projects list** —
either discovered from the filesystem or explicitly registered — so the phone
can list projects with zero live `pi`s.

## Non-goals

- Not making the base project itself run a `pi` / come "online". The user's
  workflow is worktree-per-change; the base repo only needs to be **listable**.
  (An optional always-on daemon per project is a separate, later plan.)
- Not changing the existing worktree/terminal spawn. Plan/108/112/120 stay as-is.

## Design

### Source of projects: filesystem discovery (v1)

The device daemon scans **configured roots** (default `~/source`, overridable via
`projects.roots` in `~/.pi/piper/config.json`) for git repositories, depth-limited
(default depth 2) and capped (default 200 entries) for safety. A directory is a
project candidate when it contains a `.git` (dir or file). Each result:

```jsonc
{ "path": "C:/Users/Alessandro/source/ngTradr", "name": "ngTradr" }
```

`name` = `basename(path)`. Optional later: surface the default branch /
upstream URL for richer tiles. Discovery is **read-only and best-effort**;
unreadable dirs are skipped silently.

Why discovery over manual add: typing a path on a phone is painful, and the
user's repos already live under a small set of roots. Discovery lists them with
zero setup. (Explicit add / hide / pin arrive in a follow-up if needed.)

### Protocol (app `protocol.dart` + pi-extension `protocol/types.ts`)

One new request/result pair, riding the same typed-action channel as
`open_terminal` / `list_worktrees` (no relay change — user envelopes forward
verbatim; the phone targets room `"device"` exactly like offline open-terminal):

```
ClientMessage += ListProjectsRequest   { type:"list_projects_request", id }
ServerMessage += ListProjectsResult    { type:"list_projects_result", in_reply_to,
                                         ok, projects: [{path, name}], message? }
```

### pi-extension (device-daemon handler)

- New module `src/projects/discover.ts`: `discoverProjects(roots, opts)` — pure,
  tested in isolation (mock fs). Depth-limited, capped, deduped, sorted by name.
- Wire a `list_projects_request` handler in `src/actions/handlers.ts` (alongside
  `list_worktrees_request`). Routed by the device daemon's action dispatcher.
- Reads roots from `~/.pi/piper/config.json` (`projects.roots`, default
  `["~/source"]`). Env override `REMOTE_PI_PROJECTS_ROOTS` (colon/`;`-separated)
  for tests/ops.

### App

- `data/actions/actions_repository.dart`: `Future<List<ProjectInfo>> listProjects()`.
- New **Projects** list on Home (a section above/below sessions, or a tab). Each
  tile: project name + tail of path + a count of existing worktrees for that base
  (from `listWorktrees(base: path)`). No "online dot" — projects are always
  shown (sourced from the device daemon, not the relay).
- Tap a project → existing **BranchNameDialog** ("Creates a git worktree off this
  project on a new branch…") → `openTerminal(cwd: path, branch)` routed to room
  `"device"` (the offline path from plan/120). The spawned worktree session then
  appears online as usual.
- Empty state: "No projects found under ~/source — add a root in Settings."
- Errors (device daemon unreachable): "Cockpit/Pi not running on that PC" — same
  guidance as plan/120's offline fallback.

## Steps

### Step 1 — Discover projects (extension)

**Files:** `src/projects/discover.ts` (new), `src/projects/discover.test.ts`.

- `discoverProjects(roots, { maxDepth, maxEntries })` → `{path,name}[]`.
- Reads roots from config + env. Skips non-existent / unreadable roots.
- **Acceptance:** given a temp tree with nested git repos, returns the expected
  set, respects depth + cap, dedupes, never throws on a missing/unreadable root.

### Step 2 — Expose `list_projects_request` (extension)

**Files:** `src/actions/handlers.ts`, `src/protocol/types.ts`, `src/protocol/codec.ts`,
`src/projects/config.ts` (roots read).

- Handler replies `list_projects_result` with discovered projects. Always `ok:true`
  (empty list is valid).
- **Acceptance:** action-dispatch test sends `list_projects_request`, gets back
  the discovered set for a configured root.

### Step 3 — App: Projects list + spawn

**Files:** `app/lib/protocol/protocol.dart`, `app/lib/data/actions/actions_repository.dart`,
`app/lib/ui/home/...` (new projects section/widget), `BranchNameDialog` reuse.

- `listProjects()` action; render tiles; tap → BranchNameDialog → `openTerminal`
  to room `"device"`.
- **Acceptance:** with the Cockpit/supervisor up and no project `pi` running,
  `ngTradr` appears as a project tile; tapping it → entering a branch → a
  worktree terminal opens on the PC and the new session shows online on the phone.

### Step 4 — Config + Settings

**Files:** `~/.pi/piper/config.json` (`projects.roots`), app Settings (read-only
display of roots for v1; editing = follow-up).

- **Acceptance:** adding a root to `projects.roots` makes its repos appear on next
  `listProjects()`; invalid roots are skipped.

## DoD

- [ ] Projects list on the phone shows repos even with **zero** `pi` sessions
      running (served by the device daemon).
- [ ] Tap project → new worktree → terminal opens on PC + new session online.
- [ ] Worktree count per project is correct (from the worktree registry).
- [ ] No phantom "device" tile; device room still filtered (plan/120 step 3).
- [ ] Discovery is read-only, depth/cap-bounded, never throws on bad roots.
- [ ] Unit tests: discover (fs mock), action handler, app list rendering.

## Next plans

- **122:** Explicit project add / pin / hide (for repos outside the scanned
  roots, or to curate the list).
- **123:** Optional always-on daemon per project (register a project with the
  supervisor so its base session can be online too — for users who want that).
- **124:** Richer project tiles (default branch, upstream, dirty/clean, last
  commit) via a cheap `git -C <path> …` snapshot cached on the device daemon.
