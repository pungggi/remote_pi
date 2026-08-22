// PlainPeerChannel — protocol message channel without E2E cipher.
//
// Wraps a connected PeerTransport. After pairing, use this to exchange
// ClientMessage / ServerMessage with the Pi extension.
//
//   send(ClientMessage)   → JSON          → transport.send()
//   serverMessages stream ← transport.receive() → JSON → ServerMessage

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:app/data/transport/channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/protocol/codec.dart';

import 'package:flutter/foundation.dart';
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

  /// Replay defense (PR #24/#25 reviews): ids already delivered are replayed
  /// frames — drop. STATIC so the cache survives channel re-creation on
  /// reconnect (review #3/#25 — a fresh channel must not forget replayed
  /// ids). Bounded FIFO; ids are UUIDs, never legitimately reused.
  static const int _seenIdsCap = 4096;
  static final Queue<String> _seenIds = Queue<String>();
  static final Set<String> _seenIdsSet = <String>{};

  bool _seenBefore(dynamic id) {
    // Only String ids participate (action replies correlate via in_reply_to
    // and carry no id — see _handleFrame). null/absent → never a replay.
    if (id is! String || id.isEmpty) return false;
    if (_seenIdsSet.contains(id)) return true;
    if (_seenIds.length >= _seenIdsCap) {
      final oldest = _seenIds.removeFirst();
      _seenIdsSet.remove(oldest);
    }
    _seenIds.add(id);
    _seenIdsSet.add(id);
    return false;
  }

  void _handleFrame(Uint8List bytes) {
    try {
      final msg = decodeServer(utf8.decode(bytes));
      // Replay dedup (PR #24/#25). BUG 2026-08-20: the old code read
      // `(msg as dynamic).id` directly — action replies (ListProjectsResult,
      // GitStatusResult, OpenTerminalResult, Pong, …) have NO `id` field
      // (they correlate via `in_reply_to`), so the dynamic access threw
      // NoSuchMethodError into the generic catch and the reply was SILENTLY
      // DROPPED — every remote action timed out (Projects "Device
      // unreachable"). Only messages that actually carry a String id
      // participate in dedup; anything else delivers.
      //
      // BUG 2026-08-22 (ask_user stuck sheet): the pi-ask bridge's contract
      // reuses the REQUEST's id (the flowId) on its dismiss/warning NOTIFY
      // frames — same id, different message. The request is delivered first,
      // so the notify hit this LRU and was dropped as a "replay", leaving the
      // ask sheet spinning forever (no error either — warnings share the id).
      // extension_ui_request frames therefore bypass the dedupe here.
      //
      // PR #49 review: this exemption deliberately covers the INTERACTIVE
      // methods too, not just notify — the bridge re-sends still-PENDING
      // requests with the SAME id on every session_sync (chat re-entry
      // catch-up, plan/100), and this channel cannot tell that legit replay
      // apart from a post-completion duplicate (both share the id); dropping
      // replays here would strand the sheet of a still-open flow. The stale
      // case (a duplicate of an already-RESOLVED flow) is dropped one layer
      // up: SyncService tracks resolved ids (it observes the completing
      // notify) and refuses to resurrect them.
      if (msg is! ExtensionUiRequest) {
        Object? id;
        try {
          id = (msg as dynamic).id;
        } on NoSuchMethodError {
          id = null;
        }
        if (_seenBefore(id)) {
          // Replayed server frame — drop before it corrupts UI state
          // (duplicate agent_chunks, duplicate echoes).
          return;
        }
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
