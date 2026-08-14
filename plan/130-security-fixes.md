# Plan 130 — Security fixes (2026-08-14 review)

**Status:** implemented · **Review source:** [`review/security-2026-08-14.md`](../review/security-2026-08-14.md)

Five fixes from the security review, executed in one pass across `relay/`,
`pi-extension/` and `app/`. Rollout mode: **transition-safe** (nothing breaks
for old clients until they re-pair/upgrade; banner chosen over full wss).

## 1. Inner-envelope sender signatures (H1 — relay impersonation)

Wire: outer envelope gains optional `sig` = base64(Ed25519(`"piper/inner/v1\n" + ct`))
made with the sender's **WS-handshake key**. Domain prefix prevents cross-protocol
signature confusion (nonce handshake / mesh blobs use the same keys).

- **Relay** (`protocol/outer.rs`, `handlers/peer.rs`): parses and forwards `sig`
  verbatim in the rewrite; never verifies, never strips. Old relays drop the
  field (harmless — transition).
- **Pi** (`transport/inner_sig.ts`, `transport/peer_channel.ts`, `index.ts`):
  signs every outbound frame (`pair_ok` included); inbound — present+invalid →
  always drop; absent → drop once the peer's `signing` ratchet is on.
  Ratchet = in-memory map (sync decisions, same-tick replies) warmed from
  `peers.json` at start, flipped on first verified sig, persisted best-effort
  (`PeerRecord.signing`, `markPeerSigning`).
- **App** (`ws_transport.dart`): signs outbound `ct` with the device key;
  verifies inbound against the paired Pi's epk; same ratchet persisted on
  `PeerRecord.signing` via `PairingStorage` (wired in `dependencies.dart`).

Not confidentiality: a compromised relay still **reads** everything (E2E cipher
remains out of scope); it can drop/strip sigs until a peer has ratcheted, after
which unsigned frames from that peer are rejected.

## 2. Insecure-transport banner (H2 — plaintext LAN dial)

`relayTransportIsSecure()` (`relay_config.dart`): `https/wss` or loopback →
secure; anything else (the default `ws://` RFC1918 dial) → insecure. Flows
`WsTransport.isTransportSecure` → `PlainPeerChannel` (`ITransportSecurityInfo`)
→ `ConnectionManager.isTransportSecure` → `HomeViewModel` → persistent
non-dismissable `_InsecureTransportBanner` on Home while Online insecure.

## 3. Relay caps (M2)

- `ws_handler`: `max_message_size`/`max_frame_size` = 5 MiB (was tungstenite
  default ~64 MiB; control frames bypassed the 4 MiB `ct` cap).
- `pi_envelope`: embedded envelope serialized-measured against 4 MiB
  (`MAX_PI_ENVELOPE_BYTES`), new `too_large` transport error.
- Auth step now times out (`AUTH_TIMEOUT_MS` = 5 s, like hello) — half-handshaked
  sockets no longer linger forever.

## 4. Mesh-gated presence/rooms (M1)

`subscribe_presence` / `presence_check` / `subscribe_rooms` / `rooms_check` +
presence backfill now filter target peers through the same `MeshAuthCache`
membership check that gates `pi_envelope` forwarding (self always allowed).
Any authenticated relay client can no longer enumerate other peers' online
state, cwd, model, git snapshot.

## 5. Local hardening + remote-action cwd policy (M4/M5/M3)

- `ensureGlobalDirs()`: `~/.pi/piper` + `sessions/` + `skills/` created `0700`
  and chmod'd best-effort when pre-existing (was umask-dependent).
- Broker + supervisor UDS sockets chmod'd `0600` after bind
  (`leader_election.ts`, `daemon/supervisor.ts`); supervisor parent dir `0700`.
- `actions/cwd_policy.ts`: remote-supplied cwds for `open_terminal_request`
  and `start_session_request` must live inside a configured `projects.roots`
  entry or a **registered** worktree (reopen also verified against the
  registry). Unknown roots get an actionable `ok:false` naming the config
  escape hatch.

## Test evidence

- relay: `cargo test` — 126 tests incl. new sig-passthrough, oversized-frame,
  auth-timeout, mesh-gated presence/rooms (tests now publish sibling blobs via
  `make_mesh_siblings`), `too_large` pi_envelope. `cargo clippy` clean.
- pi-extension: `npm test` — 889 passed incl. new `peer_channel.test.ts`
  (sign/verify/ratchet/strip-attack drop) and `cwd_policy.test.ts`.
  `tsc --noEmit` clean. `dist/` rebuilt.
- app: `flutter analyze` clean; `flutter test` 692 passed (2 failures
  pre-existing on clean tree — platform-dependent voice/appbar tests); new
  tests for `relayTransportIsSecure` classification and `PeerRecord.signing`
  round-trip.

## PR #24 review follow-up (same day)

Six findings from the Augment code review on the merged PR — all addressed on
`fix/security-review-followup`:

1. **Replay (high)** — v2 signatures carry a sender timestamp; recipients
   reject frames outside a 10-minute window AND dedupe inner message `id`s
   (LRU 2048, per channel) so a replayed frame never executes twice even
   inside the window. Pi (`peer_channel.ts`) and app (`ws_transport.dart` →
   `peer_channel.dart`) both.
2. **Cross-peer injection (high)** — v2 binds the RECIPIENT pubkey into the
   signed bytes (`piper/inner/v2\n<dest>\n<ts>\n<ct>`): a relay forwarding an
   owner-signed command from Pi A to Pi B fails verification on B. v1 frames
   (app 1.3.0) remain accepted during transition — they predate the binding.
3. **Ratchet lost after restart (high)** — the in-memory ratchet warms from
   `peers.json` by CANONICAL key (base64url handles normalized);
   `markPeerSigning` matches records canonically via the new exported
   `sameOwnerHandle`. Raw-spelling entries can no longer silently miss.
4. **Async ratchet race (medium)** — app-side inbound handling is serialized
   through a future chain (strict arrival order), and the ratchet flips
   SYNCHRONOUSLY when a `sig` is present, before the async verify — a
   trailing unsigned frame can never slip through the gap.
5. **Symlink escape (medium)** — `cwd_policy` compares on `realpathSync`
   (targets must exist; roots fall back to syntactic form when absent).
   A cwd that traverses a symlink out of a root is rejected.
6. **One-shot subscription auth (medium)** — relay runs a 60 s
   `prune_unauthorized_subscriptions` sweep re-checking every stored
   presence/rooms (target, subscriber) pair against current mesh membership
   (self-watch always allowed). `MeshAuthCache::clear()` exposed as an ops
   hook. Worst-case revocation latency = sweep interval + cache TTL.

Wire note: the outer envelope gained an optional `ts` (u64, forwarded
verbatim like `sig`). Deploy order unchanged: relay → extension → app.

## Rollout notes

Deploy order: **relay first** (forwarding `sig` is additive), then extension
(signs + verifies), then app (signs + verifies + banner). Mixed fleet behaves
as before until both ends of a pair upgrade; enforcement follows the ratchet,
not a version flag.

## Next plans

- 1xx: optional `wss://` + QR-pinned self-signed cert (full fix 2, deferred by
  choice), E2E confidentiality (X25519 inner cipher) now that signing is in
  place, relay conn/rate caps per IP.
