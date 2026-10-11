# Plan 142 — KeepAliveService FGS-timeout crash (ForegroundServiceDidNotStartInTimeException)

## Context

Found during plan/141 on-device acceptance (2026-10-11, debug APK over
Tailscale adb): tapping the waiting-for-input banner brought the app up and
it **died mid-navigation** — the "tap routing broken" report was a process
death, not a routing bug.

Logcat evidence:

```
09:10:15 FATAL EXCEPTION: main
android.app.RemoteServiceException$ForegroundServiceDidNotStartInTimeException:
Context.startForegroundService() did not then call Service.startForeground():
ServiceRecord{… ch.pungitore.piper.debug/ch.pungitore.piper.KeepAliveService}
→ Force finishing activity ch.pungitore.piper.debug/.MainActivity → WIN DEATH
```

Mechanism:

1. While the test turn streamed, the phone's verify chain was deeply
   backlogged: `[probe] verifySum=62504ms`, avg ~1.3 s per signed frame
   (pure-Dart ed25519 in `Ed25519Worker` × dual-sig v1+v2 from plan/130,
   serialized verify-before-dispatch, `enqDelay p95 ≈ 7 s`).
2. On lock, `KeepAliveController.setBackgrounded(true)` →
   `Context.startForegroundService()` (MainActivity) → the system grants
   ~5 s for the service to call `startForeground()`.
3. The process was too sluggish (crypto backlog, possibly + Samsung
   Freecess racing the lock) — `onStartCommand` didn't reach
   `startForeground()` in time → system FATALs the process. The existing
   `try/catch` in `onStartCommand` **cannot** prevent this: once
   `startForegroundService()` was accepted, a miss is fatal regardless.

Manifest side is correct (`FOREGROUND_SERVICE_DATA_SYNC` permission +
`foregroundServiceType="dataSync"`).

## Fix (implemented 2026-10-11)

**`KeepAliveService.onCreate()` now calls `startForeground()` immediately**
(with a "Connected" placeholder), before intent delivery — the earliest
legal point. `onStartCommand` still updates the text right after. This
buys back the intent-delivery portion of the 5 s window; on a busy main
thread that is the difference between surviving a lock and being killed.

Deliberately NOT changed:

- **Trigger point stays `state != resumed`** (plan/125): starting the
  anchor on transient `inactive` (shade pull) is churn, but it also starts
  the anti-freeze anchor *before* the real lock arrives — the race this
  fix targets. Documented trade-off.
- **The `try/catch` in `onStartCommand` stays** — it covers
  foreground-allowed-state failures (sticky restarts); the timeout case is
  what onCreate now absorbs.

## Acceptance

- Rebuild debug APK, reinstall, re-run the plan/141 step-6 sequence under
  the same streaming load: lock while the app is busy → no FATAL in
  logcat; banner tap opens the session.
- `adb logcat | grep FATAL` clean across several lock/unlock cycles.

## Follow-up (separate plan candidate — NOT implemented here)

**The crypto backlog itself**: ~650 ms per pure-Dart ed25519 verify × 2
sigs per frame × serialized-before-dispatch makes every streamed turn a
multi-second UI hazard (probe: `verifySum=62 s`, `enqDelay p95 7 s` for 48
frames). Directions, in order of effort: verify v2 first and only fall
back to v1 (halves the cost), batch verifies, or move to a native
libsodium binding. That is the root cause; this plan only hardens the
service start against it.
