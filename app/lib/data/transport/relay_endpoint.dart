// Plan 115 — dual relay addressing (LAN + Tailscale/manual).
//
// The relay binds 0.0.0.0, so the *same* process is reachable both on the
// home LAN (e.g. http://192.168.1.10:3000) and over an overlay such as
// Tailscale (http://100.75.161.17:3000). At home we want to bypass the
// overlay entirely — it is the flaky layer on Android. So the app learns a
// *list* of endpoints for the one relay and dials them in preference order
// (LAN first) with failover.
//
// ── Where endpoints live ──────────────────────────────────────────────
// Plan 14 globalised the relay URL into `Preferences` (one relay for the
// whole app; `peer.relayUrl` is legacy and no longer consulted when
// opening a connection). Plan 115's prose still described per-peer
// endpoints, but that would reintroduce the per-peer relay model plan 14
// removed — so endpoints live GLOBALLY in `Preferences` too:
//
//   - `prefs.relayUrl`        → the user's primary URL (what they paired
//                               with — usually the Tailscale/overlay one,
//                               or a LAN one). Always the final fallback.
//   - `prefs.lanEndpoints`    → LAN candidate URLs learned from the relay
//                               advertisement (and editable in Settings).
//   - `prefs.lastGoodRelayUrl`→ the endpoint that last succeeded; the next
//                               connect starts from it (preference bias).
//
// `resolveRelayEndpoints` merges those into the ordered candidate list;
// `selectEndpointOrder` is the pure connect-time reordering (last-good
// first + cellular-skip) and is fully unit-tested.

import 'package:app/data/preferences/preferences.dart';

/// How an endpoint was learned / its dial preference.
///
/// Preference order for dialling: `lan` (fastest, home VLAN) before
/// `tailscale` (overlay, works off-network) before `manual` (a user-typed
/// fallback). `tailscale` vs `manual` is derived from the host: a host in
/// the Tailscale CGNAT range (100.64.0.0/10) is classified `tailscale`;
/// anything else the user typed is `manual`.
enum EndpointKind { lan, tailscale, manual }

/// One dialable address for the relay, tagged with how it was learned.
class RelayEndpoint {
  final String url;
  final EndpointKind kind;

  const RelayEndpoint({required this.url, required this.kind});

  @override
  bool operator ==(Object other) =>
      other is RelayEndpoint && other.url == url && other.kind == kind;

  @override
  int get hashCode => Object.hash(url, kind);

  @override
  String toString() => 'RelayEndpoint($url, $kind)';
}

/// True when [host] is a raw IPv4 in the Tailscale CGNAT range
/// `100.64.0.0/10` (i.e. `100.64.0.0` – `100.127.255.255`). Tailscale
/// assigns client IPs from this block, so a primary relay URL whose host
/// lands here is almost certainly the overlay address.
bool isTailscaleCgnatHost(String host) {
  // Strip a bracketed IPv6 host or a zone id defensively — only IPv4 is
  // relevant here, and anything non-IPv4 simply is not Tailscale CGNAT.
  final h = host.replaceAll('[', '').replaceAll(']', '');
  final parts = h.split('.');
  if (parts.length != 4) return false;
  final first = int.tryParse(parts[0]);
  final second = int.tryParse(parts[1]);
  if (first == null || second == null) return false;
  return first == 100 && second >= 64 && second <= 127;
}

/// Classifies a user/primary URL by inspecting its host. A Tailscale CGNAT
/// host → [EndpointKind.tailscale]; otherwise → [EndpointKind.manual].
/// (LAN endpoints are tagged `lan` at the point they enter the list, not
/// here — this only disambiguates the single primary URL.)
EndpointKind classifyEndpointKind(String url) {
  String host;
  try {
    host = Uri.parse(url).host;
  } catch (_) {
    return EndpointKind.manual;
  }
  return isTailscaleCgnatHost(host)
      ? EndpointKind.tailscale
      : EndpointKind.manual;
}

/// Builds the ordered candidate endpoint list from global preferences.
///
/// Order (preference): LAN candidates first, then the primary user URL.
/// De-duplicated by URL (case-sensitive — relay URLs are not
/// normalised here; the transport applies [toWsRelayUrl] later). The
/// primary URL is always present (when set) so there is a guaranteed
/// fallback even if the LAN list is empty. Returns an empty list when
/// nothing is configured (caller treats that as "not configured").
List<RelayEndpoint> resolveRelayEndpoints(Preferences prefs) {
  final out = <RelayEndpoint>[];
  final seen = <String>{};
  for (final url in prefs.lanEndpoints) {
    if (url.isEmpty || !seen.add(url)) continue;
    out.add(RelayEndpoint(url: url, kind: EndpointKind.lan));
  }
  final primary = prefs.relayUrl;
  if (primary != null && primary.isNotEmpty && seen.add(primary)) {
    out.add(RelayEndpoint(url: primary, kind: classifyEndpointKind(primary)));
  }
  return out;
}

/// Pure connect-time reordering of the candidate list.
///
/// - [lastGood]: when non-null and matching an endpoint's URL, that
///   endpoint is moved to the front (preference bias — the endpoint that
///   just worked is tried first, then we fall through the rest in
///   preference order).
/// - [skipLan]: when true, every `lan` endpoint is dropped entirely. Used
///   on cellular, where a home-LAN address is unroutable and would just
///   burn the short connect timeout before failing.
///
/// Pure (no I/O) so the ordering + skip logic is unit-testable without a
/// device or a fake transport.
List<RelayEndpoint> selectEndpointOrder(
  List<RelayEndpoint> endpoints, {
  String? lastGood,
  bool skipLan = false,
}) {
  var filtered =
      skipLan ? endpoints.where((e) => e.kind != EndpointKind.lan).toList()
              : List<RelayEndpoint>.of(endpoints);
  if (lastGood == null || lastGood.isEmpty) return filtered;
  final i = filtered.indexWhere((e) => e.url == lastGood);
  if (i <= 0) return filtered; // not present, or already first
  final winner = filtered.removeAt(i);
  filtered.insert(0, winner);
  return filtered;
}
