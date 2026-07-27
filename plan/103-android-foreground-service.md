# 103 — Android Foreground Service (keep the relay WS alive in background)

> Fork plan. Low range belongs to upstream; this lives in `100+` per repo
> convention. Implementation target: **`app/`** (Flutter + native Android).
> Read `app/CLAUDE.md` + the relevant layer `CLAUDE.md` before editing any
> `app/` file.

## Context

### The pain (observed)

Switching focus away from the app drops the connection to the relay, and it has
to re‑establish on resume. Root cause (verified in code, not guessed):

- The app does **not** tear the socket down on background. `main.dart`'s
  `didChangeAppLifecycleState` only toggles the **mesh poll timer** — it never
  touches the relay link.
- The relay link is a **WebSocket** kept alive by (a) a 25 s protocol Ping
  (`connection_manager.dart:_startPing`) and (b) RFC 6455 `pingInterval`
  (`ws_transport.dart`). Both need the **Dart event loop running**.
- When the app backgrounds, Android **freezes the process** (Doze / App Standby /
  cached‑process eviction). The timers stop firing, the TCP socket goes stale or
  gets torn, the relay frees the room slot. On resume the dead socket surfaces as
  `onDone`/`onError` → `_onChannelLost` → the retry/backoff rebuilds the WS.

So the reconnect is **Android's process lifecycle vs. a long‑lived socket**, not
a deliberate reconnect. The user wants "stay connected is priority" — i.e. keep
the link alive across focus changes.

### The fix in one sentence

Run a **minimal native foreground service** in the app process whose only job is
to hold a persistent notification. That elevates the whole app process to
**foreground priority**, so Android does **not** freeze it, so the Dart root
isolate (and therefore `ConnectionManager` + `WsTransport` + pings) keeps running
while the UI is backgrounded.

### Honest scope (do NOT over‑promise)

A foreground service dramatically extends background lifetime — **from seconds
to hours** — which fully solves the reported pain (switching apps no longer drops
the link). It does **not** grant infinite background connectivity: Android 15
(API 35, the current `targetSdk`) caps the `dataSync` foreground‑service type at
**6 h**, and deep Doze throttles network for everyone. These are **Android's
ceiling**, not a gap to be closed by a future plan: when the cap or Doze wins,
the WS drops and the existing retry backoff + reconnect‑on‑resume recover
gracefully (no data loss — the relay resyncs on reconnect). This plan is
**self‑contained and deliberately Firebase‑free**: no Google project, no central
push service, no third‑party wake dependency — consistent with the fork's
self‑hosted model.

## Decisions (need confirmation before implementation)

| # | Decision | Recommended | Rationale |
|---|----------|-------------|-----------|
| 1 | **Custom native service vs package** | **Custom** (`KeepAliveService.kt`, no pub dep) | We only need a "priority anchor": a service that calls `startForeground()` and holds a notification. No background Dart logic, no separate isolate. A package (`flutter_foreground_task`) would add a dep + a second isolate for nothing. ~1 Kotlin file + manifest + a thin Dart channel. App convention: "Adicionar dependência sem registrar no plano correspondente" — here we add **none**, which is cleaner. |
| 2 | **Foreground‑service type** | **`dataSync`** | The canonical type for "persistent connection / ongoing data transfer." Declared + `FOREGROUND_SERVICE_DATA_SYNC` perm. **Android 15 caps `dataSync` at 6 h** — acceptable: on cap/kill the WS drops and reconnects on next foreground. If the fork later wants *indefinite* and is **not** Play‑bound (it isn't — sideloaded `ch.pungitore.piper`), `specialUse` is the escape hatch (no Play review needed; OS‑only). Start with `dataSync`. |
| 3 | **When it runs** | **Active peer ⇒ running; `StatusNoPeer` ⇒ stopped** | Keep the service alive across the transient states (`Online → Connecting → Retrying → Offline`) so a blip doesn't churn start/stop. Only stop when the user has **no peer** (`StatusNoPeer`). Started from the **foreground** (app is open when a peer connects) → never hits the Android‑14 "start FG service from background" restriction. |
| 4 | **On/off control** | **Default ON, with a Settings toggle** | Honours "stay connected is priority." A toggle ("Keep connection alive in background", stored in `Preferences`) lets users opt out for battery. When off, behaviour == today (drops on background). |
| 5 | **Notification UX** | **Persistent, low‑importance, non‑dismissable while connected** | Required by the FG‑service contract. Channel `piper_connection` (low importance → no sound). Content: "Piper · Connected to `<peer short>`". Tapping → opens app (already the default). Updates the peer name on `StatusOnline`. |
| 6 | **Battery** | **Accepted** | FG priority + WS keepalive keeps the radio warmer → more drain. User explicitly prioritised staying connected. Documented in Settings + plan; not a blocker. |

> If you want to change any of 1–6, say so before implementation starts. The rest
> of the plan assumes the recommended column.

## Expected structure

### Native (Android) — `app/android/app/src/main/kotlin/ch/pungitore/piper/`

- **`KeepAliveService.kt`** (new) — a `Service` that:
  - On `onCreate`: creates the notification channel (`piper_connection`,
    `NotificationManager.IMPORTANCE_LOW`, no sound/vibration).
  - On `onStartCommand`: builds the notification (small icon = app icon;
    contentTitle "Piper"; contentText from the intent extra `peer` or
    "Connected"; `setContentIntent` → `MainActivity` launch intent;
    `setOngoing(true)`); calls `startForeground(id, notif,
    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)`. Returns `START_STICKY`
    (Android restarts it if killed — it'll re‑surface and Dart re‑issues the
    current state via the channel).
  - Actions via intent extras / MethodChannel: `start`, `stop`, `update(peer)`.
- **`MainActivity.kt`** (modify) — registers a `MethodChannel`
  `ch.pungitore.piper/keepalive` with handlers:
  - `start(peerShort)` → `startForegroundService(intent w/ action START +
    extra peer)`.
  - `stop()` → `stopService(...)`.
  - `update(peerShort)` → posts a fresh notification (same id) with new text.
- **`AndroidManifest.xml`** (modify):
  - Add perms: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`,
    `POST_NOTIFICATIONS` (Android 13+ runtime perm).
  - Declare the service:
    ```xml
    <service
        android:name=".KeepAliveService"
        android:exported="false"
        android:foregroundServiceType="dataSync" />
    ```

### Dart — `app/lib/`

- **`data/transport/keep_alive_controller.dart`** (new, `data/` layer) — thin
  wrapper over the MethodChannel (`start`/`stop`/`update`). Pure async, no
  `BuildContext`. Exposes `Future<void> reflect(ConnectionStatus, {peerShort})`.
- **Wire to `ConnectionManager`** (modify `connection_manager.dart`): the manager
  already emits every status via `_emit`. Add a side‑effect listener (or fold
  into `_emit`) that, when a **Preferences** flag is on, calls
  `keepAlive.reflect(status, peerShort: …)`:
  - `StatusOnline` → `start` (+ `update` with peer short on change)
  - `StatusConnecting / StatusRetrying / StatusOffline` (while peer != null) →
    keep running (optionally `update` to "Reconnecting…")
  - `StatusNoPeer` → `stop`
- **`config/dependencies.dart`** (modify) — register `KeepAliveController` in
  the injector; resolve `Preferences` for the flag.
- **`data/preferences/preferences.dart`** (modify) — add a bool key
  `keepAliveInBackground` (default `true`).
- **POST_NOTIFICATIONS** — request at the right moment (on first `StatusOnline`
  if not granted), via `permission_handler` (already a dep? verify) or a direct
  MethodChannel call. On denial: the service still starts but the notification is
  suppressed by the OS → Android may then kill the service faster; degrade
  gracefully (log; show a one‑time Settings nudge).
- **UI toggle** — add a switch in the existing Settings/Preferences page
  ("Keep connection alive in background") bound to the new preference. Subtitle
  documents the battery trade‑off and the Android‑15 6h caveat.

### Tests

- Unit: `KeepAliveController.reflect` maps each `ConnectionStatus` to the right
  channel call (`start`/`stop`/`update`/no‑op). Stub the MethodChannel.
- Unit: `ConnectionManager` emits → controller called with the expected sequence
  across `Online → Retrying → Online → NoPeer` (start once, update on peer
  change, stop only on NoPeer — no churn on transient blips).
- Manual (acceptance — see Steps): real backgrounding on the Fold4.

## Steps (with acceptance criteria)

1. **Native skeleton — service + channel + manifest** — `KeepAliveService.kt`,
   MethodChannel in `MainActivity`, manifest perms + `<service>` declaration,
   notification channel.
   *Accept*: `flutter build apk --debug` succeeds; installing + triggering
   `start("test")` from a debug hook shows the persistent notification; `stop()`
   removes it; `adb shell dumpsys activity services ch.pungitore.piper` lists the
   service in the foreground slot with type `dataSync`.

2. **Dart controller + DI + status wiring** — `KeepAliveController`, register in
   `dependencies.dart`, side‑effect listener in `ConnectionManager`.
   *Accept*: pairing to the PC shows the notification "Connected to `<peer>`";
   losing+regaining the relay (kill relay, restart) keeps the service running
   through `Retrying` (notification flips to "Reconnecting…" and back) — **no
   stop/start churn**; `disconnect`/unpair → notification cleared + service
   stopped.

3. **The core acceptance test — background survival** — on the Fold4
   (`100.88.223.118` over tailnet adb), pair + go `Online`, then switch to
   another app / press Home / lock the screen.
   *Accept*: after **5 minutes** backgrounded, the relay still sees the phone
   peer connected (check `relay` logs / the PC's `peers.json` presence / Cockpit
   "online" indicator); on return the app shows **Online immediately — no
   "reconnecting" dance**. Repeat after **30 minutes** (light Doze) — still
   connected, or degrades gracefully (reconnects within the retry backoff). This
   is the proof that process foreground priority keeps the Dart isolate alive.

4. **POST_NOTIFICATIONS permission flow** — request on first connect.
   *Accept*: first pairing prompts for notification permission; denying still
   keeps the connection alive as long as Android tolerates a notification‑less FG
   service (document the degradation); granting shows the notification.

5. **Settings toggle** — `keepAliveInBackground` pref + UI switch.
   *Accept*: toggling off → next backgrounding behaves like today (drops +
   reconnects on resume); toggling on → survives per step 3. Persists across
   restarts.

6. **Notification content polish** — peer short name, "Reconnecting…" state,
   low‑importance channel (no sound/vibration), tap → app.
   *Accept*: notification reflects the live peer + connection state; tapping
   focuses the app; channel is `IMPORTANCE_LOW` (no buzz).

7. **Docs + decisions** — record in `00-decisions.md` (or a decisions addendum)
   that background keep‑alive is implemented via a **foreground service**
   (this plan), Firebase‑free by design. Update `app/CLAUDE.md` native section
   if a native‑conventions note is warranted.
   *Accept*: doc explains the honest limit (seconds→hours, not infinite) and the
   Android‑15 6h cap + deep‑Doze ceiling, with the reconnect‑on‑resume recovery
   noted.

## DoD

- [ ] 1 — Native service + channel + manifest; `dumpsys` confirms FG `dataSync`.
- [ ] 2 — Controller wired; notification reflects Online/Reconnecting; stop only on NoPeer.
- [ ] 3 — **5‑minute background test passes** (WS stays alive; no reconnect dance on resume).
- [ ] 4 — POST_NOTIFICATIONS requested; graceful degradation on denial.
- [ ] 5 — Settings toggle on/off works; persists.
- [ ] 6 — Notification UX (peer name, low importance, tap→app).
- [ ] 7 — Docs + decisions updated; honest about the Android‑15 6h cap + deep‑Doze ceiling.
- [ ] `dart analyze lib test` clean; `flutter test` green (only pre‑existing env failures).
- [ ] Debug APK installed on the Fold4, foreground service verified live.

## Risks & open questions

- **Android 15 `dataSync` 6 h cap** — for "switched away for a while" this is
  fine. If the fork needs *indefinite*, switch the type to `specialUse`
  (sideloaded → no Play review) and re‑declare. Defer unless 6 h proves too short
  in practice.
- **Deep Doze** — even a FG service's network is throttled in deep Doze /
  Doze‑on‑the‑go. Expect occasional drops on long stationary‑screen‑off; the
  retry backoff + reconnect‑on‑resume recover, and the relay resyncs on
  reconnect (no data loss). Honest by design — this is Android's ceiling.
- **Flutter engine root‑isolate behaviour under FG priority** — theory says a FG
  service keeps the whole process (incl. Dart root isolate) unfrozen; this is how
  audio/location apps keep streaming. Step 3 **empirically verifies** it for our
  case. If (unexpectedly) the isolate is throttled, fallback = move the
  keepalive/WS into a `flutter_foreground_task` background isolate (bigger
  refactor; revisit only if step 3 fails).
- **Battery drain** — accepted per decision 6; surfaced in Settings.
- **`permission_handler` availability** — verify it's already a dep; if not, use
  a 5‑line MethodChannel for POST_NOTIFICATIONS rather than adding the package
  (keep deps minimal, per app convention).

## Next plans

- **Possible `specialUse` upgrade** — only if the Android‑15 6 h `dataSync` cap
  proves too short in practice (sideloaded fork → no Play review needed).
- **Wake‑after‑kill (if ever wanted)** — deliberately **out of scope**. A true
  "OS killed me, wake me up" path would require a push mechanism; the fork is
  **Firebase‑free by choice** (no Google project / central push service). The
  foreground service is the chosen, self‑contained solution; deeper background
  survival than Android allows is simply not pursued.
