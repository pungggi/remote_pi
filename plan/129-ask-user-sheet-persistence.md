# 129 — ask_user sheet persistence (don't drop it when the chat isn't open)

## Context

Reported: *“Sometimes the ask_user dialogue does not show up — I can tell
when.”* Repro: the ask fires while the **app is backgrounded or just
relaunched**, and the sheet **never** appears (only a re-trigger helps).

Root cause: the `extension_ui_request` (ask_user) was delivered to a
**broadcast** `StreamController` in `SyncService` whose **only** listener was
`ChatViewModel` — a per-route viewmodel that exists only while `/chat` is
mounted (`ViewmodelProvider<ChatViewModel>()` inside the `/chat` route).

- **Backgrounded** → no live listener (isolate/channel suspended) → event lost.
- **Cold-relaunch** → relay reconnects, `session_sync` replays
  `pendingRequests()` (the plan/100 server-side fix), but the replay lands
  while the app is on **Home** (cold start opens the session list, not chat)
  → still no listener → dropped a second time.
- Nothing cached the “current” request, so `_bootstrap()` had nothing to seed
  `_pendingUiRequest` from → **never recovers**.

Asymmetry: the other transients (`streaming`, `working`, `queued`) are cached
in `SyncService` and seeded on `_bootstrap()`. The UI request was the odd one
out — stream-only. That was the bug. plan/100’s replay was *necessary but
insufficient*; it lacked the matching app-side durable holder.

## What changes

`SyncService` becomes the **durable SSOT** for the current pending request;
`ChatViewModel` reads it live (like `streaming`/`working`) and keeps only the
submit-result error.

```
sync_service.dart
  + ExtensionUiRequest? _currentExtensionUiRequest          // durable cache
  + ExtensionUiRequest? get currentExtensionUiRequest       // SSOT reader
  + void _handleExtensionUiRequest(ExtensionUiRequest)      // notify/interactive logic (request only)
  _onServerMessage ExtensionUiRequest case → _handleExtensionUiRequest(msg); then broadcast ping
  _resetTurnState → _currentExtensionUiRequest = null       // session switch drops the old session's ask

chat_viewmodel.dart
  - _pendingUiRequest field                                  // now read live from sync
  _onExtensionUiRequest → tracks _pendingUiError only (warning → set; completed/new → clear)
  _compose → pendingUiRequest: _sync.currentExtensionUiRequest
  respondExtensionUi → unchanged (owns the optimistic/offline error)
```

Why the request lives in sync but the error stays in the viewmodel: the error
is ephemeral retry feedback tied to the mounted modal + the local submit; the
request must survive route/background/relaunch, so it is the cached SSOT.

## Acceptance (DoD)

- `flutter analyze` → 0 issues.
- Existing `extension_ui_viewmodel_test.dart` (open/warning/dismiss/unmatched/
  replace/offline/exception) stays green — no behaviour change while mounted.
- New tests:
  1. request pushed **before** any viewmodel exists → late-mounted VM still
     shows it.
  2. a flow that **resolved** (completed notify) while no VM was mounted is
     **not** re-surfaced (no phantom sheet).
- Full suite: green except the two known pre-existing failures.

## Next

- (Optional) hold the submit-result error in `SyncService` too, so a warning
  that arrived while unmounted also re-surfaces — currently a missed warning
  just shows the open sheet without the retry message (acceptable: the user can
  still answer/resubmit).
- (Optional) server-side: consider a periodic `pendingRequests` heartbeat so a
  very long-lived backgrounded app still re-syncs on resume.
