<h1 align="center">Piper</h1>

<p align="center">
  Control your <a href="https://github.com/earendil-works/pi">Pi coding agent</a> from your phone.
  Pair with a one-time QR code and chat with your local agent — even when you're away from your computer.
</p>

---

> **This is a fork.** Piper is a fork of
> [`jacobaraujo7/remote_pi`](https://github.com/jacobaraujo7/remote_pi) (Remote
> Pi) and follows its own product line — it does not track back into the
> original project. See [FORK.md](./FORK.md) for what diverges and how upstream
> changes are merged in.
>
> The logo in `branding/` is still Remote Pi's and is not used here yet;
> Piper needs its own artwork before anything ships.

## Links

- **GitHub (this fork)** — <https://github.com/pungggi/remote_pi>
- **Upstream project** — <https://github.com/jacobaraujo7/remote_pi>
- **Package documentation** — <https://pi.dev/packages/remote-pi?name=remote-pi>

### Downloads

This fork has no published builds yet — build from source (see each package's
README), or grab the upstream releases below if you want the original app.

| Platform | Status |
|---|---|
| Google Play (Android) | *not published — upstream: [Remote Pi](https://play.google.com/store/apps/details?id=work.jacobmoura.remotepi)* |
| APK (sideload, Android) | *not published — upstream: [GitHub Releases](https://github.com/jacobaraujo7/remote_pi/releases)* |
| iOS / macOS | **not supported by this fork** — see [FORK.md](./FORK.md#plataformas-apple-fora-de-escopo) |

## What's in this repo

| Package | Stack | Role |
|---|---|---|
| [`app/`](./app) | Flutter (Android) | Mobile client |
| [`pi-extension/`](./pi-extension) | Node + TypeScript | Pi extension exposing `/remote-pi` |
| [`relay/`](./relay) | Rust + Tokio | WebSocket routing + signed mesh membership storage |
| [`site/`](./site) | NextJS | Landing page + legal pages |

## Architecture

```
Flutter app ──wss──► Relay (Rust) ◄──wss── Pi extension (Node)
                                                  │
                                           Local Pi process
                                                  │
                                           UDS broker (local mesh)
                                                  │
                                           Other agents on the same machine
```

- **Pairing** via short-lived QR code; peers persisted in Keychain (mobile) and `~/.pi/remote/` (desktop)
- **Ed25519 authentication** — the Relay handshake proves possession of the connection key; App↔Pi pairing is enforced by the endpoints. For Pi↔Pi routing, the current Relay permits a route when a correctly signed Owner blob lists both Pi keys; that check does not prove the Owner paired with or controls either Pi
- **TLS protects traffic in transit**, but current payloads are not E2E; see [`relay/README.md`](./relay/README.md) for the exact trust boundary

## Local agent mesh

When multiple Pi agents run on the same machine, they discover each other through
a **Unix Domain Socket broker** managed by the extension. One agent wins the
leader election and binds the socket; the others connect as clients. For targets
on that same machine, agents use the opaque addresses returned by `list_peers` —
no relay, no network, no extra config.

Three LLM-facing tools are exposed in the Pi chat:

- `list_peers` — lists local and cross-PC addresses available to the agent
- `agent_send` — sends a unicast message and waits for a delivery ACK. Compatible ACK values are `received`, `busy`, `denied`, and `timeout`; current brokers return `received`, `denied`, or `timeout`, while `busy` only indicates a dropped message from an old broker leader that must be restarted before resending. Broadcast is `sent` with no ACK. Asynchronous content replies use `re`
- `agent_request` — request/response with timeout, available only as deprecated legacy behavior

This lets you set up local multi-agent workflows (e.g. a `backend` agent asks a
`frontend` agent for help) entirely on your machine, in parallel with the remote
mobile pairing.

## Relay

The app and your PC are both WebSocket *clients* — neither listens for
incoming connections, and there is no local discovery. So they need a relay to
meet at. **Piper's default is running that relay on your own network**, so no
traffic and no pairing metadata ever leaves your Wi-Fi:

```bash
cd relay && cargo run --release
# or: docker build -t piper-relay . && docker run -p 3000:3000 -v piper-data:/data piper-relay
```

That's the whole setup. The extension reaches it over loopback, the pairing QR
advertises the LAN address, and the app adopts that address when you scan — no
IP to type on the phone.

To reach your Pi from **outside** your Wi-Fi, put both ends on the same overlay
network instead of exposing anything publicly. With
[Tailscale](https://tailscale.com) installed on the machine and the phone, the
relay you already run gets a second address on the tailnet (`100.x.y.z`) that is
reachable from anywhere and stable across networks. Tell the pairing QR to
advertise it:

```bash
/remote-pi set-advertise http://100.x.y.z:3000
```

The pairing QR then advertises that address, the app adopts it on scan, and the
same pairing works at home and on mobile data — no port forwarding, no domain,
no certificate. [WireGuard](https://www.wireguard.com) or your own VPC work the
same way.

Piper runs **no public relay** and does not point at anyone else's. A relay sees
every envelope in plaintext, so whoever operates it is a single point of trust
for both routing and content — that role stays yours.

Security trade-offs and the self-hosting guide: **[`relay/README.md`](./relay/README.md)**.
Design notes for the LAN default: **[`plan/102`](./plan/102-lan-default.md)**.

## Getting started

Install the Pi extension in any project where Pi runs:

```bash
pi install npm:remote-pi
```

Then in the Pi chat, run:

```
/remote-pi
```

The setup wizard walks you through agent name, session name, and relay choice,
then prints a QR code. Scan it with the Piper mobile app and you're paired.

Start the relay first — by default the extension expects one on your own
machine (see [Relay](#relay)). If pairing does not go through, work down
[Troubleshooting](#troubleshooting--connection-problems).

### Recommended companion: `@eko24ive/pi-ask`

```bash
pi install npm:@eko24ive/pi-ask
```

With pi-ask installed, the agent's `ask_user` clarification prompts (structured
questions with options, multi-select, and previews) render natively in the
mobile app — answer from your phone and the flow resolves on the desktop.
Without it, the agent simply asks in plain chat text (also answerable from the
phone, just unstructured). Piper works either way; pi-ask is optional.

## Troubleshooting — connection problems

Almost every "it won't connect" is one of the following. Work down the list in
order; each check is cheap and rules out a whole class of causes.

**Is the relay actually running?**

```bash
curl http://localhost:3000/health
```

No answer means the relay is not up, and nothing downstream can work. Start it
(see [Relay](#relay)) and try again.

**Is the port reachable from the phone?**

macOS and Windows block inbound connections on port 3000 by default — the relay
is up, `localhost` works, and the phone still sees nothing. On macOS, allow the
binary under System Settings → Network → Firewall; on Windows, in Defender
Firewall's inbound rules. Quick check from another machine on the same Wi-Fi:

```bash
curl http://<your-lan-ip>:3000/health
```

**Are both devices on the same network?**

Phone on cellular instead of Wi-Fi is the common one. Guest networks and
"client isolation" / "AP isolation" on the router also block device-to-device
traffic while the internet still works fine — a separate IoT or guest SSID will
not pair.

**Does the QR code contain an `r=` field?**

The extension omits it when it cannot find a LAN address (Wi-Fi down, or only
virtual interfaces present). Then the app keeps whatever relay it had, which is
usually the wrong one. Check what the extension resolved:

```
/remote-pi config
```

**Did it pick the wrong interface?**

With Docker, a VPN, or several adapters up, the machine has more than one
private address. Piper prefers `192.168.x.y` because that is what home and
office Wi-Fi hands out, but it can still guess wrong — a VPN that owns the
default route is the usual culprit. Override it:

```bash
REMOTE_PI_RELAY=http://192.168.1.10:3000 pi
# or persist it: /remote-pi set-relay http://192.168.1.10:3000
```

**Did you switch networks since pairing?**

The relay address was stored at pairing time and your router hands out a
different one on another network. Pair again — scanning a fresh QR adopts the
new address. Assigning the PC a static DHCP lease avoids this permanently.

**Does the app reject the URL you typed?**

Enter `http://` or `https://`, not `ws://` or `wss://` — the app converts to
WebSocket internally. `http://` is accepted on purpose for relays on your own
network.

**Was it working before you updated?**

The pairing keys live under identifiers that changed when this fork took its
own namespace, so an app built before that cannot see the old identity. Pair
again; there is nothing to migrate.

## Status

The MVP is functional. Planning notes and roadmap live in [`plan/`](./plan).

## License

License is per-package — see each subproject's `LICENSE` file (the `pi-extension`
is MIT). A repository-wide license decision is pending.
