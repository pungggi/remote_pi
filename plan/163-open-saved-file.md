# Plan 163 — Open saved file (doc viewer)

## Context

Plan/158 added **Save to Downloads** to the doc viewer: bytes land in the
system MediaStore Downloads folder and the toast shows the stored name. But
saving is usually only step one of a workflow:

- A `.jwlibrary` backup (plan/162 binary cards) must be **opened** in JW
  Library to restore — the file sitting in Downloads does nothing by itself.
- Archives, APKs, office documents: the user wants to open them in the right
  app right away (ZIP manager, package installer, office suite).

Before this plan the user had to leave the app, open a file manager, find
Downloads, and tap the file. This plan closes that loop: **Save → snackbar
Open → the right app handles it.**

## Expected structure

### Android (MainActivity.kt)

- `saveToDownloads(name, mime, bytes)` now returns `Map<String, String>`:
  `{"name": <stored display name>, "uri": <MediaStore content URI>}` instead
  of just the display name. The URI is the new information — the name was
  already shown to the user.
- New channel method `openSavedFile(uri, mime)`:
  - Fires `ACTION_VIEW` with `FLAG_GRANT_READ_URI_PERMISSION` (the app owns
    the MediaStore entry, so a temporary read grant suffices).
  - Returns `true` when an activity handled it.
  - Catches `ActivityNotFoundException` → returns `false` (NOT an error:
    the file exists, nothing can render this MIME type).
  - Unexpected failures surface as `result.error("open_failed", ...)`.

### Dart (doc_viewer_page.dart)

- `_save()` tolerates BOTH native shapes:
  - `Map` → snackbar with label `Saved to Downloads · <name>` and an
    **Open** `SnackBarAction` (4 s, so the action is reachable).
  - Legacy `String` (older native side) → plain toast, no Open action.
- `_openSaved(uri)` invokes the channel; `false` → toast
  "No app can open this file type"; `PlatformException` → a typed failure
  toast. Never fails silently.

### Tests

`app/test/ui/doc_viewer/doc_viewer_save_test.dart`:

- `{name, uri}` → snackbar with a working Open action.
- Legacy `String` return → toast, no Open action (backward compat).
- `_fileName()` keeps real long extensions (`.jwlibrary`), only appends a
  fallback when absent.
- `openSavedFile` returning `false` → "no app" toast.

## Steps

1. Native: change `saveToDownloads` return type + add `openSavedFile`.
   **Acceptance**: Kotlin compiles; URI logged for debugging.
2. Dart: parse both return shapes, wire the snackbar action, add
   `_openSaved`. **Acceptance**: legacy native still shows a plain toast.
3. Tests: the four cases above. **Acceptance**: `flutter test` green.

## DoD

- [x] Native channel (`saveToDownloads` map + `openSavedFile`)
- [x] Dart snackbar Open action + legacy tolerance
- [x] Tests green (4 widget tests)
- [x] Shipped in app 1.6.2 (PR #106)

## Next plans

- Optional: **Open in…** (ACTION_SEND chooser) next to Open when several
  handlers exist — `ACTION_VIEW` picks the default today.
