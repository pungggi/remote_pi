# 106 — Follow-me composer draft (text + attachments)

## Context

When the user switches sessions within Piper (Phone: back→Home→tap; Tablet:
detail pane keyed by `(epk, room)`), the unsent composer state — typed text in
`InputBar`'s `TextEditingController` and the attached images in the
route-scoped `AttachmentViewModel` — is **lost**, because both are recreated
on the switch. The user wants a single **follow-me draft**: the unsent text +
attachments carry across sessions until sent or discarded.

There is no draft store today. (The Pi-side `queuedMessages` are a different
thing — explicit follow-ups, not the input draft.)

## Decision (closed)

- **(b) Follow-me**, NOT per-session. One global draft, shared by every
  session's composer, cleared on send.
- **Text + attachments** both (the user explicitly wants attachments — e.g. a
  shared PDF — to follow too).
- **In-memory only** (survives session switches + backgrounding via the FG
  service). Lost on app kill/restart. Disk persistence = future (`106b`).

## Why it works

Session switches always dispose the old composer and mount a fresh one:
- Phone: switch = pop `/chat` (InputBar/AttachmentVM disposed) → push a new
  `/chat` (fresh instances read the draft).
- Tablet: `_DetailPane` is `key`ed per session → old torn down, new built.

The global `ComposerDraft` bridges the two: the old composer writes to it on
every change; the fresh one reads it on mount.

## Structure

- **`ComposerDraft`** (new, `data/share/composer_draft.dart`) —
  `extends ChangeNotifier`. Holds `text` + `List<PickedImage> images`.
  `setText`, `setImages`, `clear`, `hasContent`.
- **`InputBar`** — new nullable `ComposerDraft? draft` param. On `initState`,
  restore `_controller.text` from the draft. `_onTextChange` already fires on
  every edit → also `draft.setText(...)`. `_submit` clears the controller →
  draft text clears via that listener.
- **`AttachmentViewModel`** — new nullable `ComposerDraft? draft` ctor param.
  On construct, restore images from the draft (emit `AttachmentAttached` if
  non-empty). A `_commit(state)` wrapper = `emit` + `draft.setImages(...)`
  replaces plain `emit` on every **terminal** state change (attached / empty);
  `AttachmentPicking` stays a plain `emit` (transient — don't clobber the
  draft mid-pick). `takeImagesForSend` commits empty → draft images clear.
- **Wiring** — `dependencies.dart` registers + injects `ComposerDraft`;
  `main.dart` adds it to the `MultiProvider`; `chat_page.dart` passes
  `draft: context.read<ComposerDraft>()` to `InputBar`.

Send clears both halves: `_submit` clears the controller (→ draft text ''),
`takeImagesForSend` commits empty (→ draft images []).

## Steps

1. `ComposerDraft`.
2. `AttachmentViewModel`: draft param + restore + `_commit`.
3. `InputBar`: draft param + restore-on-mount + `setText` on change.
4. Wire (dependencies / main / chat_page).
5. Build, run attachment tests, install.

## DoD

- [ ] Type in Session A → switch to Session B → the text is in B's field.
- [ ] Attach a PDF in A → switch to B → the pages are attached in B.
- [ ] Send in B → draft cleared → switch to A → empty composer.
- [ ] Existing attachment tests pass; `dart analyze` clean.
- [ ] Pick-in-flight doesn't wipe a pre-existing draft (Picking uses `emit`).

## Next plans

- `106b` — persist the draft to disk (survive app restart). Images → a cached
  file; text → preferences.
