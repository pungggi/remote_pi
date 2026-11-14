# 164 — Stream perf regression: research findings + measured root cause

**Status**: root cause CONFIRMED by measurement (2026-11-08); relay fix deployed + verified live. App-side follow-up open.
**Date**: 2026-11-08
**Trigger**: "Something slowed down the response stream since our last performance pass" (PR #84, Oct 30).

## Context

The agent response stream (pi-extension → relay → phone app) feels slower than at PR #84 time. Live `relay.log` evidence gathered the same evening:

- **Firehose flood**: while the phone is subscribed, the relay emits ~800-900 `room_announced` frames per 10 s window (`rooms_emitted=858`, `rooms_suppressed=0`). That is ~90 state frames/s riding the same WebSocket as `agent_chunk`.
- **Presence suppression works** (`presence_suppressed=679-892`), room suppression does not: the frames reaching subscribers are non-identical, so the 2026-08-22 identical-frame fix never absorbs them.
- **Keeper churn doubled**: "keeper hello rejected" went from ~5.3k/day (10/29-11/4 log) to ~12.3k/day (current log).
- **Known exemption**: plan/132 `run_done` markers are unique by `ended_at` and deliberately bypass suppression (`registry.rs`); the keeper also refreshes `gh_ref`/`stats` on held rooms (`room_keeper.ts`), and every stats push mutates the frame.

The working hypothesis: a constant background stream of "changed" room frames starves `agent_chunk` processing on the phone, where every inbound frame pays pure-Dart Ed25519 verification.

## Measured root cause (2026-11-08 instrumented relay)

Attribution counters added to the firehose 10s window log (`rooms_poll_top` / `rooms_sent_conn_top` / `rooms_sent_target_top`, top-3 per window) caught the flood with the phone app open:

- **The phone app polled `rooms_check` at ~60/s** (623 polls in one 10s window) for one target peer, and the relay answered **every** poll with a full multi-room snapshot (`rooms_emitted=623, suppressed=0`).
- **Why dedup never fired**: `PeerRegistry::rooms_of` returned `HashMap::into_values()` — Rust HashMap iteration order is randomized per call, so consecutive snapshots serialized differently even with identical content. The per-conn byte-identical dedup could never match; the app's "did the snapshot change" check always said yes, feeding a re-poll loop. Single-room snapshots (all existing tests) have no ordering ambiguity — that is why the suite was green while production flooded.
- Impact: ~60 full-snapshot frames/s on the same WS as `agent_chunk`, each parsed and diffed by the app — starves streaming.

**Fix deployed**: `rooms_of` now sorts by `room_id` (deterministic serialization) + regression test `rooms_check_dedup_suppresses_identical_multi_room_responses` (3 rooms, asserts sorted order AND suppression). 98 lib + 21 rooms tests green. Live after/before: 18 polls/10s → 3 emitted (15 suppressed); steady-state windows quiet.

**Open app-side follow-up**: the re-poll trigger itself (suspects: `PairingStorage` write → `HomeViewModel._onStorageChanged` → `_load` → `subscribeToPeers`; signature matches the paired presence_check+rooms_check ratio 1:1). With suppressible replies the loop is harmless (~2/s decaying), but the trigger deserves its own fix or debounce.

## Primary-source findings

### 1. Discord: the client declares what it is looking at

- **Gateway send rate limit**: 120 events per 60 s per connection, enforced by close code 4008. State streams are capped by design, not best-effort. Source: [Discord Gateway docs](https://docs.discord.com/developers/events/gateway).
- **Lazy guilds** (member-list/presence at scale): the client subscribes to *ranges* (e.g. `[0,99]`) of the member list. The server replies with `GUILD_MEMBER_LIST_UPDATE` carrying delta operators (`SYNC`, `INSERT`, `UPDATE`, `DELETE`) scoped to the subscribed ranges. The client never receives members it is not looking at. Born from the Fortnite/Blobs incidents where full-list fan-out took guilds down. Source: [Unofficial Discord docs, Lazy Guilds](https://arandomnewaccount.gitlab.io/discord-unofficial-docs/lazy_guilds.html).

**Why it matters here**: our phone Home needs ~a screen of session tiles, not the full room registry. The relay pushes everything to every firehose subscriber.

### 2. Matrix sliding sync (MSC3575): room-list sync must be windowed

- The old `/sync` "scales badly as the number of rooms on an account increases ... all rooms are returned to the client" and initial sync "can take minutes."
- Sliding sync's goals: sync time independent of total room count, bandwidth minimized, "don't incremental sync rooms you don't care about," lazy-load extras. Mechanism: sorted lists + ranges (`[0,99]`), per-room `required_state`, delta tokens, and `SYNC/INSERT/DELETE/UPDATE` ops. Source: [MSC3575 proposal](https://github.com/matrix-org/matrix-spec-proposals/blob/kegan/sync-v3/proposals/3575-sync.md).

**Why it matters here**: same failure shape (state feed grows with history, not with what is visible), same cure (window + deltas + subscribe-on-demand).

### 3. tokio broadcast: slow-receiver policy is explicit

- Broadcast channels retain messages until every receiver clones them; one slow receiver fills the ring. At capacity the oldest message is overwritten and the laggard gets `RecvError::Lagged(n)`. The docs spell out the two valid policies: abort, or tolerate the loss and resume from the oldest retained value. Source: [tokio::sync::broadcast docs](https://docs.rs/tokio/latest/tokio/sync/broadcast/).

**Why it matters here**: for *state* frames the right policy is "lag is fine, send me the latest" (loss-tolerant, latest-wins). For chat frames it is "never drop" (the plan/145 ledger already owns that). The relay's firehose should treat room state as latest-wins per (room, subscriber), not as a lossless stream.

### 4. Pure-Dart Ed25519 is the phone-side multiplier

- `cryptography_plus` documents pure-Dart Ed25519 at ~200 signatures/verifications **per second** in the VM (~50 in browsers). Source: [cryptography_plus](https://pub.dev/packages/cryptography_plus). Our app pins `cryptography: ^2.7.0` (same pure-Dart code).
- `cryptography_flutter`/`cryptography_flutter_plus` delegate to platform APIs where available: "up to 100 times faster." Native `FlutterEd25519` exists for Apple platforms; elsewhere `BackgroundEd25519` moves work to a background isolate. Source: [cryptography_flutter](https://pub.dev/packages/cryptography_flutter).
- `fast_crypto` (pub.dev 0.3.0) does **not** cover Ed25519 (RSA/AES/SHA only). A `flutter_rust_bridge` + `ed25519-dalek` binding is the clean Android answer; this monorepo already builds Rust (`relay/`), so the toolchain exists.

**Order-of-magnitude check**: at ~90 state frames/s plus coalesced chunks, a 200/s verify budget leaves almost nothing for parsing, Hive writes, and rendering. Kill the flood *and* cheapen the verify; either alone may not be enough.

### 5. Single-socket ordering (supporting fact)

- WebSocket messages on one connection are strictly ordered; frames from different logical streams cannot interleave. Any state frame ahead of a chat frame delays it. Source: [High Performance Browser Networking, WebSocket](https://hpbn.co/websocket/).

**Why it matters here**: multiplexing firehose + chat on one WS is fine only if the firehose is rate-limited and coalesced. Otherwise head-of-line blocking is structural, not incidental.

## Fix options, mapped to this codebase

- **A. Relay: latest-wins coalescing + per-subscriber rate limit on room frames** (`peers/registry.rs` firehose path). Keep one pending frame per (room, subscriber); flush on a 1-2 s tick or when the subscriber drains. Add a token-bucket cap (Discord-style) per firehose subscriber. No protocol change; biggest expected win per unit of work.
- **B. Relay: change-detection that ignores volatile fields.** Content-hash the broadcast-relevant meta excluding `stats` timestamps/`run_done.ended_at`; refresh stats only when values actually change. This is what lets `rooms_suppressed` do its job again (the fix exists since PR #51; volatile fields currently defeat it).
- **C. Keeper: back off and stop mutating on every sweep** (`session/room_keeper.ts`, 60 s sweep/retry). Exponential backoff for live-room retry hellos; move `stats` refreshes to on-change or a slower cadence. Cuts the doubled keeper churn at the source.
- **D. Phone: verify in batches, then go native.** Coalesce inbound frames and verify the arrival-ordered chain once per batch (one Ed25519 op per batch, not per frame). Longer term: `cryptography_flutter_plus` on iOS + a tiny `flutter_rust_bridge` ed25519-verify crate for Android.
- **E. Protocol (structural, Matrix/Discord pattern)**: firehose v2 = snapshot + visible-window ranges + delta ops, `subscribe_rooms`/`unsubscribe_rooms` on scroll. Removes the "state scales with history" failure class permanently, but touches relay + app; do after A-D prove insufficient or as the next plan.

## Recommended sequence

1. **Measure first** (half a day): add per-hop timestamps (ext send → relay forward → app receive) to one probe turn; add a "top announcer" metric to the firehose. The `[probe]` line in `main.ts` already covers the ext side.
2. **A + B + C** (relay + keeper, no app release needed): should collapse ~90 frames/s to low single digits.
3. **D batch-verify** (app-side, independent deploy).
4. **E** if the structural fix is still wanted after re-measuring.

## Sources

- Discord Gateway docs (rate limiting, intents): https://docs.discord.com/developers/events/gateway
- Discord lazy guilds (ranges, delta ops): https://arandomnewaccount.gitlab.io/discord-unofficial-docs/lazy_guilds.html
- Matrix MSC3575 sliding sync: https://github.com/matrix-org/matrix-spec-proposals/blob/kegan/sync-v3/proposals/3575-sync.md
- tokio broadcast (lagging policy): https://docs.rs/tokio/latest/tokio/sync/broadcast/
- cryptography_plus (pure-Dart Ed25519 ~200/s): https://pub.dev/packages/cryptography_plus
- cryptography_flutter (platform APIs, up to 100x): https://pub.dev/packages/cryptography_flutter
- HPBN, WebSocket (HOL blocking): https://hpbn.co/websocket/
