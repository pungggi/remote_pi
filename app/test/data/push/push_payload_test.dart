import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/push/push_payload.dart';
import 'package:flutter_test/flutter_test.dart';

final _peer = base64.encode(List<int>.generate(32, (i) => i + 1));

Uint8List _bytes(Map<String, dynamic> value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Map<String, dynamic> _wake([String? event]) => {
  'v': 1,
  'event': event ?? 'run_started',
  'event_id': 'event-1',
  'peer': _peer,
  'room': 'main',
  'occurred_at': 1790000000000,
};

void main() {
  test('parses a bounded authorized wake payload', () {
    final payload = PushPayload.tryParse(
      _bytes(_wake()),
      allowedPeers: {_peer},
    );
    expect(payload, isNotNull);
    expect(payload!.event, PushEventType.runStarted);
    expect(payload.peer, _peer);
    expect(payload.roomId, 'main');
  });

  test('run_done carries or derives its dedupe timestamp', () {
    final withEnd = _wake('run_done')..['ended_at'] = 1790000000123;
    final payload = PushPayload.tryParse(
      _bytes(withEnd),
      allowedPeers: {_peer},
    );
    expect(payload!.endedAtMs, 1790000000123);
    final derived = PushPayload.tryParse(
      _bytes(_wake('run_done')),
      allowedPeers: {_peer},
    );
    expect(derived!.endedAtMs, 1790000000000);
  });

  test('validation token has a separate strict schema', () {
    final payload = PushPayload.tryParse(
      _bytes({
        'v': 1,
        'event': 'push_validate',
        'event_id': 'validation-1',
        'registration_id': 'registration-1',
        'token': 'short-lived-token',
        'occurred_at': 1790000000000,
      }),
      allowedPeers: const {},
    );
    expect(payload, isNotNull);
    expect(payload!.registrationId, 'registration-1');
    expect(payload.token, 'short-lived-token');
  });

  test('drops unauthorized peers and unexpected content fields', () {
    expect(
      PushPayload.tryParse(_bytes(_wake()), allowedPeers: const {}),
      isNull,
    );
    final withPrompt = _wake()..['prompt'] = 'must never travel by push';
    expect(
      PushPayload.tryParse(_bytes(withPrompt), allowedPeers: {_peer}),
      isNull,
    );
  });

  test('drops invalid version, room, event and oversized payloads', () {
    expect(
      PushPayload.tryParse(_bytes(_wake()..['v'] = 2), allowedPeers: {_peer}),
      isNull,
    );
    expect(
      PushPayload.tryParse(
        _bytes(_wake()..['room'] = ''),
        allowedPeers: {_peer},
      ),
      isNull,
    );
    expect(
      PushPayload.tryParse(_bytes(_wake('unknown')), allowedPeers: {_peer}),
      isNull,
    );
    expect(
      PushPayload.tryParse(
        Uint8List(maxUnifiedPushCleartextBytes + 1),
        allowedPeers: {_peer},
      ),
      isNull,
    );
  });
}
