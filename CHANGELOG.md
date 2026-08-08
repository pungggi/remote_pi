# Changelog

All notable changes to Remote Pi are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For the canonical protocol specification, see [PROTOCOL.md](PROTOCOL.md).

---

## [Unreleased]

### Added

- **Adaptive keep-alive (battery & heat, plan 125)** — the phone ran hot
  and drained fast because five overlapping keep-alive mechanisms kept the
  cellular radio permanently awake. The relay heartbeat dropped 25 s → 60 s
  (`REMOTEPI_HEARTBEAT_SECS`, floor 30), the foreground service now runs
  only while the app is backgrounded, and "Keep connected in background"
  became a three-way toggle — Always / When charging (default) / Off — with
  a native charging probe + 60 s poll. Roughly halves inbound radio wakeups
  with no change to message delivery.
- **Steer vs Follow-up choice while working (plan 127)** — while the agent
  is working, a segmented **[Steer | Follow-up]** toggle above the composer
  lets you queue a message as the **next** turn (clock icon, "queued · next
  turn") instead of injecting into the running one (route icon; steer stays
  the default). Follow-ups drain in FIFO order when the current turn ends,
  attributed to their own bubble, and render consistently across paired
  devices. Image attachments on follow-ups are deferred to a later slice.

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
