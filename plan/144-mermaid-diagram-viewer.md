# Plan 144 — Mermaid diagram viewer (show_file kind)

**Objective**: give the agent a first-class way to show Mermaid diagrams on the
paired phone. `show_file` gains a fifth kind, `mermaid`, next to
markdown/text/pdf/html. The app renders the diagram in a sandboxed WebView with
a bundled, offline copy of mermaid.js.

## Context

Agents produce Mermaid source constantly: architecture sketches, flows, sequence
diagrams. Today the only way to show one is to hand-write an HTML wrapper, load
mermaid from a CDN, and push it as `kind: "html"` with `allowNetwork: true`.
That breaks the sandbox promise and fails offline.

Plan/126 built the document pipeline (`agent_file` + `DocViewerPage` routing by
`kind`). This plan adds one more kind to that pipeline. No new tool, no new
message type, no relay change.

## Fixed decisions

| # | Decision | Value |
|---|---|---|
| 1 | Surface | `show_file` kind `mermaid`. Extensions `.mmd` / `.mermaid` auto-detect; `kind=` override forces it |
| 2 | Rendering | **Bundled** `mermaid.min.js` (v11) as an app asset, WebView, strict offline CSP. Why: works offline, keeps the plan/126 sandbox discipline. Precedent: `cockpit/assets/md_preview` bundles markdown-it |
| 3 | Wire | `agent_file.kind` gains `"mermaid"`, `mime: text/vnd.mermaid`, text cap (1 MiB), UTF-8 validated |
| 4 | Theme | mermaid theme follows the app brightness: `dark` in dark mode, `default` in light mode |
| 5 | Zoom | In-page pan/zoom (pointer events + CSS transform). Why: webview_flutter exposes no native pinch-zoom API |
| 6 | Errors | Parse errors render in-page (readable message), Flutter spinner stops via a JS channel. Mermaid stays at `securityLevel: "strict"` (default) so labels are sanitized |
| 7 | Scope | App + pi-extension + protocol docs. Cockpit does not render `agent_file` and stays untouched |

## Steps

1. **pi-extension**: `ShowFileKind` + detection + mime + schema/description.
   Acceptance: `show_file` on a `.mmd` file reports `kind: "mermaid"`, metadata
   only; unit tests in `show_file.test.ts` pass.
2. **Protocol**: `types.ts` union + PROTOCOL.md kind list.
3. **App**: `MermaidViewer` (WebView, bundled asset inlined into a temp HTML
   page, CSP `default-src 'none'`, pan/zoom, theme-aware), routing in
   `DocViewerPage`, bubble icon/label, pubspec asset.
   Acceptance: `flutter analyze` clean; `agent_file_test.dart` dispatches the
   new kind; manual check renders `graph TD; A-->B`.
4. **Docs**: pi-extension README + CHANGELOG entries.

## DoD

- `show_file({ path: "x.mmd" })` pushes a bubble; tap opens the diagram,
  offline, themed, zoomable.
- Invalid Mermaid source shows an in-page error, not a hang.
- Extension vitest + `flutter analyze` + app protocol tests green.

## Next plans

- Mermaid code fences inside the Markdown viewer (separate; needs gpt_markdown
  block handling).
- Cockpit parity if `agent_file` ever lands there.
