// Relay endpoint resolution.
//
// The app always connects to a SINGLE relay at a time, regardless of
// how many peers it's paired with. The URL is resolved from:
//
//   1. `prefs.relayUrl` (user override, set via Settings or onboarding)
//   2. `kDefaultRelayUrl` (the public community relay)
//
// Canonical scheme on storage is `http://` or `https://` — this is
// the form the user types and what we keep in Preferences. The WebSocket
// transport calls [toWsRelayUrl] right before opening the socket; the
// mesh HTTP client uses the URL as-is. The legacy `ws://` / `wss://`
// schemes are NOT accepted on input — the app is pre-release and
// historical persisted values get re-set by the user during the
// onboarding gate.
//
// `peer.relayUrl` is kept on PeerRecord for legacy QR code payloads but
// is no longer consulted when opening a connection — the resolution is
// global, not per-peer.

import 'package:app/data/preferences/preferences.dart';

/// **There is no default relay.** Empty on purpose.
///
/// Plan/102 — Piper's topology is a relay on the user's own machine, reached
/// over the WLAN. That address is per-network and handed out by DHCP, so it
/// cannot be a build-time constant: the phone learns it from the pairing QR
/// (`r`), which PairingViewModel adopts into Preferences.
///
/// This constant is what `resolveRelayUrl` returns *before* that happens — a
/// fresh install that has not paired yet, or a QR with no `r`. It used to point
/// at the upstream project's public relay, which meant every fresh Piper
/// install talked to a third party's server before its first pairing. This fork
/// operates no public relay and does not borrow one: reaching a Pi from outside
/// the WLAN is the user's own call (their own relay, or Tailscale).
///
/// Empty is a legitimate state, not an error to paper over — "not paired yet"
/// and "no relay" are the same condition, and the QR resolves both at once.
/// [isValidRelayUrl] rejects it, so nothing treats it as connectable.
const String kDefaultRelayUrl = '';

/// User-facing message returned when [isValidRelayUrl] rejects a value.
/// Surfaced verbatim by Settings and Onboarding — keep stable for
/// localization later. Empty input gets a more generic message; the
/// ws/wss case is called out explicitly so the user understands the
/// app does the conversion internally.
const String kRelayUrlInvalidScheme =
    'Use http:// or https:// (not ws:// or wss:// — the app converts '
    'to WebSocket automatically).';

const String kRelayUrlInvalidGeneric =
    'Enter a valid URL starting with https:// (or http:// for local '
    'relays).';

/// Returns the effective relay URL the app should connect to, or the empty
/// string when none is known yet (see [kDefaultRelayUrl]) — callers that are
/// about to open a connection should treat empty as "not configured", which
/// [isValidRelayUrl] reports.
///
/// When non-empty it is always an `http(s)://` URL; the caller is responsible
/// for applying [toWsRelayUrl] when opening a WebSocket.
String resolveRelayUrl(Preferences prefs) =>
    prefs.relayUrl ?? kDefaultRelayUrl;

/// Translates the canonical HTTP-form relay URL into the WebSocket
/// form expected by the underlying transport. `https://` → `wss://`,
/// `http://` → `ws://`. Pre-existing `ws(s)://` URLs (legacy QR
/// payloads, old peer records) pass through unchanged so the relay
/// mismatch check in `pair_request_flow` can still compare them.
String toWsRelayUrl(String url) {
  if (url.startsWith('https://')) return 'wss://${url.substring(8)}';
  if (url.startsWith('http://')) return 'ws://${url.substring(7)}';
  return url;
}

/// Security fix 2026-08 (H2) — classifies a relay URL's transport for the
/// Home insecure-connection banner. Returns `true` when the link is
/// confidential: `https://`/`wss://` (TLS), a loopback host (`ws://` to
/// localhost can't be sniffed off-path), or a tailnet dial (see
/// [_isTailnetHost] — encrypted by the overlay's WireGuard layer). Any other
/// `http://`/`ws://` host — the default LAN dial — returns `false`: anyone
/// on the same network can read the traffic and (with the relay's own key)
/// impersonate the peer.
bool relayTransportIsSecure(String url) {
  final lower = url.toLowerCase();
  if (lower.startsWith('https://') || lower.startsWith('wss://')) return true;
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') return true;
  return _isTailnetHost(host);
}

/// Banner/overlay alignment (2026-08-31): the insecure-transport banner's own
/// advice says "use https:// or an overlay (Tailscale) relay", and the
/// documented remote setup advertises `http://100.x.y.z:3000` — but the
/// classifier used to flag those dials, so following the banner's advice
/// still left the banner up. A tailnet dial IS confidential regardless of the
/// plaintext scheme: Tailscale encrypts every packet between tailnet nodes
/// with WireGuard, so an off-path (or same-LAN) sniffer sees only encrypted
/// UDP. Recognized as tailnet:
///
/// - IPv4 CGNAT range `100.64.0.0/10` (100.64.0.0–100.127.255.255), the
///   address range Tailscale assigns to nodes;
/// - the Tailscale IPv6 ULA prefix `fd7a:115c:a1e0::/48`;
/// - `*.ts.net` MagicDNS hostnames — resolvable only inside a tailnet.
///
/// Accepted corner case: an ISP handing out 100.64/10 addresses ON THE LAN
/// itself (CGNAT in front of the Wi-Fi, no tailnet involved) would be
/// misclassified as secure. Rare in home/office networks, and every doc that
/// mentions `100.x` in this repo means the tailnet.
bool _isTailnetHost(String host) {
  // MagicDNS name — only a tailnet resolver can answer it.
  if (host.endsWith('.ts.net')) return true;

  // 100.64.0.0/10 — the CGNAT block Tailscale uses for node IPv4s. Strictly
  // four numeric octets; anything else (hostname, malformed) fails closed.
  final octets = host.split('.');
  if (octets.length == 4) {
    final a = int.tryParse(octets[0]);
    final b = int.tryParse(octets[1]);
    if (a == 100 && b != null && b >= 64 && b <= 127) return true;
  }

  // fd7a:115c:a1e0::/48 — textual prefix check. Dart's Uri.host keeps IPv6
  // literals bracket-stripped; the three prefix groups are non-zero, so "::"
  // elision can never replace them in any spelling of such an address.
  if (host.startsWith('fd7a:115c:a1e0:')) return true;

  return false;
}

/// Validates a candidate relay URL the user typed into Settings or
/// the onboarding form.
///
/// Rules:
/// - Non-empty.
/// - Scheme must be `http://` or `https://`. Returns `false` (with the
///   ws/wss-specific reason via [relayUrlValidationMessage]) for the
///   legacy `ws://` / `wss://` schemes — the app converts internally.
/// - Must be parseable by `Uri.parse` AND yield a non-empty `host`.
bool isValidRelayUrl(String url) {
  if (url.isEmpty) return false;
  if (url.startsWith('ws://') || url.startsWith('wss://')) {
    return false;
  }
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    return false;
  }
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return false;
  }
  if (uri.host.isEmpty) return false;
  return true;
}

/// Returns the user-facing rejection message for [url]. Returns `null`
/// when the URL is valid. Distinguishes the ws/wss case (specific
/// hint about internal conversion) from generic invalid scheme /
/// malformed input.
String? relayUrlValidationMessage(String url) {
  if (url.isEmpty) return kRelayUrlInvalidGeneric;
  if (url.startsWith('ws://') || url.startsWith('wss://')) {
    return kRelayUrlInvalidScheme;
  }
  if (isValidRelayUrl(url)) return null;
  return kRelayUrlInvalidGeneric;
}
