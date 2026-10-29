# Piper app

Flutter client for paired Pi sessions. It provides session lists, chat, approvals, notifications, and relay recovery on Android and iOS.

## Development

```bash
flutter pub get
flutter test
dart analyze lib test
flutter build apk --debug
```

Read `CLAUDE.md` and the relevant layer instructions before editing.

## Balanced / Active sessions

Android Settings offers **Balanced / Active** in addition to the legacy keep-alive modes.

- **Active**: any live working room keeps the relay socket and foreground service active.
- **Grace**: after the last run or accepted wake, the connection stays up for five minutes.
- **Sleeping**: the socket, pings, rechecks, retries, and foreground service stop. Pairing, subscriptions, selected room, and cached state remain local.
- **Recovery**: foregrounding, manual reconnect, or an accepted wake reconnects and performs normal synchronization.

The default remains **When charging**. Routine metadata does not extend the grace period.

## UnifiedPush wake

Balanced works without a distributor, but new PC-started runs after deep idle then appear only when you open Piper. Install and select a UnifiedPush distributor to enable background wake.

Setup requirements:

- Select **Balanced / Active** in Android Settings.
- Install a UnifiedPush distributor, such as ntfy, and complete its own server setup.
- Open **Settings → UnifiedPush wake** and select the distributor.
- Keep the status at **Wake registration validated**. Use Retry after distributor, network, or stale-endpoint failures.

The relay is the Web Push application server. Registration uses an authenticated protected relay path: `wss`, loopback, or the recognized Tailscale VPN range. Cleartext LAN relay connections keep local Balanced available but do not upload endpoint or key material.

Push messages contain only event IDs, peer/room identifiers, timestamps, and validation data. They never contain prompts, agent output, session titles, working directories, or chat content. Reconnect and full sync are always authoritative.

## Android limits

The foreground service keeps the `dataSync` type. Android 15+ quota exhaustion stops the service and connection cleanly; a valid foreground interaction is required before another start.

A distributor wake is best effort and depends on Android, the distributor, and its push server. If a foreground-service start is refused, Piper uses a generic notification with session tap routing when possible.

Test at least two distributors for cold and warm wake, process death, Doze, network transitions, waiting clear, and duplicate live-plus-push delivery.
