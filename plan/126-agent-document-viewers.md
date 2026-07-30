# Plan 126 — Document viewers the agent can push (Markdown / Text / PDF / HTML+JS)

**Objective**: generalize plan/114's agent→user image flow beyond images. Today
the agent can push a **file** to the user's phone with exactly one tool —
`show_image` (jpeg/png/webp/gif, 4 MiB). The user wants the agent to also be able
to show **Markdown**, **plain text / code**, **PDF**, and **HTML with
JavaScript** — each opening an appropriate full-screen viewer on the mobile app,
mirroring the `show_image` bubble→viewer UX.

Expected result: user says "show me `plan/126-agent-document-viewers.md`" or
"render `report.pdf`" or "open `dashboard.html`" → the agent calls a tool → the
extension reads/validates the file and broadcasts a new `agent_file` message
with inline base64 + a `kind` discriminator → the app renders a tappable bubble
→ tap opens the right viewer (Markdown, Text, PDF, or WebView).

## Why this direction

The plan/114 pipeline is already general — only the content type is hardcoded:

- **`pi.registerTool`** + **`_broadcastToActive(ServerMessage)`** — one new tool
  + one new `ServerMessage` variant reuse the exact pattern of `show_image` /
  `agent_image`. Relay stays opaque (inline base64 in the `ct`).
- **`WireImage` is the only image-specific bit** — for documents we carry
  `data: base64` + `kind` instead. One decode path in the app, same context
  hygiene (bytes never reach the model — only metadata in the tool_result).
- **Cockpit already renders Markdown + text/code** (`FileViewer`, `gpt_markdown`
  + `highlight`); the **mobile app only renders agent-reply Markdown**. So
  Markdown/Text viewers port existing patterns; PDF and HTML(+JS) are net-new
  rendering on the app (new packages).

## Non-goals (explicitly cut)

- ❌ **Cockpit (desktop)** out of scope — it already has Markdown/text in
  `FileViewer`; PDF + HTML+JS there is a follow-up. Parity, not blocking.
- ❌ **Editing** — viewers are read-only (cockpit's FileViewer edits; the app
  viewers do not). "View source" toggle for Markdown/HTML is in-scope; editing
  is not.
- ❌ **Generating documents** — the tool shows an existing file on disk. "Build a
  chart HTML then show it" composes (agent writes file, then `show_file`), but
  generation is not this plan.
- ❌ **Replay via `session_sync`** — same as plan/114: `agent_file` is a live
  broadcast; the app persists the bubble locally (survives app restart, not a
  local-DB wipe). Reopened as follow-up if it hurts.
- ❌ **Binary channel / resize** — inline base64 only. PDFs up to the cap pay the
  ~+77% double-base64 tax (risk #1). Binary relay is the plan/114/30 follow-up.

## Fixed decisions

| # | Decision | Value |
|---|---|---|
| 1 | Scope | **Agent → user (file from disk)**. Touches `app` + `pi-extension` + protocol; **relay unchanged** |
| 2 | Tool | **One** tool `show_file({ path, caption?, kind?, allowNetwork? })`. `kind` auto-detected from extension+magic bytes when omitted |
| 3 | Kinds | `markdown` · `text` · `pdf` · `html` (+ existing `show_image` stays for images) |
| 4 | Protocol | New `ServerMessage` **`agent_file`** `{ id, in_reply_to, kind, data: base64, mime?, path?, caption?, size? }`. Additive/optional → backwards compatible |
| 5 | Transport | **Inline base64** in `agent_file`, inside the opaque `ct`. Relay does not change |
| 6 | Size caps (raw file) | `markdown`/`text`/`html`: **1 MiB** · `pdf`: **10 MiB**. Reject larger (no server-side resize) |
| 7 | Model context | `show_file` tool_result returns **metadata only** (`shown`, `kind`, `path`, `mime`, `bytes`). `agent_file` never enters `context`/provider (same as plan/114) |
| 8 | Markdown viewer | `gpt_markdown` (already a dep) — scrollable, selectable, themed. Optional "source" toggle |
| 9 | Text viewer | Monospace `SelectableText`, line numbers optional. Syntax highlight via `highlight` is a **nice-to-have** follow-up (new dep in app) |
| 10 | PDF viewer | **`pdfx`** (native renderers: PDFKit iOS / PdfRenderer Android). Paginated, zoom. Adds native deps → build-config check |
| 11 | HTML+JS viewer | **`webview_flutter`** + platform plugins. **JS enabled. Network BLOCKED by default** (see #12). Badge shows sandbox state |
| 12 | HTML+JS sandbox | NavigationDelegate rejects every sub-resource/navigation that leaves the inlined document (no remote `<script src>`, no XHR/fetch, no iframes to remote). Opt-in `allowNetwork:true` unblocks (badge flips to "online") — **⚠️ the key product decision, see "Decisions to confirm"** |
| 13 | Timeline / persistence | Same as plan/114: left-aligned assistant bubble anchored by `in_reply_to`; persisted in local app DB; **not** in `session_history` |

### Assumed defaults (veto if you disagree)

- **Path resolution**: `path.resolve(p)` vs session cwd; reject if missing or not
  a regular file.
- **Kind detection**: by extension first, magic bytes second:
  - `md`/`markdown` → `markdown`; `txt`/`log`/`csv`/`tsv`/`json`/`yaml`/`yml` and
    code extensions (`dart`,`ts`,`tsx`,`js`,`jsx`,`py`,`rs`,`go`,`java`,`c`,`cpp`,`h`,`sh`,`sql`,…) → `text`;
    `html`/`htm` → `html`; `pdf` → `pdf` (verify `%PDF-` magic). Explicit `kind`
    param overrides detection (e.g. force `text` on a `.md`).
  - Unknown extension → tool error (no guessing) unless `kind` is given.
- **Text decoding**: decode base64 → UTF-8; if not valid UTF-8, reject as "binary,
  not a text kind" (suggest `show_image` or a future binary path).
- **Bubble preview**: text/markdown show first ~3 lines (clamped) + filename;
  pdf/html show an icon card + filename + size.
- **Save/Share**: reuse plan/114 actions where meaningful — text/markdown → share
  as `.txt`/`.md`; pdf → share/save file; html → share source (rendered HTML is
  not a shareable asset). Save-to-gallery does not apply here.
- **Offline**: no active peer → `shown:false, reason:"no active peer"` (info, not
  error); turn never blocks.
- **Dedup**: `agent_file.id` stable UUID; app dedups by id.

## ⚠️ Decisions to confirm (before implementing)

1. **HTML+JS network policy (#12)** — default **JS on / network blocked**. Confirm,
   or do you want full network by default? (Network-blocked still runs inlined JS
   — canvas, DOM, local charts — but blocks CDN scripts, fetch, remote images.)
2. **`allowNetwork` opt-in** — include the per-call escape hatch now, or defer?
3. **PDF library (#10)** — `pdfx` (native) recommended. Alternatives: `syncfusion`
   (heavy, commercial-ish), `pdfrx`, `flutter_pdfview`. Veto if you have a pref.
4. **Unified `show_file` (#2)** vs separate `show_markdown`/`show_text`/`show_pdf`/
   `show_html` tools. I recommend one tool (less prompt noise, one description);
   say if you'd rather have four.
5. **Caps (#6)** — text 1 MiB, PDF 10 MiB. Bump/lower?

## Expected structure

```text
pi-extension/src/
├── protocol/
│   ├── types.ts          ← +ServerMessage "agent_file"; kind union (Wave A)
│   └── codec.ts          ← + "agent_file" in SERVER_TYPES (Wave A)
└── index.ts              ← show_file handler: detect kind, read, validate, cap,
                            broadcast agent_file; filter context (Wave B)

app/lib/
├── protocol/protocol.dart            ← +AgentFile ServerMessage parse (Wave A)
├── domain/session_state.dart         ← +AgentFileMsg (ChatMessage variant) (Wave C)
├── ui/chat/
│   ├── chat_page.dart                ← case AgentFileMsg() → AgentFileBubble (Wave C)
│   └── widgets/agent_file_bubble.dart← tappable card → opens viewer (new) (Wave C)
└── ui/doc_viewer/                     (new dir)
    ├── doc_viewer_page.dart          ← router: kind → right viewer (new)
    ├── markdown_viewer.dart          ← gpt_markdown + source toggle (new)
    ├── text_viewer.dart              ← SelectableText monospace (new)
    ├── pdf_viewer.dart               ← pdfx paginated (new)
    └── html_viewer.dart              ← webview_flutter + sandbox (new)
```

---

## Wave A — Protocol (app + pi-extension)

**pi-extension** (`src/protocol/types.ts`):

```ts
// New ServerMessage — a document the agent shows to the user.
| {
    type: "agent_file";
    id: string;                       // UUID (dedup in app)
    in_reply_to: string;              // _currentTurnId (timeline anchor)
    kind: "markdown" | "text" | "pdf" | "html";
    data: string;                     // base64 of raw file bytes
    mime?: string;                    // original mime for display/save
    path?: string;                    // repo path (display / save name)
    caption?: string;
    size?: number;                    // raw bytes
  }
```

`src/protocol/codec.ts`: add `"agent_file"` to `SERVER_TYPES`.

**app** (`lib/protocol/protocol.dart`): new `class AgentFile extends ServerMessage`
with `fromJson`; add the case in `ServerMessage.fromJson`. Decode `data` base64 →
`Uint8List`; for text kinds decode further to `String` (UTF-8) in the domain layer.

**Acceptance**: `pnpm typecheck` (pi-ext) + `flutter analyze` green; codec
roundtrip of `agent_file`; `PROTOCOL.md` gains a "Documents from the agent" section.

---

## Wave B — pi-extension

### B1 — Tool `show_file` (`src/index.ts`, next to `_registerShowImageTool`)

```ts
const ShowFileParams = Type.Object({
  path:     Type.String({ description: "Path to a file in the repo (relative to session cwd). Markdown/text/code/PDF/HTML." }),
  caption:  Type.Optional(Type.String({ description: "Optional subtitle under the bubble." })),
  kind:     Type.Optional(Type.Union([Type.Literal("markdown"), Type.Literal("text"), Type.Literal("pdf"), Type.Literal("html")], { description: "Override auto-detection." })),
  allowNetwork: Type.Optional(Type.Boolean({ description: "HTML+JS only: allow remote resources/network. Default false (sandboxed)." })),
});
```

### B2 — Handler (detect → read → validate → cap → broadcast)

1. Resolve `path.resolve(params.path)`; reject if missing / not a regular file.
2. Determine `kind`: explicit `params.kind` wins; else detect by extension, then
   magic bytes (`%PDF-` for pdf). Unknown → `{ shown:false, error:"unsupported/unknown file type" }`.
3. `kind === "text" | "markdown"`: read bytes, decode UTF-8; if invalid UTF-8 →
   reject ("not a text file"). `kind === "html"`: read as UTF-8 too.
4. Stat → enforce cap by kind (text/markdown/html 1 MiB; pdf 10 MiB). Over →
   `{ shown:false, error:"file too large" }`.
5. Base64-encode the raw bytes → `data`. Set `mime` from kind/extension.
6. Broadcast **`agent_file`** via `_broadcastToActive` with `id`, `in_reply_to`,
   `kind`, `data`, `mime`, `path`, `caption`, `size`. For `html`, include
   `allowNetwork` flag carried through to the app — **see protocol note**: add
   `allowNetwork?: boolean` to the `html`-kind payload (or a top-level optional).
7. Return **metadata only**: `{ shown: anyPeerActive(), kind, path, mime, bytes }`.
   No peer → `{ shown:false, reason:"no active peer" }`.
8. Any exception → `console.error` + `{ shown:false, error }`; never crash the turn.

### B3 — Keep bytes out of the model context

`agent_file` is a ServerMessage on the app channel, so it never becomes a buffer
message / provider request (same as `agent_image`). The tool_result (B2.7) is
metadata-only. **No base64 in the tool_result.** Add a test asserting the
`agent_file` broadcast is not surfaced to `context`.

**Acceptance B**: `pnpm test` covers (a) `.md` → `kind:markdown` broadcast +
metadata-only result; (b) `.pdf` valid → broadcast with `%PDF-` verified; (c)
over-cap text → `shown:false`, no broadcast; (d) non-UTF-8 `.txt` → reject; (e)
unknown extension w/o `kind` → reject; (f) `kind` override forces rendering; (g)
no peer → `shown:false, reason`; (h) `agent_file` absent from `context`.
`pnpm typecheck && pnpm test` green, no regression.

---

## Wave C — app

### C1 — Domain (`domain/session_state.dart`)

```dart
class AgentFileMsg extends ChatMessage {
  final String kind;          // markdown | text | pdf | html
  final Uint8List bytes;      // raw
  final String? path;
  final String caption;
  final String? mime;
  final bool allowNetwork;    // html only
  // convenience: textContent (UTF-8 decoded) for markdown/text/html
}
```
Add to the `ChatMessage` sealed union; update the exhaustive switch in
`chat_page.dart` and any test switches.

### C2 — Ingest (`SyncService` / repo)

On `AgentFile`: base64 → `Uint8List`, build `AgentFileMsg`, insert at arrival
position, **persist locally** (reuse the plan/31 attachment path used by
`AgentImageMsg`). Dedup by `id`.

### C3 — Bubble (`ui/chat/widgets/agent_file_bubble.dart`)

Left-aligned assistant card. Content by kind:
- `markdown`/`text`: file icon + name + first ~3 lines (clamped).
- `pdf`: PDF icon + name + human size.
- `html`: HTML/JS icon + name + sandbox badge ("JS · offline"/"JS · online").
Caption under if present. Tappable → `DocViewerPage` (Hero optional for text
preview). Add `case AgentFileMsg() => AgentFileBubble(msg)` in `chat_page.dart`.

### C4 — Viewers (`ui/doc_viewer/`)

**`doc_viewer_page.dart`** — routes by `kind` to the right sub-viewer; common
chrome: top bar (filename + close), bottom bar (Share; Save where applicable),
tap to toggle chrome, swipe-down dismiss (mirror `ImageViewerPage`).

- **`markdown_viewer.dart`** — `gpt_markdown` (`MarkdownBody`) in a themed
  scroll; `SelectionArea` for copy; toolbar toggle **Source ⇄ Rendered**.
- **`text_viewer.dart`** — monospace `SelectableText.rich` (or `SelectableText`)
  in a scroll; line numbers optional; long-line wrap toggle. (Syntax highlight is
  a follow-up — add `highlight` + `SyntaxColors` later.)
- **`pdf_viewer.dart`** — `pdfx` `PdfDocument` → page list/`PdfView`, pinch-zoom
  via `InteractiveViewer`, page indicator. Verify Android `minSdk` ≥ 21 and iOS
  Podfile/Podspec.
- **`html_viewer.dart`** — `WebViewWidget` from `webview_flutter` +
  `webview_flutter_android` / `webview_flutter_wkwebview`. Write bytes to a temp
  file in the app docs dir and `loadFlutterAsset`/`loadFile` (avoid data: URL
  limits). `navigationDelegate`: **block all** requests except the local file
  itself when `!allowNetwork`; when `allowNetwork`, allow same-document + (opt-in)
  remote. JS on via `javascriptMode: unrestricted`. Badge reflects state.

**Acceptance C**: widget tests — `AgentFile` populates `AgentFileMsg` + persists;
tap opens the right viewer by kind; markdown renders + source toggle works; text
is selectable; pdf viewer builds and pages (smoke on device); html runs inline JS
(e.g., a `<script>` that sets `document.title`) and **blocks** a remote `<img>`
when sandboxed; dedup by id. `flutter analyze` 0 issues; `flutter test` green;
Android + iOS builds pass.

---

## Wave D — integration + docs

- **Persistence smoke**: show a file, kill app, reopen → bubble + viewer work.
- **Manual device smoke**: "show `README.md`" → markdown viewer; "show
  `big.pdf`" (over 10 MiB) → agent says too large; HTML with `<script>` runs but
  remote `<img>` is blocked (and loads when `allowNetwork`).
- **Docs**: `PROTOCOL.md` ("Documents from the agent"), `pi-extension/README.md`
  (agent tools list gains `show_file` with the kind table + sandbox note).

---

## Risks

1. **Wire size / relay**: a 10 MiB PDF → ~13 MiB on the wire (double-base64 in
   the opaque `ct`). Acceptable for MVP (rare); follow-up = binary relay channel
   (plan/30, plan/114 risk #1).
2. **WebView sandbox bypass**: `navigationDelegate` must reject *all* navigation
  and sub-resource requests (images, css, fonts, xhr, ws) when sandboxed, not
  just top-frame. Test with a known remote resource. Cleartext/ATS stays off.
3. **PDF native deps**: `pdfx` pulls platform code; first build needs
   `flutter clean` + `pod install` (iOS) and a `minSdk` check (Android). Bundle
   size increases.
4. **Local DB size**: persisting up-to-10 MiB PDF blobs locally could grow the DB.
   Mitigation: cap stored PDFs, or store path-only when feasible (deferred).
5. **Exhaustive `ChatMessage` switches**: adding `AgentFileMsg` forces every
   exhaustive switch/test to handle it (same churn as plan/114's `AgentImageMsg`).
6. **Large text decoding**: a 1 MiB text file in one `SelectableText` can jank;
   use line-based lazy rendering if needed.
7. **HTML with no network may "look broken"**: a doc referencing a CDN lib won't
   render. The badge + caption should set expectations; `allowNetwork` is the
   escape hatch (decision #1/#2).

---

## Definition of Done

- [x] Wave A: `agent_file` ServerMessage + parse both sides; `PROTOCOL.md` ("Documentos do agente"); `pnpm typecheck` green.
- [x] Wave B: `show_file` tool (detect + validate + per-kind caps + magic bytes + UTF-8) + `agent_file` broadcast + metadata-only result + bytes kept out of context (test); `pnpm test` green (14 unit + 1 broadcast integration).
- [x] Wave C1: `AgentFileMsg` in domain (`session_state.dart`).
- [x] Wave C2: ingest `AgentFile` → state + local persistence (`MessageRecord.file`) + dedup (`sync_service.dart`).
- [x] Wave C3: `AgentFileBubble` tappable card (`agent_file_bubble.dart`); `chat_page.dart` switch updated.
- [x] Wave C4: Markdown / Text / PDF / HTML(+JS) viewers (`lib/ui/doc_viewer/`); sandbox enforced via injected CSP meta + `NavigationDelegate`.
- [x] Wave D docs: `PROTOCOL.md` + `pi-extension/README.md` (tool `show_file` + sandbox note). New app deps in `pubspec.yaml`: `webview_flutter ^4.13.0`, `pdfx ^2.8.0`, `path_provider ^2.1.5`.
- [ ] Wave D verificação: `flutter pub get && flutter analyze && flutter test` + **device smoke** (needs Flutter toolchain + device — not runnable in this env).
- [x] Relay unchanged; bytes never reach model context (B3 test confirms).
- [ ] Commit: `feat(plan-126): agent document viewers (md/text/pdf/html)`

> **Verification caveat (as in plan/114)**: pi-extension side is verifiable here
> (`pnpm typecheck`/`pnpm test`). The Flutter app side needs a Flutter toolchain
> and a device — run `flutter pub get && flutter analyze && flutter test` and the
> device smoke before release.

---

## Next plans

- **Cockpit parity**: PDF + HTML(+JS) in the desktop `FileViewer` (md/text exist).
- **Binary relay channel**: kill the double-base64 tax for large PDFs (plan/30/114).
- **Replay of `agent_file` in `session_sync`**: if local-DB-wipe loss hurts.
- **Syntax-highlighted text viewer**: port cockpit's `highlight` + `SyntaxColors`.
- **`show_image` → `show_file` unification** (optional): fold images into one tool
  with `kind:image` later; keep `show_image` now for back-compat.
