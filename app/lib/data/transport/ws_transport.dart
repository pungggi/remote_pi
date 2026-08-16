// WebSocket-based PeerTransport.
//
// Flow per connection:
//   1. Connect to relay WS
//   2. Ed25519 challenge-response (hello → challenge → auth)
//   3. After auth, two parallel streams of inbound frames:
//        - envelope frames `{peer, ct}` → decoded to the peer queue
//        - control frames (top-level `type`, no `peer`) → control stream
//      Outbound `subscribe_presence` / `presence_check` go raw too.
//
// `peer` is standard base64 of the destination's Ed25519 pubkey (matches
// the relay registry, populated from the peer's hello). `ct` is base64 of
// the inner-envelope bytes (plain JSON post-rollback, see plano 06).

import 'dart:async';
import 'dart:convert';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../pairing/pair_request_flow.dart';

/// Security fix 2026-08 — inner-envelope signature domain. MUST match
/// `DOMAIN_PREFIX` in pi-extension `src/transport/inner_sig.ts`.
const String kInnerSigDomain = 'piper/inner/v1\n';

/// v2 domain (PR #24 follow-up) — binds the RECIPIENT pubkey and a timestamp
/// into the signed bytes: `piper/inner/v2\n<dest>\n<ts>\n<ct>`. Kills the
/// cross-Pi redirect (a frame signed for Pi A fails on Pi B) and bounds
/// replay to [kInnerSigMaxAgeMs]. MUST match `DOMAIN_PREFIX_V2` on the
/// pi-extension side.
const String kInnerSigDomainV2 = 'piper/inner/v2\n';

/// Replay freshness window for v2 signatures — MUST match `MAX_AGE_MS` in
/// pi-extension `src/transport/inner_sig.ts` (10 minutes; generous for phone
/// ↔ PC clock skew, short enough that a captured frame is useless later).
const int kInnerSigMaxAgeMs = 10 * 60 * 1000;

class WsTransportError implements Exception {
  final String message;
  const WsTransportError(this.message);

  @override
  String toString() => 'WsTransportError: $message';
}

class WsTransport implements PeerTransport, IControlLink, ITransportSecurityInfo {
  final WebSocketChannel _ws;
  final _queue = _MsgQueue();
  final _controlController =
      StreamController<ControlInbound>.broadcast();

  /// This device's Ed25519 key — signs the WS challenge AND every outbound
  /// inner envelope (security fix 2026-08).
  late final SimpleKeyPair _ed25519Key;

  /// Canonical http(s) relay URL we dialed — drives [isTransportSecure].
  late final String _relayUrl;

  /// Inbound-signature ratchet: flips true on the first VERIFIED Pi
  /// signature (or from the persisted [PeerRecord.signing] at connect).
  /// Once true, unsigned inbound frames are dropped — a malicious relay
  /// can no longer strip signatures to impersonate the Pi.
  bool _requireSignature = false;
  /// True once the ratchet flip has been PERSISTED via [_onPeerRatcheted]
  /// (fires on the first VALID signature; invalid present-sigs flip only
  /// the in-memory flag, matching the relay's strip-frame power exactly).
  bool _ratchetPersisted = false;
  void Function()? _onPeerRatcheted;

  WsTransport._(this._ws);

  // Connect, authenticate with relay, and return a ready transport.
  static Future<WsTransport> connect({
    required String relayUrl,
    required String peerPubkey, // base64 standard or url — destination peer
    required SimpleKeyPair ed25519Key, // this device's Ed25519 long-term key
    bool peerSigningRequired = false, // security fix 2026-08 — ratchet seed
    void Function()? onPeerRatcheted, // ...and persistence hook
  }) async {
    // Plan-18 follow-up — a WS-level pingInterval (RFC 6455 control
    // frames) keeps the TCP connection alive through NAT / corporate
    // proxies and surfaces a dead WS as `onDone` / `onError`. The
    // protocol-level Ping/Pong handled by ConnectionManager covers
    // app↔Pi liveness; this one covers app↔relay TCP liveness.
    //
    // Plan 125 — this is a BACKSTOP, not the primary keepalive. The
    // relay itself pings inbound every ~60 s (peer.rs heartbeat) and
    // `ws` auto-replies Pong, which already keeps NAT mappings alive
    // in both directions; the inbound-liveness watchdog in
    // ConnectionManager (_kInboundTimeout, checked every 30 s) is the
    // PRIMARY dead-socket detector. So the client-side ping can be
    // slow: 240 s beats every common NAT idle timeout (consumer routers
    // ≥ 60 s, Cloudflare WSS ~100 s, corporate LBs 2–5 min) as a
    // last-resort backstop, and removes a redundant outbound radio
    // wakeup every 20 s.
    // Accept http(s) URLs in the user-facing form but always speak
    // ws(s) on the wire — IOWebSocketChannel rejects http schemes.
    final WebSocketChannel ws = IOWebSocketChannel.connect(
      Uri.parse(toWsRelayUrl(relayUrl)),
      pingInterval: const Duration(seconds: 240), // plan 125 — was 20s (backstop only)
    );
    final transport = WsTransport._(ws);

    final challengeCompleter = Completer<Map<String, dynamic>>();
    bool authDone = false;

    // Perf fix (2026-08-16): frames are processed in PARALLEL again — the
    // serialized chain made every inbound frame wait for the previous
    // frame's Ed25519 verify and froze the UI during agent-chunk bursts.
    // The review-#4 ratchet race stays closed because the flag is flipped
    // SYNCHRONOUSLY (before the awaited verify) inside processFrame, so any
    // later frame in the same microtask queue already sees it flipped.
    Future<void> processFrame(dynamic raw) async {
        // Volume probe removed (perf 2026-08-16): per-frame debugPrint
        // flooded the debug console (~200 frames/10s) and caused jank.
        if (!authDone) {
          try {
            challengeCompleter.complete(
              jsonDecode(raw as String) as Map<String, dynamic>,
            );
          } catch (e) {
            if (!challengeCompleter.isCompleted) {
              challengeCompleter.completeError(e);
            }
          }
          return;
        }
        try {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          // Envelope: {peer, room?, ct, sig?} → enqueue payload bytes.
          if (frame.containsKey('peer') && frame.containsKey('ct')) {
            final ct = frame['ct'] as String;
            final bytes = _b64Decode(ct);
            final senderRoom = frame['room'] as String?;
            // Plan-18 follow-up — DEMUX inbound by sender room.
            // SessionRepository is singleton; without this guard,
            // AgentChunks for a chat the user just left bleed into
            // the chat they're now viewing. When senderRoom doesn't
            // match the currently-addressed Pi cwd, drop the payload.
            // Legacy Pis without `room` route unconditionally.
            if (senderRoom != null && senderRoom != transport._activeRoom) {
              return; // room-mismatch — drop silently (perf)
            }
            // Security fix 2026-08 + PR #25 follow-up — dual-sig verification.
            //   sig2 present → strict v2 (dest + ts window); invalid → drop,
            //                           NO v1 fallback (legit senders sign both).
            //   sig only    → v1 transition, unless the Pi is v2-ratcheted
            //                           (downgrade strip → drop).
            //   both absent → drop once ratcheted (relay strip).
            // The unsigned-drop ratchet flips SYNCHRONOUSLY on sig presence
            // (serialized chain closes the async-gap race, review #4/#24).
            final sigRaw = frame['sig'];
            final sig2Raw = frame['sig2'];
            final tsRaw = frame['ts'];
            final hasSig2 = sig2Raw is String && sig2Raw.isNotEmpty;
            final hasSig = sigRaw is String && sigRaw.isNotEmpty;
            if (hasSig2 || hasSig) {
              transport._requireSignature = true;
              if (!await transport._verifyInboundEnvelope(
                ct,
                hasSig ? sigRaw : '',
                hasSig2 ? sig2Raw : null,
                tsRaw,
              )) {
                debugPrint('[ws-in] sig=INVALID DROPPED');
                return;
              }
              if (!transport._ratchetPersisted) {
                transport._ratchetPersisted = true;
                try {
                  transport._onPeerRatcheted?.call();
                } catch (_) {/* persistence hook is best-effort */}
              }
            } else if (transport._requireSignature) {
              debugPrint('[ws-in] sig=ABSENT-after-ratchet DROPPED');
              return;
            }
            transport._queue.add(bytes);
            return;
          }
          // Control: top-level `type` only → presence stream.
          final ctrl = ControlInbound.tryFromJson(frame);
          if (ctrl != null && !transport._controlController.isClosed) {
            transport._controlController.add(ctrl);
            return;
          }
          // Anything else: unknown shape — drop silently.
          // unknown shape — drop silently
        } catch (e) {
          debugPrint('[ws-in] malformed DROPPED err=$e');
        }
    } // processFrame

    final sub = ws.stream.listen((raw) {
      // Perf fix (2026-08-16): parallel per-frame processing — no global
      // serialization; race-safety via the synchronous ratchet flip
      // inside processFrame (see comment above).
      unawaited(processFrame(raw));
    },
      onError: (e) {
        if (!challengeCompleter.isCompleted) challengeCompleter.completeError(e);
        transport._queue.error(e);
      },
      onDone: () {
        if (!challengeCompleter.isCompleted) {
          challengeCompleter.completeError(const WsTransportError('WS closed during auth'));
        }
        transport._queue.close();
        if (!transport._controlController.isClosed) {
          transport._controlController.close();
        }
      },
    );

    try {
      // 1. Hello (standard base64 — matches relay registry format).
      // Plan 17: app is a client (no cwd) and always announces itself
      // on the canonical 'main' room. Pi-side hellos include their own
      // room_id (one per cwd) AND room_meta; that's not our concern here.
      final pub = await ed25519Key.extractPublicKey();
      ws.sink.add(jsonEncode({
        'type': 'hello',
        'pubkey': base64.encode(pub.bytes),
        'room_id': 'main',
      }));

      // 2. Challenge
      final ch = await challengeCompleter.future;
      if (ch['type'] != 'challenge') {
        throw WsTransportError('Expected challenge, got ${ch['type']}');
      }
      final nonce = _b64Decode(ch['nonce'] as String);

      // Plan 115 — the relay may advertise its local LAN IPv4 candidates
      // (`lan: ["http://192.168.1.10:3000", ...]`) so the app can bypass
      // Tailscale on the home VLAN. Old relays omit the field → empty
      // list, which is a no-op for the caller. Captured here (the only
      // place the raw challenge frame is visible) and surfaced via
      // [advertisedLanUrls] for the connection factory to persist.
      final lanRaw = ch['lan'];
      if (lanRaw is List) {
        transport._advertisedLanUrls = lanRaw
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .toList(growable: false);
      }

      // 3. Auth
      final sig = await Ed25519().sign(nonce, keyPair: ed25519Key);
      ws.sink.add(jsonEncode({
        'type': 'auth',
        'sig': base64.encode(sig.bytes),
      }));
      authDone = true;

      transport._peerPubkey = _normalizeToStandard(peerPubkey);
      transport._ed25519Key = ed25519Key;
      transport._relayUrl = relayUrl;
      transport._requireSignature = peerSigningRequired;
      transport._onPeerRatcheted = onPeerRatcheted;
      transport._sub = sub;
      return transport;
    } catch (e) {
      await sub.cancel();
      await ws.sink.close();
      rethrow;
    }
  }

  String _peerPubkey = '';
  StreamSubscription? _sub;

  /// Plan 115 — LAN candidate URLs the relay advertised in its challenge
  /// frame (empty when the relay is older than plan 115 or has no usable
  /// LAN address). Populated during [connect]; read by the connection
  /// factory to persist into `Preferences.lanEndpoints`.
  List<String> _advertisedLanUrls = const [];
  List<String> get advertisedLanUrls => _advertisedLanUrls;

  /// Active target room on the Pi side. Plan 17: set via
  /// `setActiveRoom`, defaults to 'main' when unset. The outer envelope
  /// embeds this so the Pi can route the inner message to the right
  /// per-cwd session.
  String _activeRoom = 'main';

  /// Override the destination room (Pi side). The app remains on the
  /// 'main' room itself (that's what we sent in `hello.room_id`).
  void setActiveRoom(String room) {
    if (room == _activeRoom) {
      return;
    }
    _activeRoom = room;
  }

  @override
  Future<void> send(Uint8List data) async {
    final ct = base64.encode(data);
    // Security fix 2026-08 (dual-sign, PR #25 review #1) — every outbound
    // frame carries BOTH signatures with the device key (same key as the WS
    // handshake):
    //   sig  — v1, sender-bound: keeps pre-#25 Pis verifying (they only read
    //          `sig`; a v2-only scheme breaks the mixed rollout).
    //   sig2 — v2, dest-bound + ts-windowed: kills cross-Pi redirect + replay
    //          for upgraded recipients.
    final ts = DateTime.now().millisecondsSinceEpoch;
    final algo = Ed25519();
    final sigV1 = await algo.sign(
      utf8.encode('$kInnerSigDomain$ct'),
      keyPair: _ed25519Key,
    );
    final sigV2 = await algo.sign(
      utf8.encode('$kInnerSigDomainV2$_peerPubkey\n$ts\n$ct'),
      keyPair: _ed25519Key,
    );
    _ws.sink.add(jsonEncode({
      'peer': _peerPubkey,
      'room': _activeRoom,
      'ct': ct,
      'sig': base64.encode(sigV1.bytes),
      'sig2': base64.encode(sigV2.bytes),
      'ts': ts,
    }));
  }

  /// Verifies an inbound envelope's `sig` over `ct` against the PAIRED Pi's
  /// pubkey (which the relay asserts in `peer` — and which we dialed).
  /// v2 (`ts` present): dest-bound + freshness window. v1 (no ts): legacy
  /// sender-bound transition path. Never throws — any parse/decode failure
  /// is an invalid signature.
  /// True once the paired Pi demonstrated v2 (a verified `sig2`). v1-only
  /// frames from such a peer are a relay downgrade strip → dropped.
  bool _piV2 = false;

  /// Dual-sig inbound verification (PR #25 review #1):
  ///   sig2 present → STRICT v2 (dest binding + ts window); invalid → drop,
  ///                 never v1 fallback (legit senders sign both).
  ///   sig only    → v1 transition path, unless the Pi is v2-ratcheted
  ///                 (downgrade strip → drop).
  /// Never throws — any parse/decode failure is an invalid signature.
  Future<bool> _verifyInboundEnvelope(
    String ct,
    String sigB64,
    String? sig2B64,
    Object? tsRaw,
  ) async {
    try {
      final pk = SimplePublicKey(_b64Decode(_peerPubkey), type: KeyPairType.ed25519);
      final algo = Ed25519();
      if (sig2B64 != null && sig2B64.isNotEmpty) {
        if (tsRaw is! num || tsRaw.toInt() != tsRaw) return false;
        final ts = tsRaw.toInt();
        final now = DateTime.now().millisecondsSinceEpoch;
        if ((now - ts).abs() > kInnerSigMaxAgeMs) return false; // stale replay
        final ok = await algo.verify(
          utf8.encode('$kInnerSigDomainV2$_peerPubkey\n$ts\n$ct'),
          signature: Signature(_b64Decode(sig2B64), publicKey: pk),
        );
        if (ok) _piV2 = true; // mark BEFORE returning — next v1-only = strip
        return ok;
      }
      if (_piV2) return false; // v1-only from a v2-capable Pi — downgrade strip
      return await algo.verify(
        utf8.encode('$kInnerSigDomain$ct'),
        signature: Signature(_b64Decode(sigB64), publicKey: pk),
      );
    } catch (_) {
      return false;
    }
  }

  /// Security fix 2026-08 (H2) — true when this transport is confidential:
  /// `wss://`/`https://` (TLS) or a loopback host (nothing to sniff off-path).
  /// Drives the persistent insecure-transport banner on Home.
  @override
  bool get isTransportSecure => relayTransportIsSecure(_relayUrl);

  @override
  Future<Uint8List> receive() => _queue.next();

  // ---- IControlLink --------------------------------------------------------

  @override
  Stream<ControlInbound> get controlFrames => _controlController.stream;

  @override
  void sendControl(Map<String, dynamic> json) {
    _ws.sink.add(jsonEncode(json));
  }

  // -------------------------------------------------------------------------

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await _ws.sink.close();
    _queue.close();
    if (!_controlController.isClosed) await _controlController.close();
  }
}

// ---------------------------------------------------------------------------

class _MsgQueue {
  final _buf = <Uint8List>[];
  final _waiters = <Completer<Uint8List>>[];
  bool _closed = false;

  void add(Uint8List msg) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(msg);
    } else if (!_closed) {
      _buf.add(msg);
    }
  }

  void error(Object e) {
    for (final w in _waiters) {
      w.completeError(e);
    }
    _waiters.clear();
    _closed = true;
  }

  void close() {
    for (final w in _waiters) {
      w.completeError(const WsTransportError('transport closed'));
    }
    _waiters.clear();
    _closed = true;
  }

  Future<Uint8List> next() {
    if (_closed) return Future.error(const WsTransportError('transport closed'));
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future;
  }
}

// Decodes standard or url-safe base64 (pads defensively).
Uint8List _b64Decode(String s) {
  final pad = (4 - s.length % 4) % 4;
  final padded = s + '=' * pad;
  try {
    return base64.decode(padded);
  } on FormatException {
    return base64Url.decode(padded);
  }
}

// Relay registry uses standard base64 (from each peer's hello). QR/storage
// may carry url-safe encoding — re-encode to standard so the relay matches.
String _normalizeToStandard(String pubkey) {
  try {
    final pad = (4 - pubkey.length % 4) % 4;
    final bytes = base64Url.decode(pubkey + '=' * pad);
    return base64.encode(bytes);
  } catch (_) {
    return pubkey;
  }
}
