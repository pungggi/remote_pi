# 105 — Android PDF share (native PdfRenderer)

## Context

Plan 104 added Share-to-attach for `image/*` and `text/plain`. The natural
next ask is **PDF**: share a PDF from Files / a browser / mail → it lands in
the Piper chat so the Pi can read it.

The catch: the relay protocol carries only **inline images** + text
(`user_message.images[]`, `text`). There is no file/blob channel — plan 30
deliberately scoped files out. A "real" PDF-as-file path would need
protocol-level support (relay + extension + app) — out of scope here.

What we *can* do without touching the protocol: **render the PDF to image(s)
on-device** with Android's native `PdfRenderer` (no Dart PDF dependency, no
abandoned-package risk) and feed them through the existing image pipeline
(`SharedImageInbox` → `AttachmentViewModel` → `user_message.images`).

## Decision: two phases

- **Phase 1 (this plan): page 1 only.** Render the first page to a PNG and
  attach it as a single image. Zero changes to the single-image attachment
  model — the PDF is transparently converted to an image at the native layer.
  Ships now, zero regression risk to camera/gallery/clipboard/image-share.
  Limitation: only page 1 is attached (logged natively; multi-page PDFs lose
  pages 2..N).
- **Phase 2 (deferred, `105b`): all pages (capped).** Requires extending the
  attachment model from `AttachmentAttached.image: PickedImage` to
  `images: List<PickedImage>`, rippling through `takeImageForSend →
  List<MessageImage>`, `sendMessage({List<MessageImage>? images})`, the
  composer preview, and tests. Real multi-page support; bigger change.

Phase 1 is shipped first because it is safe, immediate, and covers the common
single-page case (receipts, single-sheet docs, PDF exports of one screen).

## Phase 1 — structure

### Android

- `AndroidManifest.xml` — add `application/pdf` to the `SEND` intent-filter
  (Piper becomes a Share target for PDFs).
- `MainActivity.kt`
  - `stashShareIntent`: the image branch also accepts `application/pdf` —
    both stash the `EXTRA_STREAM` uri in `pendingShareUri`.
  - `consumeShareImage()`: branch on mime — `image/*` → read bytes (existing);
    `application/pdf` → `renderPdfFirstPage(uri)`.
  - `renderPdfFirstPage(uri)`: open the uri → `ParcelFileDescriptor` →
    `PdfRenderer` → `openPage(0)` → render to a `Bitmap` (scaled to ~1242px
    wide, white background so transparent PDFs aren't black slabs) → PNG bytes.
    Returns `{data, mime: "image/png"}`. Manual `close()` on page/renderer/pfd
    (`PdfRenderer`/`Page` are `AutoCloseable`, not `Closeable` — Kotlin `.use`
    doesn't apply).

### Dart

**Unchanged.** The native layer hands back a PNG, so
`ImagePickerService.consumeSharedImage()` → compress → `SharedImageInbox` →
`AttachmentViewModel.attachExisting` → preview → send works verbatim.

## Steps

1. Manifest: add `application/pdf` data element.
2. MainActivity: imports (`Bitmap`, `PdfRenderer`), stash + consume branches,
   `renderPdfFirstPage`.
3. `flutter build apk --debug`, install, verify via logcat that sharing a PDF
   stashes + renders page 1 and the chat attaches it.
4. Commit.

## DoD

- [ ] Sharing a PDF shows Piper in the Share sheet.
- [ ] Selecting Piper attaches page 1 as an image (preview + send).
- [ ] logcat: `rendered pdf page 1 of N → WxH`.
- [ ] Image / text share still works (no regression).
- [ ] `dart analyze lib test` clean.

## Next plans

- `105b` — multi-page: attachment model → `List<PickedImage>`, render up to N
  pages, preview shows count, send all as `images[]`.
