# Changelog

All notable changes to Remote Pi are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For the canonical protocol specification, see [PROTOCOL.md](PROTOCOL.md).

---

## [Unreleased]

### Added

- **Completion notifications** — long-press a session and flip "Notify when
  finished": when that session's agent run ends while the app is
  backgrounded (and the background connection is alive), you get a system
  notification naming the session; tapping it opens that chat. Tasks started
  from the computer's terminal count too. No message content ever travels in
  the notification. Requires the relay + Pi extension shipped with this
  release (older relays silently drop the marker — everything else keeps
  working).

## [1.4.0] — 2026-08-24

### Added

- **Pause button in the chat navigation pill** — tap ❚❚ to freeze the view
  wherever it is while the agent keeps working: streamed replies, new
  messages and tool calls no longer move what you're reading. Tap ▶ (or
  jump-to-newest) to catch up and follow the live reply again like before.

## [1.3.6] — 2026-08-21

### Fixed

- **Everything missed while offline now loads automatically** — messages
  generated while the phone was away (any gap length) are backfilled: sync
  replies lost to a flaky connection are re-requested, history keeps paging
  older until it reaches what you already have, and every app resume triggers
  a catch-up sync.

## [1.3.5] — 2026-08-21

### Fixed

- **Reading older messages while a reply is streaming finally works** — the
  view used to snap back to the newest message every time the reply grew,
  making it impossible to scroll up during generation. The viewport now stays
  exactly where you left it (your scroll gesture is no longer interrupted),
  and follows the live reply again once you scroll back to the bottom.

## [1.3.4] — 2026-08-21

### Fixed

- **Responses no longer stay invisible until you re-enter the chat** — if the
  app connected while a reply was already being generated (chat opened
  mid-turn, phone reconnected after the screen turned off), the stream and
  its "done" signal were never delivered. The PC now replays the in-flight
  text the moment the app attaches and resumes streaming live from there.
- **"Jump to message" works again for far-away messages** — tapping a user
  message in the session navigator now scrolls there even when the target is
  beyond the lazily-built list window, hopping one screen at a time.

### Performance

- **Smoother streaming on long replies** — text deltas are coalesced into
  short frames on the PC side, cutting per-frame signature work on the phone
  by 3-6x with no visible change in granularity.

## [1.3.3] — 2026-08-21

### Fixed

- **Fresh pairings complete reliably again** — the phone's first-contact
  envelope was addressed to a key hash the PC rejected, making pairing
  time out for good measure.
- **No more freezes or battery drain while the agent replies** — Ed25519
  signature verification moved to a background isolate (previously it ran
  on the UI thread; a long reply could peg the CPU and stall the app).
- **Projects screen and quick actions no longer time out** — replies that
  carry no message id (project list, worktrees, layout changes) were being
  silently swallowed by replay dedup.

## [1.3.2] — 2026-08-16

### Fixed

- **Fresh installs no longer time out** — a failed first mesh-blob publish
  is now retried on every poll tick and app resume instead of never
  (the relay's mesh gate needs the blob to authorize presence/rooms).
- **UI freeze during agent replies fixed** — inbound frames are processed
  in parallel again; per-frame debug logging removed.

## [1.3.1] — 2026-08-14

### Security

- **Hardened message signatures (plan 130 follow-up)** — signatures now
  also bind the recipient Pi (a relay can no longer redirect a signed
  command to another of your machines) and carry a timestamp so captured
  messages can't be replayed. Older apps and Pis keep working during the
  upgrade; a relay attempting to strip or downgrade signatures is detected
  and the frames are rejected.
- **Replay protection survives reconnects** — duplicate message IDs are
  remembered across connection drops on both sides.
- **Subscription re-validation on the relay** — revoked mesh members stop
  receiving presence/room updates within ~2 minutes instead of keeping
  them indefinitely.
- **Symlink-proof remote working-directory policy** — remote terminal and
  session starts can no longer escape the configured project roots via
  symlinked paths.

## [1.3.0] — 2026-08-14

### Security

- **Signed messages (plan 130)** — every message between the app and the
  Pi is now cryptographically signed by the sender's device key. A
  compromised or malicious relay can no longer impersonate your paired
  Pi (or the app): after the first verified signed message, unsigned
  frames from that peer are rejected automatically. Transition-safe —
  pairs with an older Pi keep working until both sides upgrade.
- **Insecure-connection warning** — while connected over a plaintext
  `ws://` relay (the default home-LAN dial), a persistent banner on Home
  warns that traffic is readable on this network. Use an `https://` or
  overlay (Tailscale) relay to clear it.
- **Hardened relay** — message-size limits, an auth-handshake timeout,
  and mesh-membership gating for presence/room metadata (other relay
  clients can no longer see your PC's sessions without being paired into
  your mesh). Requires relay 0.3.x deployed alongside.

### Added

- **Steer vs Follow-up choice while working (plan 127)** — while the agent
  is working, a segmented **[Steer | Follow-up]** toggle above the composer
  lets you queue a message as the **next** turn (clock icon, "queued · next
  turn") instead of injecting into the running one (route icon; steer stays
  the default). Follow-ups drain in order when the current turn ends and
  render consistently across paired devices.

---

## [0.2.0] — 2026-07-30

### Added

- **PC mesh foundation** — the app is no longer tied to one PC. Pair
  multiple machines into a mesh of coding agents. The Owner-key syncs
  across your devices via platform credential stores (iCloud / Google),
  so reinstalling the app restores your peers automatically.
- **Cross-PC messaging** — send messages between coding agents on
  different PCs through the relay. Prefix addressing (`<pc>:<agent>`)
  routes envelopes across machines, with delivery ACKs so you know when
  a message arrived.
- **Daemon mode** — Pi can run as a background daemon so your mesh stays
  alive even when no terminal is open.
- **Multi-device chat** — pair multiple phones to the same Pi. Messages
  echo to every paired device so all views stay in sync.
- **Copy agent replies** — one tap on any assistant bubble copies the
  full reply to clipboard.
- **Jump to your messages** — ▲/▼ pill in the chat transcript jumps
  between your own questions instead of scrolling.
- **Pin projects to top** — tap the pin icon on any project to keep it
  at the top of the Projects list.
- **About & What's new** — Settings now shows the app version and an
  in-app changelog so you know what changed after an update.
- **Start session** — long-press an offline session to bring it back to
  life in its original working directory, with the full conversation
  history intact. Not a permanent pin — the session goes offline again
  after a PC restart.

### Changed

- Pi-extension upgraded to Pi SDK 0.83.
- Site messaging reframed: "mesh of coding agents," not "phone controls Pi."

### Fixed

- Chat transcript no longer duplicates or drops messages when paginating
  history.
- Pending message bubbles no longer get stuck after a network hiccup.
- Chat title no longer flashes the default on open.
- App no longer silently drops session history sync on cold start.
- Relay control frames deduplicated — fixes Android CPU spikes with
  multiple connected devices.
- Pairing no longer rejects a second phone pairing to the same Pi.

### Security

- Honest trust model: all user-facing copy now correctly describes TLS
  transport (not end-to-end encryption). The relay sees plaintext;
  self-hosting is the recommended path for sensitive deployments.

---

## [0.1.3] — 2026-05-22

### Added

- Privacy Policy and Terms of Service pages (`/privacy`, `/terms`).
- Site documentation layout improvements: sidebar + table of contents.
- Multi-platform Docker build for the relay (`linux/amd64`, `linux/arm64`).
- Relay published at `wss://relay-rp1.jacobmoura.work` (default community endpoint).
- Visual identity and launch icons for Android, iOS, and macOS.

### Changed

- Native display name "Remote Pi" applied across platforms.
- Pi-extension prepared for npm publishing.

### Fixed

- App: empty custom relay URL allowed in onboarding (previously rejected).

### Removed

- macOS desktop platform from the Flutter build (focus on mobile only).

[Unreleased]: https://github.com/jacobaraujo7/remote_pi/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/jacobaraujo7/remote_pi/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/jacobaraujo7/remote_pi/releases/tag/v0.1.3
