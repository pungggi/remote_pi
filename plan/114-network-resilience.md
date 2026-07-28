# Plan 114 — Network resilience (react to network change + recover fast)

## Context

Reported symptom: *"on the local VLAN, then I go outside (mobile), Piper stays
offline until I restart Tailscale **and** Piper."*

Diagnosis (verified in code this session):

- The app has **no network-change detection at all** — `connectivity_plus` is
  not even a dependency. So after VLAN → mobile, it sits on its backoff
  schedule (up to **30 s**) before the next attempt instead of reacting to "I
  just got a new network."
- It **does** retry forever (`_kBackoff = [1,2,5,10,30]`, clamped — never gives
  up), so the failure is *slow recovery*, not *giving up*.
- Half-open detection leans on the WS-layer ping interval, which is **slow** to
  fail on mobile. The app has an inbound-driven `_missedPings` counter (25 s
  Pi-liveness probe), but 3 misses only **marks the room offline locally** — it
  does **not** force-close the WS. There is no "no inbound frame for N seconds
  → this socket is dead, reconnect" watchdog (the pi-extension has one at 70 s;
  the app does not).
- `ChatViewModel.reconnect()` exists, but it is only surfaced for a graceful
  `bye` (`peerOfflineReason`), **not** for a network drop. And it lives only on
  the chat screen, not Home.

So: the phone can't reach the relay until Tailscale re-routes (partly outside
our control), and even when it does, the app is slow to notice and slow to
retry. This plan makes the **app** half of that recovery near-instant — the
moment the network is usable again, you're back in ~1 s instead of a full
restart.

This is the layer that fixes the **reported (mobile) problem**. Plan 115 (dual
addressing) removes the Tailscale dependency at home but does nothing for
mobile — the two are complementary.

### Design decisions

- **A + B + C together, not piecemeal.** A (react) needs a reconnect primitive;
  B (button) calls the same primitive; C (liveness) feeds the same reconnect.
  One primitive (`forceReconnect`), three triggers.
- **Reconnect = reset backoff + dial now.** A public `forceReconnect()` on
  `ConnectionManager` that cancels the pending `_retryTimer`, resets
  `_retryAttempt = 0`, tears down the current (possibly half-open) channel, and
  calls `_connect(peer)` immediately. This is the single chokepoint A/B/C call.
- **Liveness watchdog mirrors the pi-extension's.** Track `_lastInboundAt`
  (stamped on **every** inbound frame in `_watchChannel`); a watchdog force-
  closes when silent beyond a threshold **while status is Online** (so we never
  fire during the connecting window). Threshold ~60 s (≥ 2× the 25 s ping).

## Expected structure

### A — Network-change detection (`connectivity_plus`)

- Add `connectivity_plus` dep.
- New `NetworkMonitor` service (platform-aware, no-op stub on desktop tests):
  exposes a `Stream<List<ConnectivityResult>>`. Emits on any change
  (wifi↔cellular↔none).
- `main.dart` wires it: on a transition **to** a connectivity state (i.e. not
  `none`), call `ConnectionManager.forceReconnect()`. Debounced (coalesce a
  burst of changes within 1 s into one reconnect).

### B — Manual reconnect affordance

- **Surface the existing path for network drops**, not just `bye`. Today the
  reconnect banner shows only when `peerOfflineReason != null`. Extend: show a
  **"Reconnect"** action whenever `status is StatusRetrying || StatusOffline`
  (the actual network-drop states).
- **Home** gets a lightweight reconnect affordance when the whole connection is
  retrying (e.g. the status chip becomes tappable, or a small button in the
  empty/offline state) → `forceReconnect()`.
- **Chat** keeps its existing banner for `bye` and adds the same action for the
  retrying/offline states.
- All paths call `forceReconnect()` (no duplicated logic).

### C — App-side inbound-liveness watchdog (`connection_manager.dart`)

- Stamp `DateTime _lastInboundAt = now` inside `_watchChannel` on every inbound
  frame (alongside the existing `_missedPings = 0` reset).
- New `_livenessTimer` (e.g. every 15 s, or piggyback the existing 15 s
  `_watchdogTimer`): if `status is StatusOnline && now - _lastInboundAt >
  _kInboundTimeout` (60 s) → call `_onChannelLost(peer, channel)` (the existing
  force-close-and-reconnect path). This closes half-open sockets that the
  WS-layer ping interval hasn't noticed yet.
- `_kInboundTimeout = 60 s` is ≥ 2× the 25 s relay ping, so a healthy
  connection never trips it; only a truly silent (half-open) socket does.
- Reset `_lastInboundAt` on every successful connect so the window starts clean.

### The shared primitive — `ConnectionManager.forceReconnect()`

```text
forceReconnect():
  peer = _activePeer; if null return
  cancel _retryTimer
  _retryAttempt = 0
  await _teardownActive(emitNoPeer: false)   // drop half-open socket, keep peer
  _scheduleRetry(peer) with delay = 0        // → emits StatusConnecting, dials now
```

(Implementation detail to confirm in step: whether to go through `_scheduleRetry`
with a zero delay or directly `_connect`; either way the observable contract is
"backoff reset, dial now, status → Connecting".)

## Steps

1. **`forceReconnect()` primitive.** Add to `ConnectionManager`; cancel pending
   retry, reset attempt, teardown active channel (no `NoPeer` emit), reconnect
   now. Unit-test: retrying state → `forceReconnect` → next status is
   `Connecting` and `_retryAttempt` is 0; online-with-channel → current channel
   is closed and a new connect starts.
2. **C — liveness watchdog.** `_lastInboundAt` stamp in `_watchChannel`; 15 s
   watchdog; force-close at 60 s silence while Online. Unit-test: inbound
   resets the clock; 60 s of silence after Online → `_onChannelLost` fires
   (inject a controllable clock).
3. **A — `connectivity_plus` + `NetworkMonitor`.** Dep + service + debounce.
   Wire in `main.dart` to `forceReconnect()` on transition to a connected
   state. Unit-test the debounce/coalesce; integration-guard the platform
   channel so widget tests don't need a real device.
4. **B — reconnect affordance.** Home: tappable status chip / offline-state
   button. Chat: extend the banner to retrying/offline (not just `bye`). Both
   call `forceReconnect()`. Widget-test the affordance appears in the right
   states and invokes the VM.
5. **Verify on device.** The real test: connected at home → switch to cellular
   → confirm the app returns to Online **without** restarting the app (and
   faster than before). Toggle Wi-Fi off/on → confirm ~1 s recovery. Leave it
   half-open (airplane mode 90 s) → confirm the liveness watchdog force-closes
   and reconnects on its own.

### Acceptance criteria

- [ ] After a network change (VLAN → mobile, Wi-Fi toggle), the app reaches
  Online **without an app restart**, faster than the pre-fix 30 s backoff.
- [ ] A tappable **Reconnect** appears in both the retrying and offline states
  (Home + Chat) and reconnects on tap.
- [ ] A half-open socket (no inbound for 60 s while "Online") is force-closed
  and reconnected automatically.
- [ ] `forceReconnect` resets the backoff to attempt 0.
- [ ] `dart analyze lib test` clean; new + existing transport/viewmodel/widget
  tests pass.

## DoD

Network transitions and half-open sockets recover automatically and quickly,
with a one-tap manual fallback — no more "restart Tailscale + Piper." Committed
+ pushed; SESSION-STATUS notes the new dep + the `forceReconnect` primitive.

## Next

- **115** — dual relay addressing (LAN at home, Tailscale off-network): reuses
  this plan's `connectivity_plus` + `forceReconnect` for endpoint selection and
  cellular-skip.
- **114b** — foreground-service hook: have `KeepAliveController` also nudge
  `forceReconnect()` on Android network broadcasts (today the Dart isolate
  drives reconnect; a native broadcast can wake it faster while backgrounded).
- **114c** — reconnect UX polish: show "last retry N s ago / next in N s" and a
  spinner during the immediate post-network-change attempt.
