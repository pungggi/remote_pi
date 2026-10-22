# Plan 146 — agent_file history: reference records + on-demand re-fetch

## Context

`agent_file` (plan/126, extended by plan/144-mermaid) is a **live push**: the
extension broadcasts the file with an inline base64 payload to the devices
connected *at that moment*. Chat history survives (`session_sync` →
`session_history`, replayed from Pi's durable `.jsonl` transcript via the
plan/128 file index), but `agent_file` is not a Pi message — it never enters
that transcript. Observable symptom (2026-10-22): a phone joining the session
after the push sees the `show_file` tool call in history, but no bubble and no
viewer. The file is gone for that device.

The **delivery ledger** (plan/145, `problemz` worktree, in flight) heals the
common case: stamped frames + sender-side journal replay re-delivers a missed
`agent_file` (with its full payload) as long as the loss is inside the
2048-frame journal window and the same session epoch. It cannot help when:

- the journal overflows (degrades to full `session_sync` → transcript → no
  `agent_file`),
- the PC session restarted (epoch change → same full-sync fallback),
- the app was reinstalled / the local DB wiped.

Those are exactly the cases this plan covers: make `agent_file` a durable,
**reference-only** citizen of session history, and re-fetch bytes from the PC
on demand.

**User decision (2026-10-22)**: *reference + re-fetch* — history records carry
metadata only, never the payload (PDFs may be 10 MiB each; contrast with
images, decision #8, which stay inline because they are small and
user-authored). Wire/DB bloat and sync cost stay proportional to the number of
files shown, not their size.

## Fixed decisions

| # | Decision | Value |
|---|---|---|
| 1 | History record | `agent_file` reference event: `fileId`, `ts`, `kind`, `mime`, `name`, `bytes`, `caption` — **no payload** |
| 2 | Registry | Per-session sidecar next to the transcript (written on `show_file`, loaded with the file index): `fileId → absPath` + metadata |
| 3 | Fetch | New `ClientMessage` `agent_file_fetch {fileId}` → `agent_file_payload` (base64, same caps as live) or `agent_file_error {code}` |
| 4 | Security | `fileId` is an opaque UUID; the path never crosses the wire; fetch only served to paired peers; re-read re-validates size cap + extension |
| 5 | App storage | Local DB persists the reference record (cheap); fetched payloads are NOT persisted (temp file for the viewer, like today's live path) |
| 6 | Relation to plan/145 | Live path unchanged: inline payload broadcast (later stamped `(epoch, seq)` by the ledger). History path: reference-only. The two plans touch disjoint code paths |

## Steps

1. **pi-extension — registry**
   `session/file_registry.ts`: append-only sidecar
   (`$PI_CODING_AGENT_DIR/sessions/<cwd>/<session>.files.jsonl`), one line per
   `show_file`: `{fileId, ts, kind, mime, name, bytes, caption, absPath}`.
   Written inside the `show_file` execute path (after validation, before
   broadcast). Acceptance: pushing a file writes the sidecar; unit tests.
2. **pi-extension — history merge**
   `_handleSessionSync` merges registry entries into the `SessionHistoryEvent[]`
   timeline by `ts` as `agent_file_ref` events. Acceptance: `session_history`
   contains one ref event per pushed file, ordered; no base64 in any history
   payload (assert in tests).
3. **pi-extension — fetch handler**
   `agent_file_fetch {fileId}` (early-dispatch spot, per sender, like
   `report_seq`/`session_sync`): resolve in registry → stat + re-validate
   (exists, regular file, size cap, extension still maps to `kind`) → read →
   reply `agent_file_payload {in_reply_to, fileId, kind, mime, data}`; on any
   failure `agent_file_error {code: "not_found" | "gone" | "too_large"}`.
   Rate-limit per channel (reuse the ledger's burst discipline). Acceptance:
   vitest for all four outcomes; unpaired sender rejected.
4. **Protocol** — `types.ts` + `codec.ts` both directions, PROTOCOL.md section
   (mark: additive, optional, ignored by old peers).
5. **App — reference records**
   Parse `agent_file_ref` history events into persisted `AgentFileMsg` records
   with `payload == null`, `fileId` set. Bubble renders from metadata (icon,
   name, size, caption) with a subtle "on PC" affordance.
6. **App — fetch flow**
   Tap on a payload-less bubble: spinner → send `agent_file_fetch` → on
   `agent_file_payload` open the viewer (existing routing); on error show an
   inline error state ("Datei auf dem PC nicht mehr verfügbar"). Live-path
   bubbles (payload inline) keep opening directly.
   Acceptance: `agent_file_test.dart` + viewmodel tests cover ref→fetch→open
   and ref→error.
7. **Docs** — pi-extension README, CHANGELOGs, PROTOCOL.md.

## DoD

- Push a file, kill the PC session, restart pi (new epoch), let the phone
  full-sync: the bubble is in history; tapping re-fetches and opens the viewer.
- Delete the file on the PC, tap: friendly error, no crash.
- `session_history` wire + app DB contain no file base64.
- vitest + `flutter analyze` + `flutter test` green.

## Next plans

- Surface fetch state in the bubble (spinner/error) also for live-payload
  bubbles whose viewer temp file was evicted.
- Retention: prune sidecar + registry entries older than N sessions.
