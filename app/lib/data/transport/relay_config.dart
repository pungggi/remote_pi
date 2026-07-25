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

/// Fallback relay, used only until a real one is known.
///
/// Plan/102 — Piper's default topology is a relay on the user's own machine,
/// reached over the WLAN. That address is per-network and handed out by DHCP,
/// so it cannot be a build-time constant: the phone learns it from the pairing
/// QR (`r`), which PairingViewModel adopts into Preferences.
///
/// This constant is what `resolveRelayUrl` returns before that happens — a
/// fresh install that has not paired yet, or a QR with no `r`. It points at
/// upstream's public relay, which still works for reaching a Pi from outside
/// the WLAN. Hardcoded rather than build-time configurable to keep the
/// onboarding flow deterministic.
const String kDefaultRelayUrl = 'https://relay-rp1.jacobmoura.work';

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

/// Returns the effective relay URL the app should connect to.
/// Falls back to [kDefaultRelayUrl] when no user override is set.
/// Always returns an `http(s)://` URL — caller is responsible for
/// applying [toWsRelayUrl] when opening a WebSocket.
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
