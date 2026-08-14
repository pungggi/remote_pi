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

    final sub = ws.stream.listen(
      (raw) async {
        // Volume probe: log every frame the relay pushes onto this
        // socket so we can spot firehose patterns (e.g. presence
        // churn, repeated room snapshots) by counting prefix
        // occurrences — body kept compact so the log stays grep-able
        // even when the relay is chatty.
        final rawStr = raw is String ? raw : raw.toString();
        if (!authDone) {
          debugPrint('[ws-in] bytes=${rawStr.length} stage=preauth');
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
              debugPrint(
                '[ws-in] bytes=${rawStr.length} kind=envelope '
                'sender_room=$senderRoom DROPPED (room-mismatch)',
              );
              return;
            }
            debugPrint(
              '[ws-in] bytes=${rawStr.length} kind=envelope '
              'ct.bytes=${bytes.length}',
            );
            // Security fix 2026-08 — end-to-end sender verification against
            // the paired Pi's pubkey. Present+invalid → ALWAYS drop (the
            // relay forwarding a tampered/foreign-signed frame). Absent → drop
            // only once the Pi has demonstrated signing (ratchet).
            final sigRaw = frame['sig'];
            if (sigRaw is String && sigRaw.isNotEmpty) {
              if (!await transport._verifyInboundSig(ct, sigRaw)) {
                debugPrint(
                  '[ws-in] bytes=${rawStr.length} kind=envelope '
                  'sig=INVALID DROPPED',
                );
                return;
              }
              if (!transport._requireSignature) {
                transport._requireSignature = true;
                try {
                  transport._onPeerRatcheted?.call();
                } catch (_) {/* persistence hook is best-effort */}
              }
            } else if (transport._requireSignature) {
              debugPrint(
                '[ws-in] bytes=${rawStr.length} kind=envelope '
                'sig=ABSENT-after-ratchet DROPPED',
              );
              return;
            }
            transport._queue.add(bytes);
            return;
          }
          // Control: top-level `type` only → presence stream.
          final ctrl = ControlInbound.tryFromJson(frame);
          if (ctrl != null && !transport._controlController.isClosed) {
            debugPrint(
              '[ws-in] bytes=${rawStr.length} kind=control '
              'type=${frame['type']}',
            );
            transport._controlController.add(ctrl);
            return;
          }
          // Anything else: unknown shape — drop silently.
          debugPrint('[ws-in] bytes=${rawStr.length} kind=unknown DROPPED');
        } catch (e) {
          debugPrint(
            '[ws-in] bytes=${rawStr.length} kind=malformed DROPPED err=$e',
          );
        }
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
    // Security fix 2026-08 — sign the exact ct string with the device key
    // (same key as the WS handshake) so the Pi can verify end-to-end sender
    // authenticity instead of trusting the relay-asserted `peer` field.
    final sig = await Ed25519().sign(
      utf8.encode('$kInnerSigDomain$ct'),
      keyPair: _ed25519Key,
    );
    _ws.sink.add(jsonEncode({
      'peer': _peerPubkey,
      'room': _activeRoom,
      'ct': ct,
      'sig': base64.encode(sig.bytes),
    }));
  }

  /// Verifies an inbound `sig` over `ct` against the PAIRED Pi's pubkey
  /// (which the relay asserts in `peer` — and which we dialed).
  Future<bool> _verifyInboundSig(String ct, String sigB64) async {
    try {
      final pkBytes = _b64Decode(_peerPubkey);
      final pk = SimplePublicKey(pkBytes, type: KeyPairType.ed25519);
      return await Ed25519().verify(
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
