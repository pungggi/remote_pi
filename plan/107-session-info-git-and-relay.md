# 107 — Session-info dialog: git status + relay URL

## Context

The session-info dialog (AppBar ℹ) shows Name / Path / Owner / Model / Room /
Paired. Two gaps the user wants closed:

1. **Git status** — branch, ahead/behind, staged/unstaged, stash (the same
   info `pi-posh-git` renders in the Pi footer).
2. **Relay URL** — which relay this session is routed through (already in
   `PeerRecord.relayUrl`, just not shown).

## Decision (closed) — on-demand request/response, NOT events

`pi-posh-git` is a **footer-only** extension: it computes
`git status --porcelain=2 --branch` and renders into the Pi footer, exposing
**nothing** to the outside (`currentGitPrompt` lives in the footer closure).
The Pi SDK has no structured inter-extension channel (`getExtensionStatuses()`
is footer-text only).

Rather than invent a fragile cross-extension event bus, the **remote_pi
pi-extension computes git status itself** (it already owns the session `cwd`,
reported in `room_meta`). Decoupled: the app shows git even when pi-posh-git
isn't installed.

The git status reaches the app **on demand** (the dialog only needs a snapshot
when opened) by reusing the existing **typed-action request/response** channel
(`id` ↔ `in_reply_to`, same as `list_models` → `models_list`). **No relay
change** — the request/reply ride the normal user-envelope channel the relay
routes verbatim.

## Structure

### pi-extension (TS)
- **`actions/git_status.ts`** (new) — `getGitStatus(cwd)` (ported from
  pi-posh-git's proven porcelain=2 parser) + `handleGitStatus(sender, msg, cwd)`
  → replies `git_status_result { in_reply_to, status | null }`. `null` when the
  cwd isn't a repo / git unavailable.
- **`protocol/types.ts`** — `git_status_request` (ClientMessage) +
  `git_status_result` (ServerMessage) + `WireGitStatus` interface.
- **`protocol/codec.ts`** — register `git_status_result` in `SERVER_TYPES`.
- **`index.ts`** — `case "git_status_request"` in `_routeClientMessageFrom`,
  passing `_myRoomMeta?.cwd`.

### app (Dart)
- **`protocol/protocol.dart`** — `GitStatusRequest`, `GitStatusResult`,
  `GitStatus` model + `fromJson` case.
- **`data/actions/actions_repository.dart`** — `gitStatus()` via the existing
  `_dispatch<GitStatus?>` + `_onMessage` case resolving the completer.
- **`ui/chat/chat_page.dart`** — Relay row (`peer.relayUrl`) + a `FutureBuilder`
  Git row (posh-git-style summary, async-fetch on dialog open).

## Why no relay change

`room_meta` is a **typed Rust struct** (`RoomMeta`/`RoomMetaPatch`) — pushing
git there needs a relay rebuild + redeploy. The on-demand path rides the
existing envelope channel (relay forwards user envelopes verbatim, only
intercepts control frames). Snapshot-on-open is enough for a dialog.

## DoD

- [ ] ℹ shows Relay URL.
- [ ] ℹ shows a git summary line (`[main ↑3 +1 ~0 -0 | +0 ~2 -0 !]`-style),
      loading while fetching, "not a git repo" when status null, "unavailable"
      on offline/timeout.
- [ ] Works on a repo and gracefully says "not a git repo" elsewhere.
- [ ] TS + Dart analyze clean; existing tests pass.
- [ ] No relay rebuild.

## Next plans

- `107b` (optional) — push git via `room_meta.git` if we later want it **live**
  on the Home tile (then the relay typed-struct change is justified).
