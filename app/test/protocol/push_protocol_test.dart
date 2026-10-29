import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('push registration frame preserves the agreed relay contract', () {
    final frame = pushRegisterFrame(
      registrationId: 'registration',
      deviceId: 'android-registration',
      endpoint: 'https://push.example/endpoint',
      p256dh: 'p256dh',
      auth: 'auth',
      temporary: true,
      peers: const ['peer-a'],
      completionRooms: const [(peer: 'peer-a', room: 'main')],
    );
    expect(frame['type'], 'push_register');
    expect(frame['temporary'], isTrue);
    expect(frame['completion_rooms'], [
      {'peer': 'peer-a', 'room': 'main'},
    ]);
  });

  test('push responses parse with version-tolerant ControlInbound', () {
    final config = ControlInbound.tryFromJson({
      'type': 'push_config',
      'enabled': true,
      'vapid_public_key': 'public-key',
    });
    expect(config, isA<PushConfig>());
    expect((config as PushConfig).vapidPublicKey, 'public-key');

    final error = ControlInbound.tryFromJson({
      'type': 'push_error',
      'code': 'invalid_endpoint',
      'message': 'Endpoint rejected',
    });
    expect(error, isA<PushError>());
    expect((error as PushError).code, 'invalid_endpoint');
  });
}
