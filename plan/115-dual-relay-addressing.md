# Plan 115 — Dual relay addressing (LAN + Tailscale)

## Context

Plan 114 fixes **connection resilience** — detecting half-open sockets and
recovering fast on any network. This plan is orthogonal: it changes **which
endpoint the phone dials**, not how it recovers.

Today the phone reaches the relay through a **single** `relayUrl` (the relay's
Tailscale address, e.g. `http://100.75.161.17:3000`). That works off-network,
but at home it drags every byte through Tailscale — and Tailscale-on-Android's
network handoff is the flaky layer (see the "Piper stays offline when I leave
the house" report). The relay, however, binds `0.0.0.0:3000`, so the **same
process** is also reachable on the home LAN directly. Bypassing Tailscale on
the home VLAN removes the flaky layer entirely for the most common location.

This plan stores **multiple endpoints** per relay and picks the best one with
failover — **LAN-first at home, Tailscale off-network** — so home use is
rock-solid while mobile still works.

### Design decisions

- **One relay, many URLs.** The relay already listens on all interfaces; we do
  not run a second instance. We just teach the phone a list of addresses for it.
- **Happy-eyeballs selection, not subnet detection.** Rather than sniff the
  phone's subnet, the app races the LAN endpoint (short connect timeout) and
  falls back to Tailscale. On cellular the LAN IP is unroutable → fast failure
  → Tailscale wins; on home Wi-Fi the LAN connects first. Plan 114's
  `connectivity_plus` is a *speed-up* (skip the LAN race on cellular), not a
  prerequisite.
- **Endpoint source = the relay advertises its candidates.** At
  pairing/hello, the relay enumerates its non-loopback local IPv4 addresses and
  sends them; the app persists them as the LAN candidates alongside the
  Tailscale URL it already has. (Manual entry in Settings is the fallback.)
- **Reuses plan 114 plumbing.** Endpoint failover hooks into `forceReconnect()`
  + `connectivity_plus`; no new transport concept.

> **Scope note (why D ≠ the fix):** this plan makes **home** use Tailscale-free.
> It does **not** help on mobile, where Tailscale is still the only path and
> still flaky. Mobile recovery is plan 114's job. The two are complementary —
> see the "are A/B/C needed if we do only D?" discussion.

## Expected structure

### Endpoint model

- `RelayEndpoint { url: String, kind: EndpointKind }` where
  `EndpointKind ∈ { lan, tailscale, manual }`.
- `PeerRecord.relayUrl: String` → **`PeerRecord.endpoints: List<RelayEndpoint>`**
  (single-source migration: existing records get one entry `{ url: oldRelayUrl,
  kind: manual }`). `relayUrl` stays as a computed getter (first/preferred) so
  existing call sites compile; migrate lazily.
- **Preference order**: `lan` < `tailscale` < `manual` (LAN tried first).

### Relay-side advertisement (Rust, optional but preferred)

- On `hello`/pairing handshake, the relay includes its local IPv4 candidates
  (filter loopback + link-local + Tailscale `100.x`; keep RFC1918 `192.168 /
  10.x / 172.16`). This is the relay **telling the phone** "here's how to reach
  me without Tailscale."
- No `RoomMeta` change (this is handshake-only metadata, not per-room).
- Backwards-compatible: old apps ignore the field; old relays omit it.

### Selection + failover (`connection_manager.dart`)

1. `ConnectionFactory` becomes endpoint-aware: it receives the **ordered
   candidate list** and tries them in preference order with a **short per-
   endpoint connect timeout** (e.g. 1500 ms for LAN, the normal timeout for
   Tailscale). First to succeed wins; the winner is remembered as the
   "last-good endpoint" for next time (preference bias).
2. On a fresh connect after a drop, start from the last-good endpoint, then
   fall through the list.
3. `connectivity_plus` (plan 114) optimization: if the phone reports
   **cellular**, skip LAN candidates entirely (they can't route) — straight to
   Tailscale. Saves the failed-race latency on mobile.
4. **No per-room change**: the relay is one host; endpoint selection happens
   once per `ConnectionManager` connect, transparent to rooms/presence.

### Settings + pairing

- Settings "Relay" gains an optional **LAN URL** field (auto-filled from the
  relay's advertisement; user-editable). Clearing it = "Tailscale only" (opt
  out of D entirely).
- Re-pair flow captures both URLs.

## Steps

1. **Endpoint model + migration.** `RelayEndpoint` + `PeerRecord.endpoints`;
  keep `relayUrl` as a compat getter. Migration: one `manual` entry from the old
  field. Unit-test the migration + preference ordering.
2. **Relay advertisement.** Rust: enumerate local IPv4s in the hello/handshake
  response (filtered). Wire codec field (optional). Rebuild relay. (If time-
  boxed, defer to step 6's manual entry and ship D without auto-discovery.)
3. **Endpoint-aware factory + happy-eyeballs.** `ConnectionFactory` takes the
  ordered list; per-endpoint timeout; last-good caching. Unit-test the race
  order + cellular-skip (inject a fake connectivity result).
4. **Settings UI.** LAN URL field (auto-filled, editable, clearable). Persist
  into the endpoint list.
5. **Wire last-good + failover into the reconnect path.** `forceReconnect()`
  (from plan 114) restarts from last-good then falls through.
6. **Verify on device.** At home on Wi-Fi: confirm the active endpoint is LAN
  (logs / a debug chip), Tailscale idle. Switch to cellular: confirm Tailscale
  endpoint, LAN skipped. Kill the LAN path (disable Wi-Fi on the relay host's
  NIC): confirm failover to Tailscale without an app restart.

### Acceptance criteria

- [ ] At home, the phone reaches the relay via **LAN**, not Tailscale (Tailscale
  can even be stopped on the phone and the session stays up).
- [ ] On cellular, the LAN race is skipped (or fails fast) and Tailscale is used.
- [ ] If the preferred endpoint dies mid-session, the app fails over to the
  other within seconds, **without a restart**.
- [ ] A peer paired before this plan still works (single-endpoint migration).
- [ ] `cargo test` (relay), `tsc --noEmit` (ext, if touched), `dart analyze`
  clean; existing transport tests pass.

## DoD

The phone dials the relay over LAN at home and Tailscale off-network, failing
over automatically. Tailscale-on-Android's flakiness no longer affects home
use. Committed + pushed; SESSION-STATUS notes the relay rebuild + the endpoint
migration.

## Next

- **115b** — relay mDNS/Bonjour advertisement so the app auto-discovers the LAN
  endpoint with zero manual entry (today the relay pushes its IPs at hello;
  mDNS lets the phone find it even before pairing).
- **115c** — endpoint health telemetry: surface which endpoint is live in the ℹ
  dialog (LAN vs Tailscale badge) so the user can see D working.
- Pairs with **114** (network resilience) — D's cellular-skip + failover reuse
  114's `connectivity_plus` and `forceReconnect()`.
