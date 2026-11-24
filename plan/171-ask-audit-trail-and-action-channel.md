# 171 — Ask fanout: audit trail + action-required notification channel

## Problem

Plan/170 shipped the pending-ask fanout, and the live test passed
(2026-11-24): an `ask_user` fired in a session whose chat was closed reached
the phone on Home (amber tile + notification), and the tap opened the sheet.

Two gaps surfaced in that same test.

- **The fanout is not auditable on the PC.** The device daemon logged
  nothing for an `ask_notice` receipt or for the `pending_ask` broadcast.
  When a badge did not show, "the notice never arrived" and "the phone
  dropped it" looked identical from the PC. The sender logged transport
  failures only.
- **"No banner" was the expected look.** Every app notification posted on
  the `session-completion` channel with `Importance.default`: a silent shade
  entry, never a heads-up popup. For "a session is blocked on you" that is
  too quiet. Missing it is exactly the 6-hour wedge class of plan/170.

## Decision (owner, 2026-11-24)

Both follow-ups, in one plan.

## Part A: audit trail

- `main.ts`: `_broadcastToActive` is now a thin wrapper over
  `_broadcastReporting`. It stays the single choke point for probe, ledger
  stamp, journal and fan-out (nothing else may stamp), and returns the
  stamped frame's `seq`/`epoch` plus the number of owner channels that took
  the frame.
- The daemon's `ask_notice` handler writes one line per outcome to its room
  log (`~/.pi/piper/ext-device.log`) through the existing `_relayLog`:
  - `pending_ask out open=… room=… flow=… seq=… epoch=… recipients=…`
  - `ask_notice refused open=… room=… flow=… reason="…"` (wrong room,
    missing fields)
- The reply carries the receipt: `seq` and `epoch` (when the frame was
  stamped) and `recipients`.
- The sender (`_fanoutAskNotice`) logs the outcome in the ASKING session's
  own room log:
  - `ask_notice sent open=… flow=… seq=… recipients=…`
  - `ask_notice refused open=… flow=… reason="…"`
  - `ask_notice failed open=… flow=… error="…"` (plus the existing warning)

A missing badge is now a two-file lookup. The asking session's
`ext-<room>.log` says whether the notice left; `ext-device.log` says whether
it was broadcast and under which ledger seq.

The kill-switch refusal (`allow_remote_session_control:false`) is audited
too (ai-review #120): the generic gate writes the same
`ask_notice refused … reason="allow_remote_session_control:false"` line
before replying, so an opt-out is never mistaken for a notice that never
arrived.

## Part B: action-required channel

- New optional capability `IActionRequiredNotifications` with
  `showActionRequired(...)`, implemented by `FlutterLocalNotifications`.
  This is the same pattern as `IControlLink` on channels.
- `postActionRequired(local, …)` is the single call site. It takes the
  heads-up path when the capability is present and falls back to plain
  `show` otherwise.
- New channel `action-required` ("Action required") with `Importance.high`
  and `Priority.high`.
- Consumers: `PendingAskNotifications` (plan/170) and
  `WaitingInputNotifications` (plan/134/141). Both mean "a session is
  blocked on you". Completion notifications (plan/132) stay informational
  on the old channel.

Why a capability interface and not a default method on `LocalNotifications`:
the test fakes use `implements`, which inherits no method bodies, so a
default method would have forced a change in every fake. The capability
keeps them untouched.

Why a NEW channel id: Android freezes a channel's importance at creation,
and the user may have turned `session-completion` down. Raising those
notifications in place is impossible.

## Implementation map

pi-extension:

- `protocol/types.ts`: `seq`/`epoch`/`recipients` on the `ask_notice`
  `rp_control_result`.
- `main.ts`: `_broadcastReporting`; audit lines in the `ask_notice` case
  and in `_fanoutAskNotice` (now exported for tests).
- `session_control.test.ts`: receipt matches the sent frame + room log
  line; refusal audited; sender logs sent / refused / failed.

app:

- `data/notifications/local_notifications.dart`: `NotificationUrgency`,
  `IActionRequiredNotifications`, `postActionRequired`,
  `actionRequiredChannelId`, `showActionRequired`, pure `detailsFor`.
- `pending_ask_notifications.dart`, `waiting_input_notifications.dart`:
  post via `postActionRequired`.
- Tests: `local_notifications_details_test.dart` (channel contract,
  fallback, heads-up path); the two service fakes implement the capability
  and assert it was used.

## Limitations (accepted)

- Heads-up delivery is the OS's decision: a user who lowers the new
  channel, enables Do Not Disturb, or runs an OEM with custom rules still
  gets a shade entry. The channel is at least visible and tunable under
  "Action required".
- No per-session opt-out for action-required notifications yet; plan/134's
  waiting-input banner had none either.

## Acceptance (DoD)

1. An `ask_notice` served by the daemon leaves a `pending_ask out … seq=N`
   line in `ext-device.log`, and the asking session's log has
   `ask_notice sent … seq=N`.
2. A refused notice leaves an `ask_notice refused … reason="…"` line in the
   receiving room's log.
3. A pending-ask or waiting-for-input notification appears as a heads-up
   banner with sound on Android (channel "Action required" in the system
   settings). Completion notifications are unchanged.
4. `detailsFor(actionRequired)` never returns the `session-completion`
   channel id.
5. Extension vitest green, `flutter analyze` 0 errors, new tests for the
   receipt, the audit lines (receiver and sender), the channel contract
   and the capability fallback.

## Deployment

- **PC**: rebuild and restart the device daemon
  (`node pi-extension/dist/index.js daemon stop device`, then
  `daemon start device`) for the daemon log lines. Sessions started before
  the rebuild keep logging failures only.
- **App**: needs a release. The new channel is created on the first
  action-required notification.
