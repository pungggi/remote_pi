// Plan/161 — the provider slug rides room_meta end-to-end so the Home list
// can group sessions by provider. Pins the wire parse (announce + patch) and
// the merge conventions (absent = preserve) mirroring rooms_provider_error_test.
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('provider room metadata (plan/161)', () {
    test('room_meta_updated parses set and absent', () {
      RoomMetaUpdated parse(Map<String, dynamic> meta) {
        return ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'peer1',
          'room_id': 'r1',
          'meta': meta,
        })! as RoomMetaUpdated;
      }

      final set = parse({'model': 'GLM 4.7', 'provider': 'zai'});
      expect(set.provider, 'zai');
      expect(set.hasProvider, isTrue);

      final absent = parse({'working': true});
      expect(absent.provider, isNull);
      expect(absent.hasProvider, isFalse,
          reason: 'absent key must preserve, not clear');
    });

    test('room_announced reads flat and nested provider', () {
      final flat = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'peer1',
        'room_id': 'r1',
        'started_at': 1,
        'model': 'GLM 4.7',
        'provider': 'zai',
      })! as RoomAnnounced;
      final nested = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'peer1',
        'room_id': 'r1',
        'started_at': 1,
        'meta': {'provider': 'zai'},
      })! as RoomAnnounced;
      final legacy = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'peer1',
        'room_id': 'r1',
        'started_at': 1,
      })! as RoomAnnounced;

      expect(flat.provider, 'zai');
      expect(nested.provider, 'zai');
      expect(legacy.provider, isNull);
    });

    test('RoomInfo round-trips the provider slug', () {
      final room = RoomInfo.fromJson({
        'room_id': 'r1',
        'started_at': 1,
        'model': 'GLM 4.7',
        'provider': 'zai',
      });
      expect(room.provider, 'zai');
      expect(room.toJson()['provider'], 'zai');
      expect(room.copyWith(model: 'GLM 4.6').provider, 'zai',
          reason: 'copyWith without provider keeps it');
      expect(
        const RoomInfo(roomId: 'r1', startedAt: 1).toJson().containsKey('provider'),
        isFalse,
        reason: 'null provider omits the key (legacy caches stay valid)',
      );
    });
  });
}
