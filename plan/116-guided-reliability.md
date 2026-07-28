# Plan 116 — Guided connection reliability (one-tap battery + Tailscale deep-links)

## Context

Plan 114 validated the **app** half of network recovery: once the network is
usable again, Piper redials and comes back online on its own — no app restart.
The remaining blocker is **Tailscale-on-Android**, which does not auto-reroute
on a network transition (VLAN → cellular) and needs a manual kick. The user
confirmed: *"Piper came back by itself after I restarted Tailscale."*

The real fixes are **phone settings**:

1. **Tailscale as always-on VPN** (Settings → VPN → Tailscale → Always-on) —
   the system keeps Tailscale up across network changes.
2. **Battery-optimization exemption** for Tailscale (and Piper) — Android
   otherwise freezes/kills background VPNs, the most common cause of "offline
   after leaving the house."

The problem: these are **buried** in system settings, and a user will never
find them unprompted. This plan brings them within **one or two taps from
inside Piper** — the most we can do without modifying another app.

### What Piper can and cannot do (the hard Android boundary)

| Action | Piper can do it? | How |
|---|---|---|
| Exempt **itself** from battery optimization | ✅ | `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` → **one-tap system dialog** |
| Exempt **Tailscale** from battery optimization | ❌ | Can't manage another app's settings |
| Set Tailscale as **always-on VPN** | ❌ | System-only setting |
| **Deep-link** to Tailscale battery / VPN settings | ✅ | `ACTION_APPLICATION_DETAILS_SETTINGS` (pkg `com.tailscale.ipn`) + `ACTION_VPN_SETTINGS` |

So the plan is: **one-tap self-exemption** (belt-and-suspenders) + **guided
deep-links** to the Tailscale/VPN screens, surfaced **proactively** when the
connection is flaky.

### Design decisions

- **Piper's foreground service (plan 103) already exempts Piper from doze.**
  The self-exemption is therefore mostly redundant *while the foreground
  service runs* — but it (a) covers users who disabled that pref, and (b) lets
  the reliability screen show a concrete ✓. The **main value is the Tailscale
  deep-links**.
- **Proactive, not just passive.** A "Connection reliability" page in Settings
  is easy to ignore. So we ALSO surface a banner/card on Home after the relay
  has been **retrying for > 60 s** — "Having trouble staying connected? Improve
  reliability →" — right when the user is actually experiencing the pain.
- **Tailor to the detected transport.** If the resolved relay URL is in the
  Tailscale CGNAT range (`100.64.0.0/10`), the guidance is Tailscale-specific
  (battery + always-on VPN). Otherwise it shows generic background-reliability
  guidance. This avoids confusing non-Tailscale setups.
- **Android-only.** iOS has no equivalent battery-optimization footgun; the
  controller is a no-op there (the UI simply doesn't show the section).

## Expected structure

### AndroidManifest

```xml
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
```
(Sideloaded debug build — no Play-Store policy concern. Required for the
one-tap exemption dialog.)

### Platform channel — `ch.pungitore.piper/reliability` (Kotlin, MainActivity)

Methods (all best-effort; failures return null/false, never throw to Dart):

- `isBatteryOptimized()` → `!PowerManager.isIgnoringBatteryOptimizations(pkg)`
  (true = currently optimized = **needs** exemption).
- `requestBatteryExemption()` → launches
  `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` with `package:$pkg` → system
  dialog. Returns after the user resolves.
- `openTailscaleBatterySettings()` → `ACTION_APPLICATION_DETAILS_SETTINGS`
  with `package:com.tailscale.ipn` (lands on Tailscale app-info; user taps
  Battery → Unrestricted). No-op (returns false) if Tailscale isn't installed.
- `openVpnSettings()` → `ACTION_VPN_SETTINGS` (system VPN list; user toggles
  Tailscale → Always-on).

### Dart — `ReliabilityService` (`lib/data/device/reliability_service.dart`)

Thin method-channel wrapper (mirrors `KeepAliveController`'s platform-aware
shape):

- `Future<bool> isBatteryOptimized()` — false on non-Android.
- `Future<void> requestBatteryExemption()`.
- `Future<bool> openTailscaleBatterySettings()`.
- `Future<void> openVpnSettings()`.
- `Future<bool> get isTailscaleRelay` — resolves the relay URL via
  `resolveRelayUrl(preferences)` and checks the `100.64.0.0/10` range.
- Registered in `dependencies.dart` as an `addOther`/`addService`.

### UI

- **`ConnectionReliabilityPage`** (Settings entry "Connection reliability"):
  - Status row: "Background battery exemption" with a live ✓/✗ from
    `isBatteryOptimized()` and a one-tap **"Allow"** button →
    `requestBatteryExemption()` → re-check + flip to ✓.
  - **Tailscale section** (only when `isTailscaleRelay`): two tappable rows:
    - "Exempt Tailscale from battery optimization" →
      `openTailscaleBatterySettings()` (with a one-line "tap Battery →
      Unrestricted" hint, since we can't flip it for them).
    - "Keep Tailscale always-on (VPN)" → `openVpnSettings()` (hint: "enable
      Always-on for Tailscale").
  - A short explainer: *"If Piper goes offline when you switch networks, these
    keep Tailscale alive in the background."*
- **Proactive banner on Home** (in `home_page.dart`): when the relay has been
  in a non-Online status for **> 60 s** (tracked in `HomeViewModel` via a
  timer started on `_onStatus` → offline), show a dismissible card:
  *"Connection unreliable — Improve reliability"* → navigates to
  `ConnectionReliabilityPage`. Dismissed state remembered in `Preferences`
  (don't nag for the same outage once dismissed).

## Steps

1. **Manifest + platform channel.** Add the permission; implement the four
  methods in `MainActivity.kt` under the `reliability` channel. Verify each
  intent resolves (Tailscale-installed vs not) and degrades gracefully.
2. **`ReliabilityService` + DI.** Dart wrapper + `isTailscaleRelay` (CGNAT
  range check). Unit-test the CGNAT check + the non-Android no-op paths
  (inject a fake channel).
3. **`ConnectionReliabilityPage`.** Status checks + one-tap buttons. Widget-
  test the ✓/✗ flip after `requestBatteryExemption` and that the Tailscale
  section only renders when `isTailscaleRelay`.
4. **Proactive Home banner.** `HomeViewModel` tracks sustained-offline
  (> 60 s); `home_page.dart` renders the dismissible card → reliability page.
  Widget-test the 60 s threshold + dismiss persistence.
5. **Verify on device.** One-tap "Allow" grants the exemption (status flips to
  ✓); "Tailscale battery" deep-links to Tailscale app-info → Battery; "Always-
  on VPN" deep-links to the VPN list. Leave the house on cellular → confirm
  Piper recovers **without** a manual Tailscale restart (the whole point).

### Acceptance criteria

- [ ] One tap in the app opens the system "allow background" dialog; after
  Allow, the reliability screen shows ✓ granted.
- [ ] "Tailscale battery" opens Tailscale's app-info screen (→ Battery one tap
  away); no crash if Tailscale is uninstalled.
- [ ] "Always-on VPN" opens the system VPN settings.
- [ ] After > 60 s of relay-offline, Home shows the reliability card; tapping
  it opens the page; dismissing it stops the nag until the next outage.
- [ ] The Tailscale section only appears when the relay URL is in `100.64/10`.
- [ ] `dart analyze lib test` clean; new + existing tests pass.

## DoD

Connection-reliability fixes that live in system settings are reachable from
inside Piper in 1–2 taps, surfaced proactively when the connection is flaky.
Combined with plan 114, leaving the house should recover unaided once the user
has walked through the guided steps once. Committed + pushed; SESSION-STATUS
notes the new manifest permission + the reliability page.

## Next

- **116b** — auto-detect Tailscale connection state: query whether Tailscale
  is currently "connected" (via the Tailscale app's local socket / a
  health check) and surface "Tailscale isn't running" specifically, vs. the
  generic reliability card.
- **115** — dual relay addressing (LAN at home, bypassing Tailscale entirely)
  removes the need for *any* Tailscale reliability tuning at home; 116 stays
  valuable for mobile-only users.
- **Public relay path** (separate plan) — Cloudflare Tunnel / public endpoint
  so the phone reaches the relay with no Tailscale at all (the ultimate
  "works on any network" fix); makes 115 + 116's Tailscale guidance moot.
