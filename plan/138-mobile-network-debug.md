# Plan 138 — Mobile network: diagnose + fix the cellular path

## Context

Reported symptom: *"Verbindung geht nicht, wenn ich auf mobile network bin"* —
the phone (Z Fold4) works at home on Wi-Fi but stays offline on cellular.
The user also quoted `100.88.223.118:44319` — read from the **Tailscale
Android app**. That is the **phone's own** Tailscale IP (`z-fold4-von-alessandro`),
not a relay address, and nothing anywhere listens on port 44319.

### Session findings (2026-09-05, all verified live)

| Check | Result |
|---|---|
| `tailscale status` | PC `chico` = `100.75.161.17`, phone = `100.88.223.118` (idle, reachable — `tailscale ping` pong in 11 ms, direct via LAN `192.168.0.39`) |
| MagicDNS / accept-dns | enabled on the PC; `chico.tail5d4821.ts.net` resolves locally |
| Relay process (`Piper Relay` task) | **UP**, binds `0.0.0.0:3000`; `GET /` → 400 on both `127.0.0.1:3000` and `100.75.161.17:3000` (alive; 400 is expected for a plain-HTTP hit on a WS endpoint) |
| Port 44319 | **nothing listening** locally; the string appears **nowhere in the repo** |
| `~/.pi/piper/config.json` | `advertise: https://chico.tail5d4821.ts.net` |
| `tailscale serve status` | `https://chico.tail5d4821.ts.net` → proxy `http://127.0.0.1:8000` |
| Port 8000 | **nothing listening** → `curl https://chico.tail5d4821.ts.net/` → **502** |

### Root-cause chain

- **Defect A (PC, confirmed):** `tailscale serve` points at `127.0.0.1:8000`,
  a dead backend. The relay is on `:3000`. Every dial of the advertised HTTPS
  name gets a 502. The **only** off-network path is therefore broken.
- **Defect B (phone, by design of plan 115):** on cellular the app sets
  `skipLan: true` (`selectEndpointOrder`) and dials **only** the primary
  `prefs.relayUrl`. At home the LAN endpoints (learned from the relay hello)
  carry the connection and **mask** the broken primary; on cellular there is
  no fallback below the primary → permanent offline. The retry loop from plan
  114 cannot help — no amount of redialing fixes a dead backend.
- **Defect C (phone, to verify in Step 2):** if the phone's stored primary is
  the misread `100.88.223.118:44319` (the phone dialing **itself**), it can
  never connect on any network. Wherever that string came from, it is not and
  never was a relay address.

This plan does **not** revisit any closed decision (00-decisions): Tailscale
overlay for off-network access is the documented model; the serve mapping is
ops config, not architecture.

## Expected structure

No new code in the app or relay for the fix itself (hardening items are
optional add-ons). The deliverable is a **repaired PC-side path + a verified
phone-side endpoint list**, plus a drift check so this never breaks silently
again.

## Steps

### Step 1 — Point `tailscale serve` at the relay (PC)

```powershell
# reset the stale 8000 mapping, then serve the relay over tailnet HTTPS
# (verified syntax on this tailscale version — older docs show
#  `serve --https=443 / ...`, which this CLI rejects)
tailscale serve reset
tailscale serve --bg 3000
tailscale serve status        # expect: proxy http://127.0.0.1:3000
```

# prove the backend chain end-to-end
curl.exe -s -o NUL -w "%{http_code}" https://chico.tail5d4821.ts.net/
# expect: 400 (relay answering through serve) — NOT 502
```

Why HTTPS-serve and not `advertise: http://100.75.161.17:3000`: plain HTTP
over the tailnet only works while the installed APK permits cleartext
(debug builds do; release builds do not). The serve path gives a valid
TLS cert (`chico.tail5d4821.ts.net`) that survives release builds.

**Acceptance:** curl through the HTTPS name returns a relay response (400),
not 502; `tailscale serve status` shows the `:3000` backend.

> **Status 2026-09-05: DONE.** `tailscale serve --bg 3000` executed; status
> shows `/ proxy http://127.0.0.1:3000`; HTTPS curl → **400** (was 502).

### Step 2 — Verify the phone's stored primary URL

- App → Settings → Relay URL. Required value: `https://chico.tail5d4821.ts.net`.
  If it shows `100.88.223.118:44319` (or any 44319 address), that is Defect C
  confirmed — fix via Step 3.
- Cross-check what the app actually dials on cellular:

```powershell
# adb over the tailnet (SESSION-STATUS gotcha: flutter/adb not on PATH)
C:\Android\sdk\platform-tools\adb.exe logcat -s flutter | Select-String "ws"
# expect a wss://chico.tail5d4821.ts.net dial once serve is fixed
```

**Acceptance:** primary URL is the HTTPS name; logcat shows the app dialing
`wss://chico.tail5d4821.ts.net` (not a 100.88.x / 44319 address).

### Step 3 — Re-pair if the primary is wrong or stale

`advertise` in `~/.pi/piper/config.json` is already correct. With Step 1
done, `/remote-pi pair` emits a QR whose `r=` resolves for the first time
on cellular too. Scan it; the app adopts the primary from the QR.

**Acceptance:** pairing completes from the phone; afterwards the app is
Online at home **and** the endpoints list still contains the LAN candidate
(relay hello advertisement — plan 115).

### Step 4 — Cellular verification matrix

Run each, watch `~/.pi/piper/relay.log` for the phone's WS connect:

1. Tailscale **ON**, Wi-Fi **OFF** (pure cellular): app Online within
   seconds of opening; not stuck in retrying.
2. Tailscale **OFF**: app shows offline/retrying (expected — no overlay
   path); re-enable Tailscale, reopen app → Online fast (plan 114 recovery).
3. Back on home Wi-Fi: LAN endpoint wins again (logcat shows `192.168.x.x`).

**Acceptance:** all three rows behave as stated.

### Step 5 — Drift hardening (optional, cheap)

- `scripts/check-piper-stack.ps1`: asserts (a) something listens on
  `0.0.0.0:3000`, (b) `curl https://chico.tail5d4821.ts.net/` ≠ 502,
  (c) `~/.pi/piper/config.json` advertise matches the serve name. Run it
  manually or wire it into the `Piper Relay` task's restart path.
- Optional relay route `GET /health` → 200, so checks (and plan 115c's
  endpoint badge) can probe without WS semantics.
- Note the release-build constraint in `relay/README.md`: primary must stay
  HTTPS (cleartext `http://100.x:3000` dies in release builds).

## DoD

On cellular with Tailscale up, the app goes Online without manual restart;
at home the LAN endpoint still wins; the stale `:8000` mapping is gone; the
check script is green; the `100.88.223.118:44319` misreading is documented
(phone's own address, never the relay).

## Next

- **115c** — endpoint visibility badge (ℹ dialog shows LAN vs Tailscale);
  would have made Defect A visible instantly instead of "offline forever".
- `/health` route on the relay + scripted drift check.
- Consider advertising **both** the HTTPS name and `http://100.75.161.17:3000`
  as a `manual` secondary in the app, so one broken serve config never takes
  the whole mobile path down.
