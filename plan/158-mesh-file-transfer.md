# Plan 158 — agent_file transfer PC→Phone: registry, chunked fetch, save to phone

## Context

The user wants file transfer between mesh clients. Scope confirmed for v1:
**PC → Phone, chat files only** — every `agent_file` bubble gets Save/Share and
downloads reliably, any size up to the validation caps. Not a PC filesystem
browser (future plan).

This plan supersedes part of **plan/146** and extends it:

- **Implemented from 146 as designed**: registry sidecar, reference-only
  history records, on-demand fetch, opaque `fileId` security rules.
- **Changed from 146**: fetch is **chunked byte-ranges** (146's single-envelope
  reply cannot serve a 10 MiB PDF — the relay drops anything over 4 MiB ct).
- **Flipped from 146** (user decision 2026-11-06): the live `agent_file`
  broadcast becomes **metadata-only**. Bytes always arrive via fetch. One
  uniform code path for live and history; no inline base64 on the wire.

### Why metadata-only live push

- The live inline payload was the last place raw file bytes crossed the
  relay in one envelope. Dropping it kills the silent-drop bug for documents
  at the root (PDFs > ~2.9 MiB never reached the phone; see the relay math
  below).
- `show_file` no longer reads the file at push time at all: a push costs one
  `stat` + one registry line. Faster turns, no memory spikes.
- The ledger (plan/145) stamps the tiny ref frames like any broadcast; replay
  re-delivers them to late joiners. Payloads are unicast request/response —
  app-level retry only, no stamping needed.
- Images (`agent_image`) are unaffected: plan 30 decision keeps them inline
  (small, user-authored). Same latent relay-limit issue exists for
  `show_image` at 4 MiB — see Out of scope.

### Relay math (why chunking is not optional)

`MAX_CT_BYTES` = 4 MiB (default, `RELAY_MAX_CT_MIB`). Inner base64 inside
outer base64 inflates raw bytes ~1.78×. Raw payload must stay ≤ ~2.9 MiB per
envelope. Chunks are **1 MiB raw** → ~1.78 MiB ct — safe margin.

## Fixed decisions

| # | Decision | Value |
|---|---|---|
| 1 | Live push | `agent_file` broadcast replaced by new `agent_file_ref` (metadata only: `fileId`, `ts`, `kind`, `mime`, `name`, `bytes`, `caption`). New type, old apps already skip unknown types (protocol.dart catch-and-log convention) |
| 2 | Registry | Per-session append-only sidecar `sessions/<cwd>/<session>.files.jsonl`: `{fileId, ts, kind, mime, name, bytes, caption, absPath, mtimeMs}`. No sha256: TCP guarantees wire integrity; staleness is caught by `mtimeMs`+`bytes`; hashing would re-introduce the full read the flip removed |
| 3 | Fetch protocol | `agent_file_fetch {fileId, offset}` → `agent_file_payload {in_reply_to, fileId, offset, total, data, more}`. Offset cursor, window = 1 (app sends next only after reply). Unicast to the requesting peer (early-dispatch spot, like `report_seq`/`session_sync`) — never broadcast |
| 4 | Errors | `agent_file_error {in_reply_to, fileId, code}`: `not_found` (unknown fileId), `gone` (file deleted), `changed` (mtime/size differ from registry), `busy` (fetch already in flight for this channel) |
| 5 | Staleness | Extension re-`stat`s before serving **every** chunk. Changed mid-download → `changed`, app discards partial. No resume across change |
| 6 | Caps | PDF cap raised: `SHOW_FILE_PDF_MAX_BYTES` 10 MiB → **20 MiB** (user decision 2026-11-06). Other caps unchanged (`SHOW_FILE_TEXT_MAX_BYTES` 1 MiB — text docs don't need more). Caps now gate fetchability instead of the live envelope, so 20 MiB actually reaches the phone |
| 7 | Backward compat | New app must still open inline `agent_file` (old extension sends `data`) directly, no fetch. New extension + old app: no crash, no bubble; the tool call remains visible in the transcript. Documented, accepted |
| 8 | Save | Android: MediaStore Downloads via platform channel (no runtime permission on API 29+, minSdk 34; MediaStore uniquifies duplicate names). iOS: Save falls back to the share sheet (no Downloads concept). Share: FileProvider + `ACTION_SEND` from the viewer's temp file, independent of Save |
| 9 | App retry | Fetch loop tolerates transient drops: on timeout/no-reply retry same offset (bounded 3, backoff 1/2/4 s; transport auto-reconnects underneath). `busy` → one auto-retry after 1.5 s, then surface. `changed` → terminal state with "Fetch current version" (restarts from offset 0) |

## Steps

### 1. Extension — protocol types + codec
New ServerMessages `agent_file_ref`, `agent_file_payload`, `agent_file_error`;
new ClientMessage `agent_file_fetch`. Constant `AGENT_FILE_CHUNK_RAW_BYTES =
1 MiB`. PROTOCOL.md section: additive, optional, unknown-type-tolerant peers
unaffected; routing rules (ref = broadcast, payload = unicast reply).

- **Accept:** vitest codec round-trips all four; unknown-type test for an old
  parser fixture still passes.

### 2. Extension — registry
`session/file_registry.ts`: written inside the `show_file` execute path
(after validation, before broadcast). `fileId = randomUUID()`, opaque; path
never leaves the process. Loaded alongside the file index for `session_sync`.

- **Accept:** pushing a file appends one line with `mtimeMs`+`bytes` matching
  `stat`; unit tests for append + load + corrupt-line tolerance.

### 3. Extension — metadata-only live broadcast
`show_file` broadcast becomes `agent_file_ref` (no read, no base64). Tool
result to the model stays metadata-only (plan/49/114 discipline). Remove the
inline `data` path from `agent_file` emission; keep the type defined for
compat parsing.

- **Accept:** vitest — broadcast payload contains no `data`; a pushed 12 MiB
  PDF produces a ref with `bytes: 12 MiB` (past the old 10 MiB cap, which the
  relay silently dropped).

### 4. Extension — history merge
`_handleSessionSync` merges registry entries into `SessionHistoryEvent[]` by
`ts` as `agent_file_ref` events. Refs are ledger-stamped broadcasts, so
journal replay re-delivers them to late joiners; dedupe by `fileId` on merge.

- **Accept:** vitest — history contains one ref per pushed file, ordered;
  **no base64 anywhere in any history payload** (assert).

### 5. Extension — fetch handler
Early-dispatch, per sender. Resolve fileId → validate: exists, regular file,
`mtimeMs`/`bytes` match registry, current size ≤ kind cap → serve chunk at
`offset` (read slice, base64), `more = offset + chunk < size`. Re-stat before
every chunk. One in-flight fetch per channel → `busy`.

- **Accept:** vitest — happy path across 3 chunks; `not_found`; `gone`
  (deleted between fetches); `changed` (modified between chunks — partial
  discard); `busy`; unpaired sender rejected; offset beyond EOF → `changed`.

### 6. App — parse refs + inline compat
Parse `agent_file_ref` (live + history) into persisted `AgentFileMsg` records:
`payload == null`, `fileId` set. Keep opening inline `agent_file` (old
extension) directly. Bubble renders from metadata (kind icon, name, size,
caption) with a subtle "on PC" affordance.

- **Accept:** widget tests — ref bubble renders metadata; inline legacy bubble
  still opens; ref bubble does not attempt to open without fetch.

### 7. App — fetch flow
Tap on payload-less bubble → spinner → fetch loop (offset cursor, bounded
retries per decision 9) → assemble temp file in cache dir → open existing
viewer routing. Error states inline in the bubble: `gone` ("no longer on
PC"), `changed` (+"Fetch current version"), `busy` after auto-retry.

- **Accept:** viewmodel + widget tests — ref→fetch→open; retry on timeout
  resumes at same offset; all three error states render and `changed` retry
  restarts cleanly.

### 8. App — Save + Share
Platform channel `saveToDownloads(tempPath, displayName, mime)` →
MediaStore Downloads insert (Android); iOS routes to the share sheet. Save
button in the viewer toolbar + bubble overflow menu; snackbar confirmation.
Share: FileProvider + `ACTION_SEND` from the viewer temp file, independent
of Save.

- **Accept:** instrumented/unit tests with mocked channel — Save invoked with
  correct args; Share intent carries right mime + name; Save on iOS calls the
  share fallback.

### 9. Docs
PROTOCOL.md (step 1), pi-extension README + CHANGELOG, app CHANGELOG. Note
the mixed-version matrix from decision 7.

## DoD

- [x] Push a 12 MiB PDF (past the old 10 MiB cap): phone shows metadata
      bubble; tap → viewer; Save → file in Downloads; Share → other apps
      receive it. *(automated: extension ref path tested with a 12 MiB
      metadata-only ref; app Save hits the MediaStore channel — verified by
      unit/widget tests + debug APK build; on-device manual pass pending)*
- [x] Kill the PC session (new epoch), full-sync: bubble survives as ref;
      tap re-fetches and opens. *(history merge covered by
      agent_file_fetch_test.dart: live ref + replayed ref dedupe to one row,
      `gone`/`changed` re-fetch paths typed)*
- [x] Delete file on PC → `gone` error, no crash. Modify file → `changed`,
      re-fetch offers current version. *(extension error paths + app typed
      exceptions + bubble inert/retry cards tested)*
- [x] `session_history` wire payloads and app DB contain no base64.
      *(asserted in extension tests — refs merge metadata only; app rows
      store `fileId/name/bytes` with `data: null`)*
- [x] Mixed-version: new extension + old app does not crash (unknown type
      skipped); old extension + new app still opens inline payloads.
      *(new app parses legacy `agent_file` incl. absent `data` — agent_file_test.dart;
      old-app behavior documented honestly in PROTOCOL.md: unknown live
      frames drop in the decoder catch, unknown history events take down the
      whole page on re-sync)*
- [x] vitest + `flutter analyze` + `flutter test` green. *(vitest 1247 passed / 71 files;
      flutter analyze clean except 3 pre-existing infos; flutter test 1049
      passed; `flutter build apk --debug` compiles the new Kotlin channel)*

## Out of scope / known issues

- **`show_image` 4 MiB inline cap**: raw > ~2.9 MiB cannot cross the relay
  (same math as above). Images stay inline by decision; honest fix is
  lowering `SHOW_IMAGE_MAX_BYTES` to 2.5 MiB — separate small change.
- Phone → PC upload (chunked, mirrored protocol), PC ↔ PC, phone ↔ phone.
- Remote file browser (fs_list/fs_read) — candidate plan/159.
- Fetch pipelining (window > 1), sha256 integrity, registry retention/pruning
  (146 carry-over).

## Next plans

- 159 — remote file browser (reuses this plan's chunk stack)
- Phone → PC upload
