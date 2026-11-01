# Changelog

All notable changes to Remote Pi are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For the canonical protocol specification, see [PROTOCOL.md](PROTOCOL.md).

---

## [1.5.3] - 2026-11-01

### Changed

- **Plan-usage header, round two**: windows at 0% are hidden (space —
  the monthly MCP marker is 0% almost always), the bar likewise skips
  0% lanes, and the countdown reads `⏳ 2h 14m` instead of `resets
  2h 14m`.

## [1.5.2] - 2026-11-01

### Changed

- **Plan-usage header tweaks (review feedback)**: the usage line is
  centered in the group header, each window (`5h 3% · wk 4%`) now gets
  its own color by how full that window is, and the hairline bar follows
  the shortest window available (5h, else weekly, else monthly) rather
  than the busiest one.

## [1.5.1] - 2026-11-01

### Changed

- **PR #89 review — the group-header "resets 2h" countdown now ticks**
  every minute (a header-local timer, active only while a live countdown
  is rendered) instead of freezing until the next 10-min usage push.

### Added

- **Subscription usage on Home's model groups (plan/156)**: model-group
  headers now show the provider's plan quota — every window the provider
  reports (5h prompts, weekly tokens, monthly MCP credits on z.ai) — with
  a subtle pressure bar and reset countdown. It appears only while at
  least one session in the group is online, so stale offline caches never
  read as live quota. z.ai GLM Coding Plan is supported first; more
  providers can follow.

## [1.5.0] - 2026-10-30

### Added

- **Balanced Active Sessions + UnifiedPush wake (plan/153)** — the new opt-in
  keep-alive mode keeps active runs connected, then enters real idle sleep
  after five minutes. Sleeping stops the foreground service, socket, pings,
  rechecks, and retries while preserving pairing and cached rooms.
- **Validated Web Push registrations** — Android uses the official UnifiedPush
  connector and the relay stores VAPID/configuration plus validated endpoint
  registrations. New runs and waiting events can wake the app without
  Firebase; completion opt-ins, notification dedupe, and session tap routing
  are preserved.
- **Android `dataSync` timeout handling** — quota exhaustion and background
  start refusal stop cleanly without a socket/retry leak or restart loop.

- **Exact offline session resume (plan/152)** — Start session now opens a
  terminal in the original folder and runs `pi --session <id>` when the
  room registry has a stored Pi session ID. Session replacement refreshes
  the ID immediately. Older rooms open the same visible terminal with
  `pi --continue`, and the app/relay request shape is unchanged.

- **Home session slot: GitHub ref + activity stats (plan/149)** — the 40px
  letter avatar becomes a 44px rounded-square info slot with three mono
  lines. With a linked ref: `PR #70` / `#12` (PR slot wins the display,
  both slots kept), tap opens the URL. Without: turns / user-msgs / unread.
  Unknown values render `·`; a session with neither ref nor stats nor
  unread keeps the legacy initial avatar. New opaque `room_meta` keys
  `gh_ref` {pr, issue, source}, `gh_suggestion` (source `chat`, ephemeral,
  never persisted PC-side) and `stats` {turns, user_msgs}; relay passes
  them through with `git`-style absent-preserve / null-clear patch
  semantics, and the room keeper re-announces the registry's durable copy
  for offline tiles. **Ingest precedence manual > gh > chat**: manual via
  the new `set_session_ref_request`/`_result` pair (live room applies +
  pushes, any other room writes the plan/140 rooms registry directly —
  works offline, optional `cwd` creates the entry for pre-140 sessions);
  `gh pr view --json number,url,state` runs on the git-refresh cadence
  (missing binary/auth/repo changes nothing, errors nothing); the chat
  scan (user+assistant rows) only ever *suggests* from full GitHub URLs
  and `owner/repo#123` — a bare `#123` is rejected as ambiguous.
  Counters: turns on `agent_end`, user messages on `message_end`
  (role=user), pushed **only at turn boundaries**, seeded from the
  registry on reconnect (`max(registry, current)`). Unread is
  phone-local: a durable `read_markers` Hive box stores the last-read seq
  per `(epk, roomId)` (written on chat open, forward-only); unread = msgs
  box rows past the marker — never a stored counter (plan/111's 30-event
  sync would make phone-side totals systematically low). The plan/148
  cleanup dialog names the linked ref and warns when the PR's state is
  open/unknown. New public widgets: `_SessionSlot` (in `session_tile.dart`),
  `showLinkRefSheet` (in `link_ref_sheet.dart`).

### Performance

- **Streaming Markdown rendering** — upgraded `gpt_markdown` to 1.4.0 for
  incremental rendering, kept its theme stable across token updates, and
  adopted its built-in GFM link handling. Long responses now coalesce at
  50–100 ms instead of 16 ms while short replies remain responsive and final
  completion flushes immediately. This reduces CPU and allocation churn during
  long streams without removing live formatting.

### Fixed

- **Exact-resume terminal visibility** — Start session now opens a NEW visible
  Windows Terminal window (`-w new`, not a background MRU tab), so the resumed
  Pi process is visible on the PC as well as online in the app.

- **Home provider-error status**: failed LLM API turns now publish
  `room_meta.provider_error`, turning the live session slot/avatar red even
  when no chat is attached. A new turn or session clears the failure;
  reconnect and offline status colors retain their existing behavior.

- **PR #71 review fixes (plan/149 hardening)**:
  - **Relay**: a `gh_ref`/`gh_suggestion`/`stats` key explicitly cleared
    by a patch is now broadcast as an explicit `null` instead of being
    omitted — downstream treats absent as preserve, so a removed link or
    consumed suggestion never reached the phones before.
  - **Extension**: `gh pr view` refreshes a manual PR only when the
    repository identity (URL `owner/repo` prefix) matches — an unrelated
    cwd PR with the same number no longer overwrites a manually linked
    foreign-repo PR. Manual links and accepted suggestions now MERGE with
    the stored ref (linking a PR after an issue keeps both slots).
    Reconnects re-seed `gh_ref`/`stats` from the rooms registry before
    replaying the cached hello, so a ref applied through the device
    daemon while the session was offline survives the re-announce; and
    the keeper registration now persists the announced slot, so
    pre-connect turns are not lost when the process stops before the
    next `agent_end`.
  - **App**: linking an offline (keeper-held) session routes to the
    device daemon instead of the keeper (which only serves session_sync —
    the link used to time out). Unread fixes: a missing read marker no
    longer hides seq-0 rows; the marker is cleared when a room's history
    resets (new conversation); a ref-linked legacy tile still shows its
    unread; Home opens all rooms' msgs boxes before the first list so
    offline tiles show cached unread immediately; and the chat only
    advances the read marker while the app is foregrounded — keep-alive
    deliveries while the phone is locked stay unread.

- **Home: "Offline" filter tab reset to "Online" on every rooms persist** —
  `HomeViewModel._load()` (triggered via `PairingStorage.notifyListeners` from
  each non-identical `room_announced` persist in `ConnectionManager`) rebuilt
  the `HomeList` without the current `filter`, so any working-flag flip or
  keeper re-announce snapped the tab back to its default while the user read
  the offline list. `_load()` now carries the selected tab across reloads;
  only the first load (still `HomeLoading`) uses the `online` default.
  Regression test: `storage reloads preserve the selected tab`.

### Added

- **Offline session cleanup from the Home list (plan/148)**: long-press an
  offline tile, pick "Delete worktree & branch", confirm: the PC's device
  daemon runs `git worktree remove` + `git branch -D` + registry prune for
  that session's worktree, and the phone drops its cached room record in the
  same frame. Gating: the room's cwd must match a tracked worktree, the
  session must not be running, and no other LIVE session may own the folder;
  keeper-held (archive) rooms are eligible because transcripts live in
  `~/.pi/agent/sessions/<cwd>`, not in the worktree. Dirty worktrees are
  refused by git (nothing removed, message surfaced), and a session that
  comes back online between opening the menu and confirming aborts the
  action. Path matching normalizes separators (Windows `\` vs Pi `/`) and
  compares drive-letter paths case-insensitively. New public widget
  `CleanupWorktreeDialog` in `app/lib/ui/home/widgets/`.
- **Home tiles: context-window gauge (plan/147)** — a subtle full-height
  background wedge per tile (width = used fraction of the model's context
  window; user-tuned 17/24/35/50 pressure ladder, accent → warning →
  error with rising prominence at each step) plus the max context window
  behind the model name in the subtitle (`claude-sonnet-4-5 · 200k`).
  View-layer change on the existing `room_meta.context_usage` feed; the
  fraction falls back to `tokens/contextWindow` when `percent` is null
  right after compaction, and rooms without usage keep the old look.
  Review fix: usage never survives a model switch anymore — the
  extension tombstones `context_usage: null` alongside the new model, and
  both app merge paths (live update + rooms snapshot) drop cached usage
  that belongs to a different model, so a fresh model is never labeled
  with the previous model's window.
- **Home session tiles alternate git branch and model (shipped in app 1.4.1)**
  — the tile subtitle flips every 3 s between the posh-git summary
  (branch / ahead / behind / dirty / stash) and the selected model when a
  session publishes both, driven by a single ref-counted `_SubtitleClock`
  so every tile switches in lock-step (one coordinated alternation, not
  per-tile flicker). 300 ms crossfade; static precedence
  (git → model → "Last paired") when only one signal exists. The git
  snapshot used to fully replace the model subtitle, so the selected LLM
  was never visible in the session list while a git status was known.
- **Mermaid diagram previews via `show_file` (plan/144)** — the agent can now
  push a Mermaid source file (`.mmd`/`.mermaid`, or any file with
  `kind: "mermaid"`) to the phone, where it renders as an actual diagram
  instead of raw text. Rendering happens in a sandboxed WebView from a
  **bundled** mermaid.js copy: fully offline, `connect-src 'none'`, no CDN
  round-trip, `securityLevel: "strict"` labels. The diagram theme follows the
  app (dark/light), supports drag-pan / pinch-zoom / double-tap-reset, and
  parse errors surface as a readable in-page message instead of a spinner.
  Why bundled instead of CDN: the preview must work without network and must
  not break the HTML viewer's sandbox discipline.
- **Mermaid viewer gesture rework (plan/144 fix)** — on-device testing
  (Android/TLHC) showed the in-page touch handlers never see motion events:
  an ancestor gesture detector wins the arena and finger 2 never reaches the
  WebView at all. All motion gestures now run on the Flutter side via a raw
  `Listener` around the WebView and drive the page through `runJavaScript`
  (`mmdPan`, `mmdZoom` with a focal point); the page keeps only double-tap
  (zoom-in around the tap / back to fit) and desktop wheel zoom. ＋/－/fit
  buttons cover the no-gesture path, the initial view is centered (not
  top-left), and the swipe-down-to-dismiss detector is disabled for the
  Mermaid viewer (it starved the WebView's gesture arena).

### Changed

- **Waiting-for-you banners now also fire while the app is open** —
  on-device testing showed the orange tile dot alone is too easy to miss
  when the phone sits unlocked on the desk. Every rising edge notifies now
  (foreground and background); the only suppression left is the room whose
  answer sheet you already have open. The permission ask stays
  foreground-only (the OS dialog can't appear from the background), and the
  background snapshot still covers prompts that were already pending when
  the app connected.

### Added

- **Waiting-for-you notifications that actually fire (plan/141)** — the
  "Pi is waiting for input" banner now covers the flow where the orange dot
  appeared *before* you pocketed the phone: backgrounding the app snapshots
  every live waiting session and posts a banner for each (except the one
  whose answer sheet you already have open). Answering the prompt anywhere
  now also **clears** that banner from the tray. Because nothing ever asked
  for notification permission outside the keep-alive path, Android 13+
  installs could silently drop every banner — the app now asks once at the
  first waiting edge, and Settings gained a **Session alerts** row (state +
  re-request) as the recovery path after a denial.
- **Adjustable font size (plan 131, upstream #114)** — Settings → Display
  now has a **Font size** row with four presets (Small / Default / Large /
  XL). The preset composes onto the system text scale — it multiplies the
  OS accessibility setting instead of replacing it — and applies live to
  every piece of app text (chat, settings, dialogs), no restart needed.
  The 12.5 pt monospace chat text was hard to read on phones, and iOS
  offers no per-app text size for Flutter apps.
- **Blocker diagnosis for `register_ack` timeouts** — when the local
  broker has a listener that cannot answer (a suspended or
  event-loop-blocked leader), the join failure now names the process
  holding it instead of leaving you to hunt for it. On Linux it walks
  `/proc` within a 250 ms budget and reads the cmdline (Node reports
  "MainThread" in `comm`, which identifies nothing in `ps`); on Windows —
  this fork's named-pipe addition — it asks the kernel for the server pid
  of the pipe (`GetNamedPipeServerProcessId`, via a short-lived
  PowerShell probe, ~0.5 s) and classifies suspended / exited / running
  from the thread states. The advice is evidence-based: `kill -CONT`
  (Process Explorer Resume / `pssuspend -r` on Windows) only for a
  provably suspended owner; a busy one is described and left alone.
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
- **Notes on `ask_user` answers (plan 128)** — the clarification sheet now
  lets you attach a note to a question (pi-ask `Shift+N`) and to a selected
  option (pi-ask `n`), as an inline expandable "Add note" field with a chip
  when filled. A question note alone is a valid answer; an option note rides
  only its selected option (custom text on a single-select question still
  overrides the selection and drops it, matching pi-ask). The wire already
  carried `note` / `optionNotes` end-to-end — this fills the missing UI.

### Fixed

- **Failed mesh joins no longer leak or strand the broker (upstream PR
  #124 port)** — an unanswered registration leaked the client socket
  forever; a leader whose self-registration failed kept the broker path
  bound, so an idle session went on brokering the machine's mesh while
  reporting "join failed" to the user; and `/remote-pi`'s join closed
  its candidate only when superseded by a newer join. Every failure path
  now closes and releases — election only ever proved the endpoint was
  connectable, never that its owner was servicing anything (a suspended
  leader's listening instance completes the kernel-level handshake on
  POSIX and Windows alike).
- **`ask_user` sheet not appearing when backgrounded / on relaunch (plan 129)**
  — a clarification fired while the app was backgrounded or just relaunched was
  silently dropped (and never recovered): the request was delivered to a
  broadcast stream whose only listener was the per-route `ChatViewModel`, so
  with no chat open there was nothing to receive it — and even the plan/100
  reconnect replay landed on Home, with no listener. The current request is now
  a durable value in `SyncService` (mirroring `streaming`/`working`), so a
  missed request surfaces when the chat next opens; a flow that already resolved
  is correctly not re-surfaced.

### Fixed

- **app/assets/CHANGELOG.md was double-encoded** — the 1.4.1 backfill
  (e4ae5690) wrote the asset through a PS redirect, turning every non-ASCII
  char into mojibake (`â€”` for `—`, etc.); the in-app changelog viewer
  displayed the garbage. A one-shot cp1252→UTF-8 round-trip repaired all
  58 runs; shipped 1.4.1 APKs were unaffected (the release tag predates
  the backfill).

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
