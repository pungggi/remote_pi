import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/transport/epk_encoding.dart';

const maxUnifiedPushCleartextBytes = 3993;

enum PushEventType {
  validate('push_validate'),
  runStarted('run_started'),
  runFinished('run_finished'),
  runDone('run_done'),
  waitingStarted('waiting_started'),
  waitingCleared('waiting_cleared');

  const PushEventType(this.wire);
  final String wire;

  static PushEventType? fromWire(String value) {
    for (final type in values) {
      if (type.wire == value) return type;
    }
    return null;
  }
}

class PushPayload {
  const PushPayload({
    required this.event,
    required this.eventId,
    required this.occurredAtMs,
    this.peer,
    this.roomId,
    this.endedAtMs,
    this.registrationId,
    this.token,
  });

  final PushEventType event;
  final String eventId;
  final int occurredAtMs;
  final String? peer;
  final String? roomId;
  final int? endedAtMs;
  final String? registrationId;
  final String? token;

  static const _wakeKeys = {
    'v',
    'event',
    'event_id',
    'peer',
    'room',
    'occurred_at',
    'ended_at',
  };
  static const _validationKeys = {
    'v',
    'event',
    'event_id',
    'registration_id',
    'token',
    'occurred_at',
  };

  /// Strict, bounded parsing for already-decrypted connector bytes.
  /// Returns null for malformed, oversized, unknown or unauthorized input.
  static PushPayload? tryParse(
    Uint8List bytes, {
    required Set<String> allowedPeers,
  }) {
    if (bytes.isEmpty || bytes.length > maxUnifiedPushCleartextBytes) {
      return null;
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map<String, dynamic> || decoded['v'] != 1) return null;
      final event = PushEventType.fromWire(decoded['event'] as String? ?? '');
      if (event == null) return null;
      final allowedKeys = event == PushEventType.validate
          ? _validationKeys
          : _wakeKeys;
      if (decoded.keys.any((key) => !allowedKeys.contains(key))) return null;
      final eventId = _opaque(decoded['event_id'], 128);
      final occurredAt = decoded['occurred_at'];
      if (eventId == null || occurredAt is! int || occurredAt <= 0) {
        return null;
      }
      if (event == PushEventType.validate) {
        final registrationId = _opaque(decoded['registration_id'], 128);
        final token = _opaque(decoded['token'], 256);
        if (registrationId == null || token == null) return null;
        return PushPayload(
          event: event,
          eventId: eventId,
          occurredAtMs: occurredAt,
          registrationId: registrationId,
          token: token,
        );
      }
      final rawPeer = decoded['peer'];
      final room = _opaque(decoded['room'], 128);
      if (rawPeer is! String || room == null) return null;
      final peer = toStandardB64(rawPeer);
      if (!_isEd25519Key(peer) || !allowedPeers.contains(peer)) return null;
      final endedAt = decoded['ended_at'];
      if (endedAt != null && (endedAt is! int || endedAt <= 0)) return null;
      return PushPayload(
        event: event,
        eventId: eventId,
        occurredAtMs: occurredAt,
        peer: peer,
        roomId: room,
        endedAtMs: event == PushEventType.runDone
            ? (endedAt as int? ?? occurredAt)
            : null,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static String? _opaque(Object? value, int maxLength) {
    if (value is! String || value.isEmpty || value.length > maxLength) {
      return null;
    }
    if (value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return null;
    }
    return value;
  }

  static bool _isEd25519Key(String value) {
    try {
      return base64.decode(value).length == 32;
    } on FormatException {
      return false;
    }
  }
}
