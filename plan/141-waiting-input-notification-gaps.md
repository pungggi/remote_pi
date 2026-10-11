# Plan 141 — Waiting-for-input notification gaps (snapshot · cancel · permission)

## Context

User report (2026-10-10): "when a session waits for a user answer (orange dot
in the session list), the system should display an Android notification;
tapping it should open the right session." The feature **exists** — plan/134
(PRs #59 + #58) ships the whole chain (`ui_prompt_start/end` →
`meta.waiting_for_input` → amber dot + `WaitingInputNotifications` banner →
tap routes to the session via the plan/132 machinery). But in practice the
banner **never appears** for this user, and code inspection confirms three
gaps that explain it:

1. **Rising-edge-only while backgrounded.** The banner fires only on the
   working→waiting *transition* observed while the app is already
   backgrounded. The common real-world flow — dot appears while the user is
   looking at the app, then they pocket the phone — produces **no
   notification ever**. (ConnectionManager replays never emit transitions, so
   a reconnecting/restarted process can't recover either.)
2. **Permission hole.** `POST_NOTIFICATIONS` (Android 13+) is requested only
   when the keep-alive service starts (`KeepAliveController._ensurePermission`)
   or when a plan/132 completion toggle is enabled. Fresh install +
   "when charging" mode while discharging → prompt never shown →
   `hasPermission()` gate silently drops every waiting banner.
3. **Stale banner.** Answering the prompt (falling edge) never *cancels* the
   tray notification — `LocalNotifications` has no `cancel()` — so a banner
   can outlive the wait it described.

The wire chain is confirmed healthy (the orange dot renders ⇒ extension →
relay → app parse all work); all fixes are **app-only**.

### Decisions (interview 2026-10-10)

| # | Decision |
|---|---|
| 1 | **Background snapshot**: on `setBackgrounded(true)`, notify for every live waiting room (except the room whose pi-ask sheet is open). |
| 2 | **Cancel on clear**: falling edge cancels that room's banner from the tray. |
| 3 | **Proactive permission ask**: one durable ask at the first foreground waiting edge (no sheet open) + a Settings row for denied users. |
| 4 | ~~Foreground behavior otherwise unchanged~~ **AMENDED 2026-10-11** (user, during on-device verification): **every rising edge notifies, foreground included** — the tile dot alone proved too easy to miss with the app open on the desk. Sheet-open suppression and the permission gate stay; the ask stays foreground-only (the OS dialog can't appear from the background); the snapshot still covers prompts that were already pending when the app connected (replays emit no rising edge). |

## Expected structure

### A. `LocalNotifications` — add `cancel(int id)`

Interface + `FlutterLocalNotifications` impl (`_plugin.cancel(id)`, same
defensive try/catch as `show`).

### B. `WaitingInputNotifications` — the three gates change

- Constructor gains `LocalBoxes boxes` (durable `permission_asked` flag lives
  in the existing `notify_prefs` Hive box — user intent, same home as the
  plan/132 toggles).
- New injectable `List<({String epk, String roomId})> Function()? liveWaitingRooms`
  (wired in `main()` over `ConnectionManager.roomsSnapshot` +
  `isRoomWaitingForInput` — the latter already gates on `StatusOnline` +
  `_liveRoomIds`, so dead rooms can't notify).
- **`setBackgrounded(true)` → snapshot**: for each live waiting room, skip
  open-sheet room → permission gate → `show()` with the existing stable
  per-room id (same-id `show` replaces, so lifecycle flapping can't stack).
- **Falling edge → `cancel(stableId)`** regardless of foreground/background
  (a banner fired earlier while backgrounded must clear when answered).
- **Foreground rising edge → one-time permission ask**: if permission missing
  and `permission_asked` unset → set flag + `requestPermission()` (activity
  is resumed here, so the OS dialog actually shows). Skipped when a sheet is
  open for that room (never interrupt answering). Denied users recover via
  the Settings row; the flag prevents re-nagging.
- Banner copy/title/payload unchanged (plan/134 discipline: generic body, no
  prompt content on the wire).

### C. Settings — notification permission row

- `SettingsViewModel` gains optional `LocalNotifications` (same optional-DI
  pattern as `MeshSyncService`) + `hasNotificationPermission()` /
  `requestNotificationPermission()`.
- `settings_page.dart`: `_NotificationsSection` tile ("Session alerts") after
  the reliability entry — shows Allowed / Not allowed; tap requests
  permission; still-denied → SnackBar pointing at system settings (Android
  suppresses the dialog after two denials).

### D. Docs

- `CHANGELOG.md` Unreleased → Added (also feeds the in-app What's-new page,
  plan/123). No `PROTOCOL.md` change — no wire change.

## Steps (com critério de aceite)

1. **`LocalNotifications.cancel`** (A). *Aceite*: fake in tests records
   cancels; impl swallows platform errors.
2. **Facade gates** (B). *Aceite* (vitest→flutter test):
   - snapshot on backgrounding fires per live waiting room, skips open-sheet
     room, skips when callback unset;
   - `setBackgrounded(false)` fires nothing;
   - falling edge cancels with the id it showed;
   - foreground rising edge with permission missing asks exactly once
     (durable flag), sheet-open defers the ask;
   - existing 7 plan/134 tests stay green (fake gains cancel/request
     tracking).
3. **Wiring** (B/C): `dependencies.dart` (boxes + viewmodel param), `main.dart`
   (`liveWaitingRooms` closure). *Aceite*: `flutter analyze` zero issues.
4. **Settings row** (C). *Aceite*: row reflects permission state; tap
   requests; denied-then-granted flips the subtitle.
5. **Changelog** (D). *Aceite*: entry visible in Settings → What's new.
6. **On-device verification** (debug build): dot visible → background the app
   → banner within ~1 s; answer at terminal → banner clears; tap → the right
   session opens (warm + cold).

## DoD

- [x] 1–5 implemented — `flutter analyze` zero new issues; `flutter test`
      831 green (was 823 on `main`: +8 plan/141 tests — snapshot ×4,
      cancel-on-clear, permission-ask ×3).
      Implemented 2026-10-10: `LocalNotifications.cancel` (named `id:`),
      facade snapshot/cancel/ask gates + durable `permission_asked` flag in
      `notify_prefs`, `liveWaitingRooms` wiring in `main.dart`, Settings
      "Session alerts" row (viewmodel + tile), CHANGELOG entry.
- [ ] On-device verification (Android 13+ debug build) — step 6
- [ ] Honest limits unchanged and still true: local-only (no push), process
      must be alive (keep-alive), one connected peer, sheet-open room never
      double-signals

## On-device verification findings (2026-10-11)

Debug build (`applicationIdSuffix .debug`) side-by-side on the user's
Samsung; logcat + secure-storage dumps via `adb run-as`.

1. **`ForegroundServiceDidNotStartInTimeException`** — banner tap after the
   FGS start crashed the app (`startForegroundService` from a cached process
   + pure-Dart ed25519 backlog ≈ 0.4–2.5 s/frame on the main isolate →
   `startForeground` ran past the 5 s budget). Fix in plan/142
   (`startForeground` moved into `onCreate`). Root-cause follow-up: the
   crypto backlog itself (own plan, not scheduled).
2. **Banner tap landed on the session list instead of the chat** —
   `_openFromCompletionTap` (plan/132) exact-matched
   `p.remoteEpk == toAppEpk(payloadEpk)`, but PairingStorage holds BOTH
   base64url and standard forms depending on pairing era (see the warning
   in `epk_encoding.dart`): this device's fresh pairing stored the
   **standard** form, the lookup silently returned null and the tap was
   dropped. Older pairings (url-safe) matched by luck — which is why
   plan/132's tap routing appeared to work. Fixed by comparing
   `toStandardB64()` on both sides and using the STORED epk form
   downstream (`setSelectedRoom` / `SessionSelection.select` /
   ChatViewModel's bootstrap all exact-match against PairingStorage).
   Added `debugPrint` breadcrumbs (`[notif-tap] …`) to every branch of the
   tap path — the routing failed silently before, invisible without a
   debugger attached.

## Riscos & próximos

- **Room dies mid-prompt** (relay `room_ended`, no falling edge): the banner
  lingers until tapped; tap opens the session greyed. Accepted residual —
  a `room_ended`-driven cancel would need a new stream for one rare case.
- **Snapshot on `inactive`**: lifecycle fires `inactive` before `pause` on
  Android; the snapshot may run a beat early. Harmless — same-id replace.
- **Battery**: unchanged ceiling — without keep-alive the process freezes and
  nothing fires (documented in plan/132/134).
- Future (separate plan): foreign prompts rendered as answerable cards
  (plan/134 "next" already earmarks this); per-session waiting toggle if the
  always-on policy ever feels noisy.
