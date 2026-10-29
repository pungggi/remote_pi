# 153 — Balanced Active Sessions + UnifiedPush Wake

> Fork plan. Implementation targets: **`app/`** and **`relay/`**. No
> `pi-extension/` protocol or behavior change is expected.
> Branch: `feat/balanced-active-session`.
> Research: [`review/balanced-active-session-research.md`](../review/balanced-active-session-research.md).

## Context

The current keep-alive choices are too coarse:

- **Always:** reliable, but keeps the Android foreground service and relay
  WebSocket active for long idle periods. This causes heat and battery drain.
- **When charging:** good on power, but unreliable in the background on
  battery.
- **Off:** lowest Piper-owned background cost, but recovery depends on the
  user opening the app.

The research confirms a viable middle path:

- Keep the WebSocket and foreground service while an agent run is active.
- Keep them for a short grace period after the last relevant activity.
- Enter a real connection sleep after the grace period.
- Use UnifiedPush as a wake channel for events that arrive while sleeping.
- Reconnect and resynchronize after every wake. Push is not the stream and is
  not the source of truth.

### User decisions for this plan

- **Scope:** Balanced plus UnifiedPush, including new PC-started runs while
  the app is sleeping.
- **Grace period:** **5 minutes** after the last active run or relevant wake
  activity.
- **Push provider:** UnifiedPush. FCM and the embedded FCM distributor are
  not part of this plan.
- **Service type:** keep `dataSync`; implement its timeout correctly. Do not
  switch types merely to evade the Android 15 limit.

### Why both pieces are necessary

A sleeping WebSocket cannot tell the app that a PC started a new run. The
UnifiedPush distributor provides the wake path. The relay WebSocket then
resumes for live state and streaming.

Conversely, push alone is not sufficient:

- Payloads are small and best-effort.
- They are unsuitable for agent chunks and continuous presence.
- Android may still restrict background execution.
- Correctness must always be recovered by a full reconnect and sync.

## Goals

1. Add an opt-in **Balanced / Active sessions** keep-alive mode.
2. Preserve the current default `whenCharging` and all legacy mode behavior.
3. Keep active runs and notifications working in the background.
4. After 5 minutes without relevant activity, stop all of the following:
   - foreground service
   - WebSocket
   - protocol pings and rechecks
   - retry and reconnect timers
5. Register the app with a user-selected UnifiedPush distributor.
6. Let the relay send encrypted Web Push wake events even when no app
   WebSocket is connected.
7. Wake for new runs and waiting-for-input events, and deliver completion
   notifications according to the existing per-session opt-in.
8. Reconnect and fully synchronize on every wake or foreground transition.
9. Handle Android 15+ `dataSync` timeout without a crash or restart loop.
10. Measure the result on physical hardware with two distributors.

## Non-goals

- No Firebase project or embedded FCM fallback.
- No implementation of a UnifiedPush distributor or push server.
- No push of prompt text, agent output, code, images, or chat content.
- No exactly-once push guarantee or durable push-event replay.
- No WorkManager/JobScheduler replacement for the live WebSocket.
- No FGS type change to `remoteMessaging` or `connectedDevice`.
- No iOS background architecture in this plan.
- No native-crypto rewrite. Active-stream CPU profiling is a follow-up if
  measurements show that radio sleep does not address the heat.

## Design overview

### Keep-alive modes

| Mode | Background behavior |
|---|---|
| `whenCharging` | Existing behavior, remains the default |
| `always` | Existing behavior |
| `off` | Existing behavior |
| **`balanced`** | Active/grace connection, real idle sleep, UnifiedPush wake |

Selecting `balanced` enables local balanced behavior even if no distributor is
installed. In that case the UI must state the limitation: new PC events after
deep idle are discovered only when the app is opened.

### Balanced state machine

#### Foreground

- Connect immediately if not online.
- Do not run the foreground service.
- Use the existing active power cadence.
- Show cached rooms while a fresh snapshot is in flight.

#### Background with active work

- Start or keep the foreground service.
- Keep the WebSocket connected.
- Use lean cadence on battery.
- Track `working=true` across all subscribed rooms.
- Keep the connection while at least one relevant room is working.

#### Grace period

Start a **5-minute** timer:

- when the last active run finishes
- when the app enters the background without active work
- after a waiting-for-input wake
- after another explicit wake that has no active-run snapshot yet

Rules:

- A new active run cancels the timer.
- The timer restarts only for meaningful run/wake activity.
- Presence frames, model changes, git updates, snapshots, and other routine
  metadata must not keep the app awake indefinitely.
- Waiting for input does not hold the connection forever. Notify and use the
  grace period; tapping the notification returns to the foreground.

The 5-minute value is a constant injected into the controller for tests. A
user-facing duration setting is not part of the first implementation.

#### Sleeping

Add an explicit connection state, preferably `StatusSleeping`, rather than
reusing `StatusOffline` or `StatusNoPeer`.

On entry:

- cancel retry, ping, recheck, watchdog-driven reconnect, and pending connect
- close the current channel
- retain the active peer, subscriptions, pairing, selected room, and caches
- stop the foreground service
- emit `StatusSleeping`

While sleeping:

- `NetworkMonitor` must not redial merely because connectivity changed.
- The watchdog must not schedule a retry.
- A stale `onDone` from the old channel must not start a reconnect.
- Routine relay state is allowed to be stale.

On foreground, manual reconnect, or accepted wake:

- clear the sleeping flag before dialing
- reset backoff
- connect immediately
- replay subscriptions
- request presence/rooms snapshots and the normal session sync

### Activity sources

Use existing state and events:

- `RoomInfo.working` and `isRoomWorking`
- `runDoneStream`
- `waitingForInputStream`
- rooms snapshots for reconciliation after reconnect

Add a single aggregated view such as `liveWorkingRooms` or
`hasActiveRuns`. Do not create a second room-state cache.

### Android timeout

`KeepAliveService` currently uses `FOREGROUND_SERVICE_TYPE_DATA_SYNC`.
Android 15+ limits this type to 6 hours in 24 hours for applicable target SDKs.

Implement `Service.onTimeout()` so it:

- stops foreground and calls `stopSelf()` within the required window
- notifies Dart through a guarded platform-channel callback
- causes the balanced coordinator to suspend the connection
- prevents automatic FGS restart until a valid foreground/user interaction

A timeout must not leave the Dart socket and retry loop running without the
service. If Android refuses another FGS start because the quota is exhausted,
show notifications when possible but do not loop restart attempts.

The existing early `startForeground()` hardening from plan 142 must remain.

## UnifiedPush architecture

### Components

- **Piper app:** uses the official Flutter UnifiedPush connector.
- **Distributor:** installed and selected by the user. It owns the persistent
  connection to its push server.
- **Push server:** external to this repository and chosen through the
  distributor ecosystem.
- **Piper relay:** acts as the Web Push application server.

The relay stores registrations, produces wake events, encrypts payloads with
Web Push, signs requests with VAPID, and posts them to the registered endpoint.
A native Web Push endpoint needs no rewrite proxy. A provider-specific proxy is
only an external prerequisite when that provider cannot accept Web Push
directly.

### Dependencies

At implementation time, add and record the resolved versions:

- **Flutter:** official `unifiedpush` connector. Current researched release:
  `6.2.0`. Use `register`; current source deprecates the older `registerApp`
  spelling still present in some examples.
- **Rust:** `web-push` or an equivalent maintained Web Push library. Current
  researched release: `0.11.0`.

Acceptance requirements for the Rust library:

- RFC 8291 content encoding `aes128gcm`
- VAPID support
- async operation without blocking the relay event loop
- reproducible Windows release build, using vendored OpenSSL if required

Do not implement Web Push encryption or VAPID manually.

### Registration flow

1. The authenticated app requests the relay's VAPID public key over the relay
   control channel and caches it for future starts.
2. The app initializes UnifiedPush and selects the current/default distributor
   or shows a distributor picker.
3. The app calls `register` with a stable installation/instance ID at every
   startup, as required by the connector, to repair inconsistent distributor
   state.
4. `onNewEndpoint` supplies the endpoint and `PublicKeySet`.
5. The app sends this registration to the relay:
   - device and registration/instance IDs
   - endpoint URL
   - `p256dh`
   - `auth` secret
   - `temporary`, so a fallback endpoint expected to rotate can be handled
   - desired peer set
   - per-room completion-notification opt-ins
6. Upload registration material only over an authenticated,
   confidentiality-protected path: `wss`, loopback, or an explicitly recognized
   protected VPN transport. Otherwise keep local Balanced available but block
   push registration with a clear transport-status message.
7. Replace the previous endpoint/key registration atomically. If the app is
   offline when an endpoint arrives, persist a pending update locally and send
   it after reconnect.
8. The relay stores the registration as **pending** and sends a unique,
   short-lived validation token through the new push channel.
9. The app receives the validation push and returns the token over its
   authenticated WebSocket.
10. Only then does the relay mark the registration **validated**.

An endpoint or key change requires revalidation. A peer/filter-only update of
an already validated endpoint does not. An `onUnregistered` callback removes
the corresponding relay registration rather than merely changing local UI
state.

Registration and endpoint material is sensitive:

- do not log endpoint URLs, auth secrets, p256dh values, or VAPID private keys
- store pending app-side updates using the existing secure-storage approach
- remove registrations on explicit unregister, pairing removal, or revocation

### Relay control messages

Add version-tolerant control frames for:

- `push_config_request` → `push_config` with the VAPID public key and feature
  status
- `push_register`
- `push_validate`
- `push_unregister`
- success/error responses carrying the registration ID and a stable error code

Older clients never send these frames and retain their current behavior.

### Registration persistence

Add `relay/migrations/002_push_registrations.sql` and apply it through the
existing SQLite initialization path.

Suggested fields:

- registration ID and owning authenticated app pubkey
- endpoint, p256dh, auth
- desired peers and completion-room filters
- pending/validated state and timestamps
- last successful push and last terminal error

Store the relay-generated VAPID keypair separately in a protected, non-git
file under the relay data directory. Keep it stable across relay restarts and
include it in the deployment backup procedure. A replacement key may require
new distributor registrations.

### Push payload

Use a small versioned JSON payload:

```json
{
  "v": 1,
  "event": "run_started",
  "event_id": "opaque-unique-id",
  "peer": "standard-base64-epk",
  "room": "room-id",
  "occurred_at": 1790000000000
}
```

Event types:

- `push_validate`
- `run_started`: internal wake and FGS activation
- `run_finished`: internal transition to grace, including runs without a
  completion marker
- `run_done`: completion notification when that room opted in
- `waiting_started`: notification plus a 5-minute wake/grace window
- `waiting_cleared`: cancel the matching waiting notification

The payload contains no session title, prompt content, cwd, model output, or
arbitrary notification text. The app resolves titles from its local cache.
Android UnifiedPush permits at most 4096 encrypted POST bytes, which means at
most **3993 cleartext bytes**; the versioned wake payload must stay far below
that ceiling.

The app must drop messages when the connector reports unsuccessful decryption
or when the payload fails schema, size, peer, room, or event validation.

### Relay event production

Generate push events from actual room-meta transitions, not repeated patches:

- `working: false → true`: `run_started`
- `working: true → false`: `run_finished`
- unique `run_done` marker: `run_done`, even if stored state did not change
- `waiting_for_input: false → true`: `waiting_started`
- `waiting_for_input: true → false`: `waiting_cleared`

**Critical integration point:** enqueue push events before the current
`update_room_meta` early return for an empty `room_subs` set. A sleeping app
has no live WebSocket subscriber, and that is exactly when push is required.

Do not hold the registry or room mutex while performing SQLite, DNS, or HTTP
work. Hand a small event record to a bounded async push worker.

Revalidate desired peers against current pairing/mesh authorization before
sending. Persisted push subscriptions must not become a revocation bypass.

### Delivery behavior

- Push is best-effort wake, never the source of truth.
- Deduplicate repeated transitions by registration and event ID.
- Use bounded queues and a small retry policy with jitter for transient
  network errors and 5xx responses.
- Do not retry indefinitely.
- Mark 404/410 endpoint failures stale and require a new registration.
- Surface send/validation/queue metrics without logging secrets.
- Reconnect plus full sync repairs missed or duplicated push events.
- Let the connector send distributor `MESSAGE_ACK` when a message ID exists.
  This ACK covers distributor-to-connector reception only; it is not an
  end-to-end acknowledgment to the relay and does not prove Dart processing
  or reconnection.

### SSRF protection

Follow the UnifiedPush application-server guidance:

- allow HTTPS endpoints with global addresses by default
- resolve and validate the destination on every send
- reject private, loopback, link-local, and other non-global destinations by
  default
- do not follow redirects to an unvalidated destination
- add an explicit endpoint domain/IP allowlist for self-hosted private push
  servers

A private ntfy or other push server on LAN/Tailscale must be explicitly
allowlisted. Document that the push server must remain reachable from both the
relay and the distributor when the phone is sleeping.

## App push handling

### Entrypoint

Change the app entrypoint to accept `List<String> args` and follow the official
connector contract:

- initialize the UnifiedPush feature in both normal and background launches
- when `args.contains('--unifiedpush-bg')`, run only the required core
  bootstrap and **do not call `runApp`**
- otherwise run the normal app bootstrap and UI

Factor shared core initialization so background launch does not construct
unnecessary UI services. Background startup must be idempotent and must not
race duplicate notification/registration work with the foreground engine.

### New push service

Add a focused `UnifiedPushService` responsible for:

- connector initialization and every-start registration
- distributor selection and status
- VAPID public-key caching
- endpoint/key persistence and relay registration queue
- validation-token round trip
- unregister and revocation cleanup
- `onMessage`, `onUnregistered`, `onRegistrationFailed`, and temporary
  distributor unavailability
- safe payload parsing and deduplication

The service reports distributor/registration state to Settings without
exposing endpoint or key material.

### Wake behavior

For an accepted `run_started` while sleeping:

1. Start the foreground service immediately inside the distributor's
   foreground-importance window. Use a thin native hook if needed so this does
   not depend on Flutter engine startup.
2. Wake the connection asynchronously with reset backoff.
3. Reconcile rooms and actual `working` state.
4. Keep the active state until the run finishes and the 5-minute grace ends.

The distributor's 5-second foreground-importance window is not a general
background execution budget or Doze exemption. Do not assume Flutter engine
startup plus networking must fit inside it. Start the FGS as early as possible,
then reconnect and resync asynchronously.

The FGS ongoing notification is the visible indication of the active
connection. A separate run-started alert is unnecessary.

For `waiting_started`:

- show the existing waiting notification
- wake for the 5-minute grace window when Balanced is enabled
- reuse the existing session payload for tap routing

For `run_done`:

- honor the existing per-session completion opt-in
- show the existing completion notification
- if the app is already active, start the 5-minute grace
- if fully sleeping, do not keep a new socket alive solely to display a
  completion alert

For `waiting_cleared`, cancel the matching notification without opening a
socket.

If Android or the distributor does not permit an FGS start, degrade to a
notification and foreground reconnect on tap. Do not claim a guarantee that
the platform does not provide.

### Notification deduplication

A live WebSocket event and a UnifiedPush event can both arrive.

- `run_done`: deduplicate using peer, room, and `ended_at`.
- Waiting: use the existing stable per-room notification ID so a repeated
  alert replaces rather than stacks.
- `waiting_cleared`: cancel by the same stable ID.
- Run-started wake: one coordinator owns the FGS, so repeated wake requests
  are idempotent.

Preserve the current behavior that waiting notifications are not controlled by
the completion-notification opt-in.

### Settings and lifecycle

Extend Settings with:

- **Balanced / Active sessions** in the keep-alive mode dropdown
- a concise explanation of active/grace/sleep behavior
- UnifiedPush distributor selection and registration status
- validation, unavailable, and stale-registration recovery actions
- an honest status when push is configured but the private endpoint is not
  allowlisted or the distributor is unreachable

Switching away from Balanced unregisters push wake for this installation and
restores the selected legacy mode without changing its semantics.

## Expected structure

### `app/`

- `lib/main.dart`
  - args-aware normal/background entrypoint
  - shared core versus UI bootstrap
  - balanced controller and push wiring
- `lib/data/preferences/preferences.dart`
  - `KeepAliveMode.balanced`
  - migration preserving existing stored values and default
- `lib/data/transport/connection_manager.dart`
  - `StatusSleeping`
  - suspend/resume primitives
  - aggregated live working-room view
  - sleeping guards in watchdog, network recovery, and stale callbacks
- `lib/data/transport/keep_alive_controller.dart`
  - Balanced-aware FGS decisions while remaining the single FGS owner
  - timeout/exhaustion state handling
- `lib/data/transport/balanced_connection_controller.dart` **(new)**
  - active/grace/sleep state machine
  - injected clock and 5-minute grace
  - lifecycle and accepted-wake coordination
- `lib/data/push/unified_push_service.dart` **(new)**
  - connector, registration, validation, queue, wake callbacks
- `lib/data/push/push_payload.dart` **(new)**
  - strict payload models and validation
- `lib/data/push/push_registration_store.dart` **(new)**
  - secure pending registration and cached VAPID state
- `lib/data/notifications/`
  - reuse presenters/payloads; add live-versus-push dedupe
- `lib/ui/settings/`
  - Balanced mode and UnifiedPush status/setup
- `lib/config/dependencies.dart`
  - register core and UI-appropriate services
- `android/.../KeepAliveService.kt`
  - `onTimeout`, clean stop, Dart notification
- `android/.../MainActivity.kt`
  - guarded timeout and wake platform-channel methods
- `packages/piper_keep_alive/`
  - registers the keep-alive channel on normal and UnifiedPush background engines
- `pubspec.yaml` / lockfile
  - official UnifiedPush connector

### `relay/`

- `src/push/mod.rs` **(new)**
- `src/push/config.rs` **(new)** — VAPID and endpoint allowlist configuration
- `src/push/registration.rs` **(new)** — persistence and validation state
- `src/push/events.rs` **(new)** — transition events, filters, dedupe
- `src/push/web_push.rs` **(new)** — library-backed async sender
- `src/protocol.rs` — control frames and typed errors
- `src/handlers/` — authenticated registration/config commands
- `src/peers/registry.rs` — transition detection before empty-subscriber return
- `src/mesh/store.rs` — apply the new migration
- `src/lib.rs` — push state and bounded worker wiring
- `migrations/002_push_registrations.sql` **(new)**
- `tests/push_test.rs` **(new)**

### Documentation

- `plan/00-decisions.md`
  - record the explicit UnifiedPush decision for Balanced wake
  - FCM remains unadopted; the previous deferred-push decision changes only
    for this scoped feature
- `plan/125-battery-and-heat.md`
  - link to Balanced as the next lifecycle layer
- `plan/132-session-completion-notifications.md`
  - document push-assisted delivery and unchanged opt-in semantics
- `plan/134-waiting-for-input-state.md` / `plan/141-...`
  - document push wake and clear behavior
- relay/app setup documentation
  - distributor prerequisites, private endpoint allowlist, VAPID backup

## Steps and acceptance criteria

### 1. Record the design and dependency baseline

- Add this plan and the research reference.
- Record the user's UnifiedPush decision and 5-minute grace.
- Verify the selected Flutter/Rust libraries support current SDKs and
  `aes128gcm` before writing integration code.

**Accept:** dependency APIs and Windows/Android builds are proven with a
minimal compile probe. No hand-written Web Push cryptography.

### 2. Add the real sleeping primitive

- Implement `StatusSleeping`, `suspendForBalancedSleep`, and wake/resume.
- Preserve peer and caches.
- Close the channel and cancel every reconnect-producing path.
- Update Home/Chat status rendering for Sleeping.

**Accept:** unit tests prove no retry, ping, recheck, watchdog reconnect, or
network-change reconnect while sleeping. A stale channel close is harmless.
Foreground/manual wake reconnects with reset backoff and subscriptions.

### 3. Implement the Balanced coordinator and mode

- Add `KeepAliveMode.balanced` with preference migration.
- Implement active, 5-minute grace, and sleep transitions with an injected
  clock.
- Aggregate work across all subscribed rooms.
- Keep legacy modes unchanged.

**Accept:** tests cover background idle, one run, multiple rooms, run ending,
new run during grace, waiting wake, sleep, foreground resume, and mode changes.
Routine metadata does not extend grace.

### 4. Handle Android FGS timeout and start refusal

- Implement native `onTimeout` and the Dart suspension callback.
- Stop cleanly on quota exhaustion.
- Retain plan-142 early foreground startup.

**Accept:** a shortened Android timeout test produces no fatal exception and
no socket/retry leak. No automatic restart occurs before a valid foreground
interaction.

### 5. Add relay registration and VAPID persistence

- Add migration, registration store, stable VAPID keypair, config response,
  register/validate/unregister control flow.
- Add pending registration validation through a real push round trip.
- Implement SSRF rules and private allowlist.

**Accept:** relay tests cover persistence, ownership, revalidation, unregister,
revocation, invalid endpoints, DNS/IP restrictions, allowlisting, and no secret
logging. VAPID public key remains stable across restart.

### 6. Produce and send wake events

- Detect actual room-meta transitions.
- Enqueue before the empty-live-subscriber return.
- Filter by persisted peer and completion preferences.
- Send through the async Web Push worker with bounded retry and stale endpoint
  handling.

**Accept:** with zero live app WebSockets, registered devices still receive
`run_started`, `run_finished`, `run_done`, and waiting events. Repeated patches
do not duplicate events. A revoked peer receives nothing. Relay routing latency
is not blocked by push HTTP.

### 7. Integrate the Flutter connector and background entrypoint

- Initialize normal and `--unifiedpush-bg` launches.
- Implement distributor selection and every-start registration.
- Queue endpoint updates while offline.
- Parse/decrypt/validate messages and drive the balanced coordinator.

**Accept:** background launch never calls `runApp`. Cold and warm pushes are
handled. Duplicate engine initialization does not duplicate registration or
notifications. No distributor leaves local Balanced functional with an honest
status.

### 8. Integrate notifications and Settings

- Reuse existing notification payloads, stable IDs, opt-ins, and tap routing.
- Deduplicate live and push events.
- Add Balanced and UnifiedPush setup/status UI.

**Accept:** completion opt-in is honored; waiting always notifies; clear cancels
its alert; taps open the exact room. Switching modes unregisters wake and does
not change legacy behavior.

### 9. Automated verification

Run at minimum:

```text
cd app && flutter test
cd app && dart analyze lib test
cd app && flutter build apk --debug
cd relay && cargo fmt --check
cd relay && cargo clippy --all-targets -- -D warnings
cd relay && cargo test
```

Add focused tests for every state-machine, protocol, security, and error path
above. Resolve dependency conflicts only if they occur; do not preemptively add
global Tink or WebCrypto overrides from connector troubleshooting docs.

**Accept:** all new and existing tests pass, debug APK builds, and no generated
artifacts or secrets are committed.

### 10. On-device verification with two distributors

Follow the UnifiedPush recommendation to test at least two distributors, for
example ntfy plus another supported distributor.

Test both normal and background/cold-start cases:

1. Phone-started run → background → completion and waiting notifications.
2. PC-started run after deep idle → push wake → FGS → reconnect → live state.
3. Run finish → exactly 5-minute grace → FGS and socket stop.
4. Idle after grace → no Piper ping/retry/network activity.
5. Foreground → immediate reconnect and correct snapshot.
6. Waiting answered on PC → push clear removes the phone alert.
7. Live plus push delivery does not stack duplicate alerts.
8. Process death → cold push works; tap opens the exact session.
9. Wi-Fi ↔ cellular and LAN ↔ Tailscale transitions recover.
10. Doze via `adb shell dumpsys deviceidle force-idle`.
11. Shortened `dataSync` timeout via Android's documented device config.
12. Distributor unavailable → local Balanced still works and status is honest.
13. Private push server works only after explicit allowlisting.
14. Pairing removal/revocation stops push delivery.

**Accept:** at least two distributors pass the core wake cases. Any
 distributor-specific limitation is documented rather than hidden.

### 11. Battery and thermal measurement

Compare `always` and `balanced` on the same physical device:

- idle after grace
- one active streaming run
- LAN and Tailscale separately
- unplugged and screen off
- comparable signal and Tailscale exit-node configuration

Collect:

- FGS time, socket uptime, ping count/bytes, reconnect count
- actual run-active time and push count
- Batterystats/Battery Historian timelines
- Android battery usage for Piper and Tailscale separately
- CPU/crypto queue indicators if active streaming remains hot

**Accept:** Balanced shows no Piper FGS or relay traffic in deep idle and lower
Piper-owned idle activity than Always. Do not claim a universal percentage or
battery life without the measured evidence.

### 12. Deployment checklist

For the implementation rollout:

- build and install the debug APK over the existing debug channel
- rebuild `relay/target/release/relay.exe`
- coordinate the **Piper Relay** scheduled task and `piper-watchdog.ps1`
- restart the release relay and verify local and Tailscale `/health`
- verify client reconnection and persisted VAPID/registration state
- back up the mesh DB and VAPID key material before migration
- no Pi-session restart is expected because `pi-extension` is unchanged

**Accept:** release relay runs the new binary, push registrations survive a
second relay restart, and the app recovers without reinstalling or re-pairing.

## Definition of done

- Balanced keeps known active runs connected and sleeps after 5 idle minutes.
- Sleeping stops both the FGS and all connection/retry activity.
- UnifiedPush wakes for new PC runs without requiring an app restart.
- Completion and waiting notifications preserve existing opt-in and routing
  semantics.
- Push is best-effort; reconnect and sync always restore correctness.
- Android timeout, background-start refusal, revocation, stale endpoints, and
  unavailable distributors fail safely.
- Two distributors pass on-device core tests.
- App and relay test/build suites pass.
- Idle battery activity is measurably lower than Always on the target device.
- Documentation and deployment checklists are updated.

## Implementation status — 2026-10-29

Automated implementation is complete on `feat/balanced-active-session`.

- **Resolved app dependencies**: official `unifiedpush_android` 3.5.0 and
  `unifiedpush_platform_interface` 4.0.0, the Android half of the researched
  connector 6.2.0. Direct Android dependencies avoid the unrelated Linux
  WebCrypto/NASM build. Gradle substitutes duplicate Java Tink with
  `tink-android` 1.17.0 after the real connector conflict was reproduced.
- **Resolved relay dependencies**: `web-push` 0.11.0 without its default
  isahc/curl client, `aes128gcm` and VAPID from the library, reqwest/rustls for
  HTTP, and vendored OpenSSL for reproducible Windows crypto builds.
- **Verified**: 963 Flutter tests, 169 relay tests, strict clippy and rustfmt,
  debug APK, and Windows release relay. The release binary was built in
  `relay/target/plan153-release` so the running deployment stayed untouched.
- **Not executed here**: physical two-distributor tests, Android timeout/Doze
  instrumentation, comparative battery/thermal measurement, and deployment.
  These remain required before claiming the full on-device DoD.

## Risks and mitigations

- **Distributor-specific wake differences:** test two distributors and retain
  notification-plus-tap fallback.
- **Tailscale dependency:** a push server reachable only through the same
  sleeping VPN may not wake the phone. Document topology and test a reachable
  push path.
- **Battery shifted to distributor/Tailscale:** measure those processes too;
  UnifiedPush is not zero-cost.
- **Android FGS quota:** stop cleanly and reconnect on valid user interaction;
  never evade through service-type switching.
- **Push duplicates/loss:** dedupe notifications and treat sync as canonical.
- **Sensitive registration material:** no secret logs, protected storage,
  authenticated ownership, validation, and SSRF controls.
- **Background engine complexity:** no UI in `--unifiedpush-bg`; make core
  bootstrap idempotent and test cold/warm races.
- **Active-stream heat:** measure CPU separately and schedule native crypto
  work only if evidence shows it is needed.

## Next plans

- **154 candidate:** profile and reduce active Ed25519/stream CPU cost.
- **155 candidate:** optional per-room wake preferences beyond completion
  opt-ins.
- **Future:** evaluate `remoteMessaging` or `connectedDevice` only for semantic
  correctness and platform policy, never as a battery shortcut.
- **Future:** package and document a recommended self-hosted distributor/push
  topology if setup friction is the remaining adoption blocker.
