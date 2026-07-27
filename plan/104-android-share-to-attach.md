# 104 — Android Share-to-attach (receive a shared image)

> Fork plan (`100+` range). Implementation target: **`app/`**. Read
> `app/CLAUDE.md` + the relevant layer `CLAUDE.md` before editing.

## Context

Clipboard paste (plan 30-followup) is **fragile**: an image must actually be on
the system clipboard, and on Android a screenshot is saved to the gallery — it is
**not** copied to the clipboard. Diagnostics confirmed it: `primaryClip null
(empty)` when the user "pasted" a screenshot. So paste only works for the rarer
case of an explicitly-copied image.

The robust, canonical Android mechanism is the **Share sheet** (`ACTION_SEND`):
the system launches the target app handing it the image as a content URI in
`Intent.EXTRA_STREAM` **plus an automatic temporary read grant**. The app reads
the bytes via `ContentResolver` and it **always works** — no clipboard
dependence, no OEM quirks. This is how the Claude Code app (and every Android
app that "receives" an image) does it.

**Goal:** register Piper as a Share target for `image/*`. From Gallery, the
screenshot Share button, Files, or a browser's "share image" → Share → Piper →
the image lands **pre-attached** in the active peer's chat (caption + send).
Clipboard paste stays as a secondary path.

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Custom native, dep-free** | Consistent with `KeepAliveService` + the clipboard channel we already have; avoids the abandoned-package risk of `receive_sharing_intent`. We only handle `image/*` (simple scope). |
| 2 | **`MainActivity` is the share target** (single-activity) | It's already `launchMode="singleTop"` → a warm share delivers via `onNewIntent` to the existing instance (no duplicate activities). Cold start delivers via the launch `Intent`. |
| 3 | **Global `SharedImageInbox`** (DI singleton) | The chat's `AttachmentViewModel` is route-scoped (rebuilt per `/chat` mount), so the pending image must live in an app-global holder that survives until the chat consumes it. |
| 4 | **Target = active peer's chat** | `Preferences.selectedPeerEpk`, else the first paired peer. If no peer → the share is dropped with a "Pair a Pi first" nudge on Home (can't send anyway). |
| 5 | **Keep clipboard paste** | Complementary: paste for the rare explicitly-copied image; Share for everything else. Both feed the same attach pipeline. |
| 6 | **Reuse the attach pipeline** | A shared image becomes a `PickedImage` and enters via the same `AttachmentViewModel` → preview → `sendMessage(text, image:)` path as camera/gallery/clipboard. |

## Expected structure

### Native — `app/android/app/src/main/`

- **`AndroidManifest.xml`** — add to `MainActivity`:
  ```xml
  <intent-filter>
      <action android:name="android.intent.action.SEND"/>
      <category android:name="android.intent.category.DEFAULT"/>
      <data android:mimeType="image/*"/>
  </intent-filter>
  ```
- **`MainActivity.kt`** — stash the shared URI and expose it to Dart:
  - `onNewIntent(intent)`: if `ACTION_SEND` + `EXTRA_STREAM` is an image URI →
    stash it (overwrite any prior).
  - `configureFlutterEngine`: if the **launch** intent is an `ACTION_SEND`
    image → stash it (cold start).
  - MethodChannel `ch.pungitore.piper/share` → `consumeImage()` reads the
    stashed URI via `ContentResolver` → bytes (the read grant from the share is
    in effect), then clears the stash. Returns `{ data: ByteArray, mime }` or
    null. (Reuse the `PiperClip` URI→bytes logic; tag the logs `PiperShare`.)

### Dart — `app/lib/`

- **`data/share/shared_image_inbox.dart`** (new) — a `ChangeNotifier` holding an
  optional `PickedImage`. `deposit(PickedImage)` (notifies) + `consume() →
  PickedImage?` (reads + clears, no notify). App-global.
- **`data/images/image_picker_service.dart`** — add `consumeSharedImage()` (to
  the interface as a default `async => null`, like `pickFromClipboard`): invoke
  `share/consumeImage`, compress to JPEG (≤1568px/q80) like the other pickers →
  `PickedImage?`.
- **`config/dependencies.dart`** — register `SharedImageInbox` (`addInstance`);
  inject it into `ChatViewModel`.
- **`main.dart`** —
  - Cold start: after `setupDependencies()`, `consumeSharedImage()` → if present,
    `deposit()` into the inbox (the router isn't built yet, so routing happens
    when Home mounts — see below).
  - Warm share: in `didChangeAppLifecycleState(resumed)`, `consumeSharedImage()`
    → `deposit()` → if the current route isn't `/chat` and a peer exists,
    `_router.push('/chat')`.
- **`ui/home/home_page.dart`** — on mount, if the inbox has a pending image and a
  peer exists → mirror `Home._open`'s `push('/chat')` (cold-start routing). If no
  peer → snackbar "Pair a Pi first" + clear the inbox.
- **`ui/chat/viewmodels/chat_viewmodel.dart`** — inject `SharedImageInbox`; on
  init, `consume()` any pending image → if present, ask the `AttachmentViewModel`
  to attach it; subscribe to the inbox so a **warm share while already on the
  chat** attaches live (no re-mount needed). Unsubscribe on dispose.

### Tests

- Unit: `SharedImageInbox` deposit/consume/clear semantics.
- Unit: `consumeSharedImage` maps a native `{data, mime}` → compressed
  `PickedImage` (stub the channel).
- Manual (acceptance): Share an image from Gallery → Piper opens on the chat
  with the image preview attached; type a caption + send; the PC receives it
  (and `pi-multimodal-proxy` describes it for a text-only model).

## Steps (with acceptance criteria)

1. **Manifest + native stash/consume** — intent-filter, `onNewIntent` +
   launch-intent stashing, `share/consumeImage` channel.
   *Accept*: `adb shell dumpsys package ch.pungitore.piper` lists the SEND
   intent-filter; Piper appears in the system Share sheet for images;
   `consumeImage` returns bytes after a share (visible in `PiperShare` logs).
2. **`SharedImageInbox` + `consumeSharedImage` + DI** — inbox registered,
   `ChatViewModel` receives it.
   *Accept*: `dart analyze` clean; inbox unit test green.
3. **Routing — cold start + warm** — main() deposit; Home routes on mount;
   resume pushes /chat; ChatViewModel consumes + live-subscribes.
   *Accept*: Share from Gallery while Piper is **closed** → Piper opens on the
   chat with the image. Share while Piper is **backgrounded** → same. Share
   while **on the chat** → image attaches without a re-mount.
4. **No-peer path** — share with no paired peer → "Pair a Pi first" snackbar;
   inbox cleared.
5. **End-to-end** — caption + send; the image arrives on the PC.

## DoD

- [ ] 1 — Piper is a system Share target for `image/*`; `consumeImage` returns bytes.
- [ ] 2 — Inbox + `consumeSharedImage` + DI; analyze clean; unit test green.
- [ ] 3 — Cold-start, warm-background, and on-chat shares all attach correctly.
- [ ] 4 — No-peer path degrades gracefully.
- [ ] 5 — Image round-trips to the PC (and through `pi-multimodal-proxy`).
- [ ] Clipboard paste still works (regression check).

## Risks & open questions

- **`singleTop` + warm share** — `onNewIntent` fires on the existing instance.
  Verify the stashed URI is consumed exactly once (the `consume` clears it).
- **Cold-start routing vs the boot redirect** (`/boot → /home`) — deposit in
  `main()`, route from Home on mount, so the boot redirect is never fought.
- **Large images** — compress reuses the existing ≤1568px/q80 path; the iterative
  size ceiling isn't applied (single pass) — acceptable; can add if a share
  blows the inline limit.
- **Multiple peers** — v1 uses selected/first; a future "share → pick peer"
  sheet is an additive upgrade.
