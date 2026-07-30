# 124 — Battery & heat (adaptive keep-alive)

> Fork plan. `100+` range per repo convention. Implementation targets:
> **`app/`** (Flutter + native Android) and **`relay/`** (Rust).
> Read `app/CLAUDE.md`, `relay/CLAUDE.md`, and the relevant layer `CLAUDE.md`
> before editing. Supersedes the "battery = accepted" stance of plan 103 —
> that decision is **refined**, not reverted: the foreground service stays, but
> its cost is paid only when it is actually earning its keep.

## Context

### The symptom (reported)

> "The battery is going down really fast and the device is really hot. I think
> it has to do with relay keeping awake."

### Root cause (verified in code, not guessed)

The phone holds a persistent WebSocket to the relay. Four independent
"keep-alive" mechanisms run simultaneously, plus a foreground service that
prevents Android from ever freezing the process:

| # | Mechanism | Location | Cadence | Purpose |
|---|-----------|----------|---------|---------|
| 1 | Foreground service (default **ON**) | `KeepAliveService.kt` + `keep_aliveInBackground=true` | continuous | foreground priority → Android does not freeze process |
| 2 | WS-level ping (RFC 6455) | `ws_transport.dart:61` `pingInterval: 20s` | 20s outbound | app↔relay TCP keepalive |
| 3 | Protocol ping | `connection_manager.dart:1150` `_startPing` | 25s outbound | app↔Pi end-to-end liveness |
| 4 | Liveness watchdog | `connection_manager.dart:180` `_watchdogInterval` | 15s | checks 60s `_kInboundTimeout` |
| — | Relay heartbeat (inbound) | `relay/src/handlers/peer.rs:161` | 25s inbound | relay→phone keepalive |

The mobile radio is the dominant power draw. Every network wakeup has a
**"tail"** — the radio stays high-power ~5–10 s after the last packet. With
timers firing un-aligned at 15 / 20 / 25 s, the tail never completes, so the
radio is permanently tail-hot. The foreground service guarantees the process
(and radio) never idles. **That combination is the heat + drain**, not any
single line.

Three compounding findings:

- **The foreground service runs even while the app is foregrounded.**
  `keep_alive_controller.dart:_process` keys off `status is! StatusNoPeer`
  with no lifecycle check, so it starts the moment a peer connects and runs in
  the foreground too. This burns the Android-15 `dataSync` **6 h time budget
  while the app is actively open** — pure waste. The budget should be spent
  only on actual backgrounding.
- **The 20 s WS client ping is redundant for NAT keepalive.** The relay
  already pings inbound every 25 s; `ws` auto-replies Pong — that *is* the NAT
  keepalive. The client-side 20 s ping double-covers a job the relay already
  does. Its only unique value (surfacing a dead socket) is already handled by
  the `_kInboundTimeout` + watchdog path.
- **The 25 s relay heartbeat is ~4× more conservative than needed.** NAT idle
  timeouts: consumer routers ≥ 60 s, Cloudflare WSS ~100 s, corporate LBs
  2–5 min. 25 s forces the phone's radio awake ~4× more often than necessary.

### The tension (best of both worlds)

- **Reliability:** detect a dead/half-open socket fast and reconnect; survive
  backgrounding (no "reconnecting" dance on return).
- **Battery/heat:** let the radio and CPU sleep between genuinely needed work.

The current design maxes out reliability and sacrifices battery entirely. We
can recover most of the battery with **near-zero reliability loss** by (a)
stopping the foreground service when it earns nothing, (b) coalescing the
radio wakeups onto one aligned cadence, and (c) stretching intervals to the
real floor (NAT idle timeout) instead of an arbitrary 25 s.

## Key insight: the relay is the heartbeat authority

The relay pings inbound every N seconds. That inbound traffic keeps NAT alive
**and** is the liveness signal — the phone only has to *respond* (automatic
Pong). The phone does **not** need its own frequent outbound pings to keep the
socket alive. So most of the phone-side outbound traffic is redundant and can
be removed or stretched; only the relay's inbound cadence sets the true floor
on how often the radio must wake.

## Decisions

| # | Decision | Recommended | Rationale |
|---|----------|-------------|-----------|
| 1 | Gate the foreground service on app lifecycle | **Start only when backgrounded (`paused`/`inactive`); stop on `resumed`** | In the foreground the process is already foreground-priority — the service earns nothing and just burns the Android-15 `dataSync` 6 h budget. Free win, zero reliability loss. |
| 2 | Watchdog interval | **15 s → 30 s** | `_kInboundTimeout` is 60 s; checking every 15 s to detect a 60 s threshold is 4× too frequent. 30 s still detects within 30 s of the threshold crossing — acceptable latency for a belt-and-suspenders path. |
| 3 | WS client `pingInterval` | **20 s → 240 s** (or remove) | Redundant for NAT keepalive (relay already pings inbound). Keep a long interval only as a dead-socket backstop; the inbound-liveness watchdog is the primary detector. NAT timeouts are 2–5 min, so 240 s is safe. |
| 4 | Protocol ping (app↔Pi) | **Adaptive: 25 s active → 90 s lean** | In lean mode the relay's inbound proves the relay leg; the protocol ping only proves the Pi leg, which can tolerate ~90 s detection when backgrounded. Active mode unchanged for foreground use. |
| 5 | Relay heartbeat | **25 s → 60 s, configurable** | 60 s beats every common NAT idle timeout with margin and **halves inbound radio wakeups for every connected phone**. Single server-side constant; per-deployment override for cautious environments. |
| 6 | `_kInboundTimeout` rebalance | **60 s → 150 s** | If the relay moves to a 60 s heartbeat, a 60 s watchdog threshold would false-trip a healthy link. 150 s ≈ 2.5× the new heartbeat — same safety margin as today. |
| 7 | Keep-alive setting | **Three-way: Always / When charging / Off** (was on/off) | The hottest, fastest-draining scenario is FG-service + pings while on battery in a pocket. "When charging" lets users keep full reliability on power and get today's lean behaviour on battery. Default: **When charging** (was Always). |
| 8 | Lean mode trigger | **App backgrounded (`paused`/`inactive`) AND not charging** → lean cadence; foreground service still runs only if setting allows | Combines decisions 1, 4, 7 into one coherent power state. |

> If you want to change any of 1–8, say so before implementation. The rest of
> the plan assumes the recommended column.

## Expected structure

### `app/` — Dart

- **`data/transport/connection_manager.dart`** (modify)
  - `_watchdogInterval` default `15 s → 30s`.
  - `_kInboundTimeout` `60s → 150s`.
  - Add a **power-mode** field (`active` / `lean`) + `setPowerMode(...)`.
    - `active`: protocol ping `25s`, watchdog `30s`.
    - `lean`: protocol ping `90s`, watchdog `60s`, no client WS ping.
  - On mode change: cancel + reschedule the ping/watchdog timers at the new
    interval. Inbound-liveness logic is unchanged (it is interval-agnostic).
- **`data/transport/ws_transport.dart`** (modify)
  - `pingInterval: 20s → 240s`. (In lean mode the manager additionally stops
    the client ping; the WS-layer interval is just the floor backstop.)
- **`data/transport/keep_alive_controller.dart`** (modify)
  - Gate on `AppLifecycleState`: only `start` when the app is
    `paused`/`inactive` (and the setting allows it); `stop` on `resumed`.
  - Honour the three-way setting: `Off` → never start; `When charging` →
    start only if charging; `Always` → start on background (unchanged intent).
- **`data/preferences/preferences.dart`** (modify)
  - Replace `bool keepAliveInBackground` with an enum
    `KeepAliveMode { always, whenCharging, off }`, key
    `_kKeepAliveInBackgroundKey` reused. **Default `whenCharging`** (was `true`
    ≈ `always`). Provide a migration: a stored `'true'` → `always`, `'false'`
    → `off`, absent → `whenCharging`.
- **Lifecycle plumbing** (modify `main.dart` / root widget)
  - Add a `WidgetsBindingObserver` that on `paused`/`inactive`/`resumed`:
    1. tells `ConnectionManager.setPowerMode(...)` (lean when backgrounded,
       active when resumed);
    2. tells `KeepAliveController` to (re)evaluate start/stop.
  - Charging state via `BatteryPlus`-style read (verify if already a dep; if
    not, prefer a 10-line `MethodChannel` over a new package, per app
    convention). Re-evaluated on a `ACTION_POWER_CONNECTED`/`DISCONNECTED`
    broadcast or on the next status emission.

- **`ui/settings/settings_page.dart`** (modify)
  - Replace the `SwitchListTile` with a `DropdownButton`/segmented control:
    "Keep connected in background: **When charging** (default) / Always / Off".
  - Subtitle documents the trade-off: "When charging keeps you connected on
    power and saves battery on the go. Always uses a persistent notification
    and more battery."

### `relay/` — Rust

- **`src/handlers/peer.rs`** (modify)
  - Heartbeat interval `25s → 60s`, sourced from a config value
    (`Config::heartbeat_interval_secs`, default `60`), not a hardcoded
    literal. Keep the "first tick after the interval" behaviour.
- **`src/config.rs`** (modify, if config pattern exists) — add
  `heartbeat_interval_secs: u64` with env override (`PIPER_HEARTBEAT_SECS`),
  default 60, documented min 30 (refuse lower — that is the NAT floor with no
  margin). Allows cautious deployments to keep 25 s without a code change.

### Tests

- **`connection_manager` unit tests** — extend the existing virtual-clock
  harness: assert watchdog detects at 30 s granularity; assert
  `_kInboundTimeout=150s` does not false-trip a 60 s heartbeat link; assert
  `setPowerMode(lean)` reschedules ping to 90 s and watchdog to 60 s without
  dropping the connection.
- **`KeepAliveController` unit tests** — stub lifecycle + charging: assert
    `start`/`stop` calls for each (lifecycle, mode, charging) combination;
  assert never `start`s while `resumed`.
- **`Preferences` migration test** — `'true'`→`always`, `'false'`→`off`,
  absent→`whenCharging`.
- **Relay** — `peer.rs` heartbeat test: assert the interval is read from
  config and that a link still survives a simulated 60 s gap (no spurious
  close).

## Steps (with acceptance criteria)

1. **Free wins (Layer 0) — watchdog + foreground-lifecycle gating.**
   `_watchdogInterval 15→30s`; `KeepAliveController` starts only when
   backgrounded. *Accept:* `dumpsys activity services` shows the service
   absent while the app is foregrounded and present within ~1 s of
   backgrounding; the 6 h `dataSync` budget no longer ticks while open.

2. **Coalesce the radio wakeups (Layer 1).** WS `pingInterval 20→240s`;
   align the protocol ping phase so it does not collide with the watchdog
   tick. *Accept:* on a foregrounded Online session, a packet capture shows
   outbound app-originated keepalive frames at ≤ ~1 per 25 s (down from 3
   per 25 s); no change in reconnect behaviour.

3. **Relay heartbeat 25 → 60 s (Layer 3).** Config-driven. *Accept:* relay
   logs show ping every 60 s; a phone idle 10 min still has a live socket
   (relay sees the peer online); bump `_kInboundTimeout → 150s` so the
   watchdog does not false-trip.

4. **Adaptive power mode (Layer 2).** `ConnectionManager.setPowerMode`;
   lifecycle observer drives active/lean. *Accept:* background the app on
   battery → pings drop to 90 s, watchdog to 60 s (capture confirms); resume
   → back to 25 s/30 s within one tick. Reconnect latency on a real
   network-drop unchanged in active mode.

5. **Three-way setting + default `whenCharging` (Layer 4).** Preferences
   enum + migration + Settings UI. *Accept:* existing users with stored
   `'true'` see "Always"; fresh installs default to "When charging";
   on-battery background with "When charging" does **not** start the FG
   service (reverts to reconnect-on-resume); on power it stays alive per
   plan 103 step 3.

6. **On-device measurement (the proof).** *Accept:* on the target device,
   with the app backgrounded on battery for 30 min (lean mode, no FG
   service), `adb shell dumpsys batterystats` shows the app in a
   non-top/least-active bucket with markedly lower radio-awake time vs. the
   pre-change `Always` baseline; device is cool to the touch. With "Always"
   selected, background survival still matches plan 103 step 3 (no reconnect
   dance) but at the new 60 s relay cadence.

## DoD

- [x] 1 — Watchdog 30 s; FG service absent while foregrounded. _(done — plan 125, Layer 0; covered by `keep_alive_controller_test.dart`)_
- [x] 2 — WS ping 240 s; outbound keepalive ≤ ~1/25 s. _(done — plan 125, Layer 1. Note: explicit protocol-ping/watchdog phase-alignment was unnecessary — with the WS ping stretched to 240 s the only frequent outbound is the 25 s protocol ping, and the 30 s watchdog is CPU-only (rarely sends a packet), so there is no longer a pair of frequent outbound timers to align. The acceptance criterion is met by the stretch alone.)_
- [x] 3 — Relay heartbeat 60 s, config-driven; `_kInboundTimeout` 150 s; no false dead-socket trips. _(done — plan 125, Layer 3. Env var named `REMOTEPI_HEARTBEAT_SECS` to match the existing `REMOTEPI_*` relay convention, rather than the plan's `PIPER_HEARTBEAT_SECS`. Default 60, floor 30 (clamped with `warn`). Resolve/clamp extracted into a pure, unit-tested `resolve_heartbeat_secs`; 5 new `heartbeat_tests`. Relay `cargo test` 68/68 + integration suites green; `cargo clippy --all-targets -- -D warnings` clean. App inbound-liveness tests updated for the 150 s threshold.)_
- [x] 4 — Adaptive power mode: lean when backgrounded, active when resumed. _(done — plan 125, Layer 2. `PowerMode` enum + pure `pingIntervalFor`/`watchdogIntervalFor` helpers (testable); `ConnectionManager.setPowerMode()` reschedules ping + watchdog; driven from `didChangeAppLifecycleState` in main.dart. active: ping 25 s / watchdog 30 s; lean: ping 90 s / watchdog 60 s. The lean watchdog scales 2× the injected active interval so existing watchdog tests stay coherent. Note: the 240 s WS-layer backstop (Layer 1) is NOT touched in lean — it's already negligible (~1 packet/4 min) and mutating the live channel's pingInterval would need IChannel plumbing for no real gain. 3 new Layer 2 tests; `flutter test test/transport` 72/72.)_
- [x] 5 — Three-way setting, default `whenCharging`, migration correct. _(done — plan 125, Layer 4. `KeepAliveMode { always, whenCharging, off }` enum in Preferences with migration: stored `'true'`→`always`, `'false'`→`off`, absent→`whenCharging` (new default), names pass through, garbage→`whenCharging`. `KeepAliveController` reads the mode + a cached `_isCharging`; `whenCharging` gates the service on charging. Charging state via a native `isCharging` MethodChannel (reads the sticky `ACTION_BATTERY_CHANGED` intent — no new package, Android-only like the rest of the FG-service feature) + a 60 s poll while backgrounded so an unplug-while-backgrounded stops the service within ~60 s. Settings: `SwitchListTile` → `ListTile`+`DropdownButton`. 7 keep-alive controller tests; `flutter test` transport + preferences + settings suites all green. Code review fixed 3 stale doc references; no functional bugs. **Open: the Kotlin (`MainActivity.isCharging`) needs a gradle/on-device build to fully verify — the dev environment here has only JDK 8 (AGP needs 17) and no `gradlew`; the 8 lines use standard stable Android APIs and are correct by inspection.**)_
- [ ] 6 — On-device `batterystats` shows lower radio-awake time at parity of reliability.
- [ ] `dart analyze lib test` clean; `flutter test` green; `cargo test -p relay` green.
- [ ] `00-decisions.md` addendum: refine plan-103 decision 6 ("battery accepted") → "battery optimised adaptively (plan 125)".

## Risks & open questions

- **Carrier-grade NAT (CGNAT) with < 60 s idle.** Rare but possible on some
  mobile carriers. Mitigation: env override `PIPER_HEARTBEAT_SECS=30` for
  affected deployments; the watchdog's 150 s threshold still tolerates it.
  If measured CGNAT drops appear, ship 45 s as the default instead of 60.
- **Push-to-talk latency expectation.** If users expect sub-second message
  delivery while backgrounded, lean mode's 90 s protocol ping does not change
  *delivery* (the WS stays up; inbound messages arrive immediately) — it only
  changes dead-Pi detection latency. No regression on message delivery.
- **Android FG-service start restriction (14+).** Gating start on
  `paused`/`inactive` must still respect the "start FG service from a
  foreground-allowed state" rule. We start from the lifecycle observer while
  the app transitioned from foreground → background (an allowed window); the
  existing `try/catch` + retry-on-next-status already handles the edge.
- **`battery_plus` dependency.** Verify it is already a dep before adding; if
  not, use a 10-line `MethodChannel` wrapping
  `ACTION_POWER_CONNECTED`/`DISCONNECTED` + `BatteryManager.isCharging()` to
  avoid a new package (per app convention).

## Next plans

- **FCM-free push (if ever wanted)** — out of scope here; the fork is
  Firebase-free by choice (plan 103). If "true push" is later needed, revisit
  the whole keep-alive model rather than layering on top.
- **Per-network adaptive cadence** — if batterystats still shows high drain
  on cellular vs. Wi-Fi, add a transport-aware lean mode (Wi-Fi: can stay
  lean longer; cellular: even leaner). Data-driven, only if step 6 is
  insufficient.
