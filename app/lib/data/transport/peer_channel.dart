// PlainPeerChannel — protocol message channel without E2E cipher.
//
// Wraps a connected PeerTransport. After pairing, use this to exchange
// ClientMessage / ServerMessage with the Pi extension.
//
//   send(ClientMessage)   → JSON          → transport.send()
//   serverMessages stream ← transport.receive() → JSON → ServerMessage

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/transport/channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/protocol/codec.dart';
// ControlInbound + IControlLink come from these.
import 'package:app/protocol/protocol.dart';

class PeerChannelError implements Exception {
  final String message;
  const PeerChannelError(this.message);

  @override
  String toString() => 'PeerChannelError: $message';
}

class PlainPeerChannel implements IChannel, IControlLink, ITransportSecurityInfo {
  final PeerTransport _transport;

  final _controller = StreamController<ServerMessage>.broadcast();
  bool _started = false;
  bool _closed = false;

  PlainPeerChannel({required PeerTransport transport}) : _transport = transport;

  // ---- IControlLink — forwards to the underlying transport when it
  //      supports raw control frames (production: WsTransport). For
  //      non-WS transports (tests / in-memory), returns an empty stream
  //      and silently drops outbound control frames.
  @override
  Stream<ControlInbound> get controlFrames {
    final t = _transport;
    if (t is IControlLink) return (t as IControlLink).controlFrames;
    return const Stream.empty();
  }

  @override
  void sendControl(Map<String, dynamic> json) {
    final t = _transport;
    if (t is IControlLink) (t as IControlLink).sendControl(json);
  }

  /// Plan 17 — propagate the active Pi-side room to the underlying
  /// transport so subsequent `send`s carry the right outer `room` field.
  /// No-op when the transport doesn't support it (in-memory test fakes).
  void setActiveRoom(String roomId) {
    final t = _transport;
    try {
      (t as dynamic).setActiveRoom(roomId);
    } catch (_) {
      // Non-WS transports don't track rooms — fine to ignore.
    }
  }

  /// Security fix 2026-08 (H2) — forwards transport confidentiality when
  /// the underlying transport knows it; non-WS test transports default to
  /// secure (no banner in tests).
  @override
  bool get isTransportSecure {
    final t = _transport;
    if (t is ITransportSecurityInfo) {
      return (t as ITransportSecurityInfo).isTransportSecure;
    }
    return true;
  }

  @override
  Stream<ServerMessage> get serverMessages {
    if (!_started) {
      _started = true;
      _receiveLoop();
    }
    return _controller.stream;
  }

  @override
  Future<void> send(ClientMessage msg) async {
    final bytes = Uint8List.fromList(utf8.encode(encodeClient(msg).trimRight()));
    await _transport.send(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _transport.close();
    if (!_controller.isClosed) await _controller.close();
  }

  Future<void> _receiveLoop() async {
    try {
      while (!_closed) {
        final bytes = await _transport.receive();
        _handleFrame(bytes);
      }
    } catch (_) {
      if (!_controller.isClosed) await _controller.close();
    }
  }

  /// Replay defense (PR #24 follow-up #1): bounded LRU of delivered inner
  /// message ids. A replayed frame — even one inside the v2 freshness
  /// window — carries an already-seen id and is dropped. Ids are
  /// client-generated UUIDs, never legitimately reused. Map preserves
  /// insertion order; evict oldest past the cap.
  static const int _seenIdsCap = 2048;
  final _seenIds = <String>{};

  bool _seenBefore(dynamic id) {
    if (id is! String || id.isEmpty) return false;
    if (_seenIds.contains(id)) return true;
    if (_seenIds.length >= _seenIdsCap) {
      _seenIds.remove(_seenIds.first);
    }
    _seenIds.add(id);
    return false;
  }

  void _handleFrame(Uint8List bytes) {
    try {
      final msg = decodeServer(utf8.decode(bytes));
      if (_seenBefore((msg as dynamic).id)) {
        // Replayed server frame — drop before it corrupts UI state
        // (duplicate agent_chunks, duplicate echoes).
        return;
      }
      if (!_controller.isClosed) _controller.add(msg);
    } on UnsupportedTypeException {
      // Forward-compat: surface unknown server types as ErrorMessage.
      if (!_controller.isClosed) {
        _controller.add(
          ErrorMessage(code: 'unsupported_type', message: 'unknown server type'),
        );
      }
    } catch (_) {
      // Malformed frame — drop silently. Previous diagnostic logging
      // for cast / decode errors lived here; we trust upstream codecs
      // now that the channel pipeline is stable.
    }
  }
}
