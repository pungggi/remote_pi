# Plan 128: Durable, performant offline chat history

> **Status (implementation):** Steps 1–5 done + tested. Step 6 (optional local
> retention cap) deferred. Default page size is **2000** (not 500/100); the
> durable index ts-merges interspersed compaction markers with the RAM tail.
>
> Extends [plan/111](./111-history-pagination.md) (pagination) and supersedes
> the "mirror cache" model from [plan/16](./16-mirror-cache.md).

## Context

Today the mobile app's chat history is **not durable**:

- **Source of truth = `ext.messageBuffer`** (`pi-extension/src/extension-state.ts:142`),
  an **in-memory** array fed **only** by the live `message_end` hook
  (`pi-extension/src/index.ts:1931`). It is **never re-read from disk**, so a Pi
  process restart wipes it to `[]` and `session_sync` then returns `events: []`.
- **App cache = Hive box**, but it is a **substitutive mirror**: `_applyHistory`
  (`app/lib/data/sync/sync_service.dart:824`) deletes every local row whose
  `seq >= desired.length` (`:879–895`). An empty server history **wipes** the
  local cache. The relay re-delivers `session_history` on every reconnect, so a
  post-restart empty buffer empties the phone.
- **30-event cap**: `REMOTE_PI_SYNC_LIMIT` defaults to 30
  (`pi-extension/src/index.ts:840`) and the server **clamps** the client request
  down to it (`Math.min(requested, serverLimit)`, `:4047`). "Load more" is
  neutered unless the env var is raised on the PC.

Net effect: history is partial (cap + volatile buffer) and "disappears offline"
because the local cache was already truncated/emptied by the last online sync,
and offline there is nothing to re-fill it from.

Meanwhile Pi itself writes a **durable, complete, append-only** transcript to
`$PI_CODING_AGENT_DIR/sessions/<encode(cwd)>/<ts>_<uuid>.jsonl` (one line per
persisted message: `{type:'message', message:{role,content,...}}`). The desktop
**cockpit** already reads these files directly
(`cockpit/.../session_history_impl.dart`). The mobile sync path ignores them.

## Decision (scope = full, with performance as a first-class budget)

Make the **`.jsonl` the durable source of truth** for history; serve `session_sync`
from it with **cursor pagination**; make the **app store append-only** (merge,
never substitute) so it survives offline and restarts. Keep `messageBuffer` only
as the **live in-RAM tail** for the current process (incl. synthetic compaction
markers). No eager full-file loads on any hot path.

## Goals / Non-goals

**Goals**
- Kill + restart the Pi process → app can still page the **full** prior history.
- Go offline after a sync → all loaded history stays visible & scrollable.
- Reconnect to a Pi whose buffer is empty → **local history preserved** (no wipe).
- Bounded RAM on both sides; sync/merge cost is **O(page)**, not O(session).

**Non-goals**
- Cross-session history (each session is still its own chat; Home session list is
  separate). Future plan.
- E2E encryption of history. Out of scope.
- Rewriting the relay. Relay stays a dumb forwarder.

## Design

### A. Server (pi-extension) — durable file as source of truth

**A1. Port the path helpers** (TS port of cockpit's `_sessionsRoot` / `_encode` /
`_idOf` in `session_history_impl.dart`):
- root = `process.env.PI_CODING_AGENT_DIR ?? (HOME|USERPROFILE)/.pi/agent` + `/sessions`
- `encode(cwd)` = `--${cwd.replace(/^[/\\]/,'').replace(/[/\\:]/g,'-')}--`
- "current session file" = newest `*.jsonl` by **mtime** under
  `root/encode(process.cwd())`. The cwd-lock (`ext.cwdLock`/`ext.lockedName`)
  guarantees a single active daemon per cwd, so newest-mtime == the live session.

**A2. Lazy session-file index** — new `pi-extension/src/session/file_index.ts`:
- Entry: `{ ts, role, id, byteOffset, byteLen }` (small metadata only).
- Build **lazily on first `session_sync`**, not on `_cmdStart` (no connect tax).
  Stream-parse the file line-by-line; keep only `type:'message'` lines; record
  the byte offset of each. **Never `readFileSync` the whole file into a string.**
- **Cache** the index on `ext` keyed by `{path, size, mtime}`. On file growth
  (append) re-scan **only the tail** past the last known offset — O(append), not
  O(file). On replace/truncate (size shrank) rebuild fully.
- **Memory bound**: cap entries to `REMOTE_PI_HISTORY_INDEX_MAX` (default 20000);
  if exceeded, keep the **newest** N and mark `older_dropped` (cursor into the
  file still works via byte offsets; the cap is just for the in-RAM index — a
  cold page below the cap re-scans). MVP: no spill to disk; measure first.

**A3. Cursor pagination on `session_sync`** — rewrite `_handleSessionSync`
(`pi-extension/src/index.ts:4026`):
- Inputs: optional `before` (opaque cursor = `off:<byteOffset>` for file
  entries or `ram:<bufIndex>` for the RAM tail, of the oldest event the client
  already holds) + `limit` (now **honored**; default **2000** when the client
  omits it; server max `REMOTE_PI_SYNC_LIMIT` **raised to 2000** and acts as a
  *payload guard*, not a 30-event window). Drop the `Math.min(requested, 30)`
  clamp.
- Serve: from the index, take the `limit` entries **older than `before`** (or the
  `limit` newest if no `before`). Random-read just those byte ranges
  (`fs.createReadStream({start,end})` / positioned reads), parse, map to events
  via the **existing** `_mapAgentMessagesToEvents`. **Merge the live tail**
  (`ext.messageBuffer` entries newer than the file's last indexed offset, plus
  synthetic `role:"compaction"` markers), deduped by `(ts,role)` against the
  file's keyset. The file and RAM tail are both append-only ⇒ ts-sorted, so they
  are **ts-merged** (not concatenated) so an interspersed compaction marker
  lands in the right chronological spot.
- Reply `session_history` gains `next_before` (cursor of the oldest event in this
  page, or absent if none older) and `has_more` (index has older entries). Keep
  `eos`/`truncated` for back-compat (`truncated := has_more`).

**A4. `session_started_at` + history version**: keep current semantics (set once
per process, reset on `session_new`). Additionally echo a `history_version`
(file `mtime`/`size`) in `session_history` so the app can detect the underlying
file was replaced (e.g. `session_new` rotates to a new file) and clear cleanly.

**A5. Compaction markers**: synthetic `role:"compaction"` lives only in the RAM
tail (`index.ts:2036`). Across a process restart an old compaction marker is
**not** in the `.jsonl`, so it drops out of history. Accepted for MVP (it's a
visual system bubble, not conversation content). Documented in Risks.

### B. Wire (protocol) — backward-compatible additions

Document in `PROTOCOL.md` (session_sync / session_history section):

```jsonc
// app → Pi-extension
{ "type": "session_sync", "id": "<uuid>", "limit": 100, "before": "1782…:u_…" }
// `before` and `limit` optional; omitted == newest N (legacy shape).

// Pi-extension → app
{ "type": "session_history", "in_reply_to": "<uuid>",
  "session_started_at": 1782…, "eos": true,
  "events": [ /* ≤ limit, oldest-first when paging back */ ],
  "has_more": true, "next_before": "1782…:u_…", "history_version": "1782…:48231" }
```

Old clients ignore the new fields; old servers omit them → app falls back to the
capped newest-N behavior (graceful, no worse than today).

### C. App — append-only, non-destructive store

**C1. Rewrite `_applyHistory`** (`app/lib/data/sync/sync_service.dart:824`) from
**substitute** to **merge**:
- **New-session guard**: compare `h.sessionStartedAt` to the stored
  `sessionStartedAt` (already kept in `SessionIndexRecord`, written at `:908`).
  If it changed and is `!= 0` → genuine new conversation: clear the box + reset
  `_idToSeq`/`_nextSeq` (this is the **only** path that deletes history). If
  `== 0` (legacy/no-session Pi) → treat as "nothing new", **do not wipe**.
- **Merge**: for each page row, skip if `_idToSeq` already has `_key(role,id)`;
  else assign `_nextSeq++`, `box.put(seq, json)`. **O(page)**, no `box.values`
  scan, no per-row normalize-compare, **no deletes on same-session**.
- This single change fixes "disappears offline": an empty `events` with an
  unchanged `session_started_at` is now a **no-op**, never a wipe.

**C2. Backward paging UI** (ChatViewModel): on scroll-to-top (or a "Load older"
control when `has_more`), call `requestSync(before: <oldest local cursor>,
limit: 100)`. Thread `next_before` through `SyncService` state. Stop paging when
`!has_more`. Cursor = oldest row's `(ts, id)` for user rows; for assistant rows
use `(ts, inReplyTo)`.

**C3. Bounded store**: default **keep-all** (Hive + incremental per-key
`box.watch` reads stay cheap — see `session_read_repository.dart:32`). Add a
configurable retention cap `REMOTE_PI_LOCAL_HISTORY_MAX` (default off) that, when
set, evicts the oldest rows beyond a headroom on each merge. Measure first; ship
capped-behind-a-flag rather than eager compaction.

## Performance budget (the explicit requirement)

| Path | Cost | Bound |
|---|---|---|
| First `session_sync` after start | one streaming index build | O(file bytes), cached |
| Subsequent syncs (no file growth) | index lookup + page reads | O(limit) |
| File append (new turns) | re-scan tail only | O(appended bytes) |
| Server RAM (index) | metadata only | ≤ `INDEX_MAX` entries (default 20k) |
| Server RAM (tail) | current process events | O(turns this boot) |
| Wire per page | ≤ `limit` events | default 2000 (server max, env-tunable) |
| App merge per page | set-membership puts | O(limit), no box scan |
| App reads | incremental `box.watch` per key | unchanged (already cheap) |

**Forbidden on hot paths**: `readFileSync` of the whole `.jsonl`; full `box.values`
scan in `_applyHistory`; per-row `jsonEncode` normalize-compare; eager index build
on `_cmdStart`.

## Steps (with acceptance criteria)

1. **Port path helpers + lazy index** (`session/file_index.ts`, extension).
   - AC: builds an index from a fixture `.jsonl`; caches by `{size,mtime}`; on
     append re-scans only the tail; honors `INDEX_MAX` cap (newest N).

2. **Cursor `session_sync` server** (rewrite `_handleSessionSync`).
   - AC: with `before` returns the correct older page (oldest-first); merges RAM
     tail deduped by `(ts,role,id)`; `has_more`/`next_before` correct; the legacy
     30-clamp test is updated to the new 500 payload guard.

3. **Protocol doc** (`PROTOCOL.md`).
   - AC: `before`/`next_before`/`has_more`/`history_version` documented; back-compat
     note (old client/server) present.

4. **App append-only merge + new-session-only clear** (rewrite `_applyHistory`).
   - AC: empty `events` (unchanged session) → no-op, box intact; reconnect with
     empty server buffer → history preserved; same-session re-delivery dedups
     (zero new writes); genuine `session_started_at` change → clear.

5. **App backward paging UI**.
   - AC: scroll-to-top loads the previous page; cursor threads across taps;
     paging stops at `!has_more`; works fully offline for already-loaded pages.

6. **(Optional, behind flag) local retention cap**.
   - AC: with cap set, box stays ≤ cap+headroom; oldest evicted; reads/merge stay
     correct; default off.

## DoD

- Kill the Pi process, restart, reconnect from the phone → the **full** prior
  conversation is pagable (not wiped, not capped at 30).
- Go offline after a sync → all loaded history stays visible and scrollable.
- Reconnect to a legacy Pi whose buffer is empty → **local history preserved**
  (no wipe); app just can't page further back.
- Long session fixture (10k messages): first sync completes in well under the
  20s pending-send budget; server RSS bounded by `INDEX_MAX`; app merge is
  O(page) (no UI jank on reconnect).
- `pnpm --dir pi-extension test` green; new unit tests for the file index
  (build/cache/tail-scan/cap) and the cursor paging (before/has_more/dedup);
  app tests for the merge (no-wipe-on-empty, new-session-clear, dedup).

## Risks

- **`.jsonl` line-shape drift** across pi versions → parser must be tolerant
  (skip non-`message` / unparseable lines, never throw). On total parse failure,
  fall back to RAM-tail-only (today's behavior). Add a fixture per known shape.
- **Synthetic compaction markers lost across restart** (A5) — minor visual gap;
  the conversation text is intact. Acceptable for MVP.
- **Concurrent daemons on the same cwd** → cwd-lock already prevents this; the
  newest-mtime assumption is documented and asserted.
- **Back-compat**: new app + old extension → app sends `before`, old server
  ignores it and returns newest-30; app merges (no wipe) and just can't page back.
  Old app + new extension → ignores new fields, behaves like today. No breakage.
- **Very large sessions** (>20k msgs) → index cap drops the oldest metadata;
  cold paging below the cap re-scans. Acceptable; revisit if real sessions exceed.

## Next plans

- Cross-session history: a per-peer session index backed by the same file scan,
  so Home can list/restore any past session for a cwd (today only cockpit does).
- Binary history channel to avoid double-base64 cost when paging very large
  sessions over mobile networks (deferred; page size guard keeps payloads sane).
