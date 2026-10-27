import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('provider_error room metadata', () {
    test('room_meta_updated parses true, false, and absent', () {
      RoomMetaUpdated parse(Map<String, dynamic> meta) {
        return ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'peer1',
          'room_id': 'r1',
          'meta': meta,
        })! as RoomMetaUpdated;
      }

      expect(parse({'provider_error': true}).providerError, isTrue);
      expect(parse({'provider_error': false}).providerError, isFalse);
      expect(parse({'working': true}).providerError, isNull);
    });

    test('room_announced reads flat and nested provider_error', () {
      final flat = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'peer1',
        'room_id': 'r1',
        'started_at': 1,
        'provider_error': true,
      })! as RoomAnnounced;
      final nested = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'peer1',
        'room_id': 'r1',
        'started_at': 1,
        'meta': {'provider_error': true},
      })! as RoomAnnounced;
      final legacy = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'peer1',
        'room_id': 'r1',
        'started_at': 1,
      })! as RoomAnnounced;

      expect(flat.providerError, isTrue);
      expect(nested.providerError, isTrue);
      expect(legacy.providerError, isNull);
    });

    test('RoomInfo defaults, round-trips, and copies providerError', () {
      final legacy = RoomInfo.fromJson({
        'room_id': 'r1',
        'started_at': 1,
      });
      const failed = RoomInfo(
        roomId: 'r1',
        startedAt: 1,
        providerError: true,
      );

      expect(legacy.providerError, isFalse);
      expect(failed.toJson()['provider_error'], isTrue);
      expect(RoomInfo.fromJson(failed.toJson()).providerError, isTrue);
      expect(failed.copyWith(model: 'gpt-4o').providerError, isTrue);
      expect(failed.copyWith(providerError: false).providerError, isFalse);
    });

    test('RoomInfo equality and hashCode include providerError', () {
      const failed = RoomInfo(
        roomId: 'r1',
        startedAt: 1,
        providerError: true,
      );
      const same = RoomInfo(
        roomId: 'r1',
        startedAt: 1,
        providerError: true,
      );
      const healthy = RoomInfo(roomId: 'r1', startedAt: 1);

      expect(failed, same);
      expect(failed.hashCode, same.hashCode);
      expect(failed, isNot(healthy));
    });
  });
}
