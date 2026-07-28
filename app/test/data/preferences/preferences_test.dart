import 'package:app/data/preferences/preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  group('Preferences', () {
    test('defaults to hideToolCalls=false before load()', () {
      final p = Preferences(_FakeSecureStorage());
      expect(p.hideToolCalls, isFalse);
    });

    test('load() hydrates from storage', () async {
      final store = _FakeSecureStorage();
      await store.write(key: 'prefs.hide_tool_calls', value: 'true');
      final p = Preferences(store);
      await p.load();
      expect(p.hideToolCalls, isTrue);
    });

    test('setHideToolCalls writes to storage and notifies', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      var notifs = 0;
      p.addListener(() => notifs++);

      await p.setHideToolCalls(true);
      expect(p.hideToolCalls, isTrue);
      expect(await store.read(key: 'prefs.hide_tool_calls'), 'true');
      expect(notifs, 1);

      // No-op if value unchanged.
      await p.setHideToolCalls(true);
      expect(notifs, 1);

      await p.setHideToolCalls(false);
      expect(p.hideToolCalls, isFalse);
      expect(notifs, 2);
    });

    test('relayUrl defaults to null and round-trips via setRelayUrl',
        () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      expect(p.relayUrl, isNull);

      await p.setRelayUrl('wss://custom.example.com');
      expect(p.relayUrl, 'wss://custom.example.com');
      expect(await store.read(key: 'prefs.relay_url'),
          'wss://custom.example.com');

      // Reload from cold start → value survives.
      final p2 = Preferences(store);
      await p2.load();
      expect(p2.relayUrl, 'wss://custom.example.com');

      // Clearing sends null and removes the key.
      await p.setRelayUrl(null);
      expect(p.relayUrl, isNull);
      expect(await store.read(key: 'prefs.relay_url'), isNull);

      // Empty string also clears.
      await p.setRelayUrl('wss://x');
      await p.setRelayUrl('');
      expect(p.relayUrl, isNull);
    });

    test(
      'onboardingCompleted defaults to false and round-trips via '
      'setOnboardingCompleted',
      () async {
        final store = _FakeSecureStorage();
        final p = Preferences(store);
        expect(p.onboardingCompleted, isFalse);

        await p.setOnboardingCompleted(true);
        expect(p.onboardingCompleted, isTrue);
        expect(
          await store.read(key: 'prefs.onboarding_completed'),
          'true',
        );

        final p2 = Preferences(store);
        await p2.load();
        expect(p2.onboardingCompleted, isTrue);
      },
    );

    test('selectedRoom round-trips epk + roomId composite (plan 17)',
        () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      await p.setSelectedRoom(epk: 'abc123', roomId: 'room-xyz');
      expect(p.selectedPeerEpk, 'abc123');
      expect(p.selectedRoomId, 'room-xyz');
      expect(p.selectedRoomRaw, 'abc123:room-xyz');

      // Reload from cold → preserved
      final p2 = Preferences(store);
      await p2.load();
      expect(p2.selectedPeerEpk, 'abc123');
      expect(p2.selectedRoomId, 'room-xyz');
    });

    test(
      'backward-compat: legacy value (no `:room` suffix) returns epk '
      'and null roomId so caller defaults to "main"',
      () async {
        final store = _FakeSecureStorage();
        // Pre-populate with legacy format (just the epk, no suffix).
        await store.write(
          key: 'prefs.selected_peer_epk',
          value: 'legacy_epk',
        );
        final p = Preferences(store);
        await p.load();
        expect(p.selectedPeerEpk, 'legacy_epk');
        expect(p.selectedRoomId, isNull);
      },
    );

    test('setSelectedRoom with null epk clears the selection', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      await p.setSelectedRoom(epk: 'abc', roomId: 'r');
      expect(p.selectedPeerEpk, 'abc');
      await p.setSelectedRoom(epk: null);
      expect(p.selectedPeerEpk, isNull);
      expect(p.selectedRoomRaw, isNull);
    });

    // ── Plan 115 — LAN endpoints + last-good winner ─────────────────────
    group('plan 115 — lanEndpoints', () {
      test('defaults to empty before load()', () {
        expect(Preferences(_FakeSecureStorage()).lanEndpoints, isEmpty);
      });

      test('setLanEndpoints round-trips and survives cold start', () async {
        final store = _FakeSecureStorage();
        final p = Preferences(store);
        await p.setLanEndpoints([
          'http://192.168.1.10:3000',
          'http://10.0.0.5:3000',
        ]);
        expect(p.lanEndpoints, [
          'http://192.168.1.10:3000',
          'http://10.0.0.5:3000',
        ]);

        final p2 = Preferences(store);
        await p2.load();
        expect(p2.lanEndpoints, [
          'http://192.168.1.10:3000',
          'http://10.0.0.5:3000',
        ]);
      });

      test('setLanEndpoints dedupes + drops empties', () async {
        final p = Preferences(_FakeSecureStorage());
        await p.setLanEndpoints([
          'http://192.168.1.10:3000',
          'http://192.168.1.10:3000', // dup
          '',
          '   ',
          'http://10.0.0.5:3000',
        ]);
        expect(p.lanEndpoints, [
          'http://192.168.1.10:3000',
          'http://10.0.0.5:3000',
        ]);
      });

      test('setLanEndpoints([]) clears and removes the key', () async {
        final store = _FakeSecureStorage();
        final p = Preferences(store);
        await p.setLanEndpoints(['http://192.168.1.10:3000']);
        await p.setLanEndpoints(const []);
        expect(p.lanEndpoints, isEmpty);
        expect(await store.read(key: 'prefs.lan_endpoints'), isNull);
      });

      test('mergeLanEndpoints unions with existing, dedupes', () async {
        final p = Preferences(_FakeSecureStorage());
        await p.setLanEndpoints(['http://192.168.1.10:3000']);
        await p.mergeLanEndpoints([
          'http://192.168.1.10:3000', // already known
          'http://192.168.1.11:3000',
        ]);
        expect(p.lanEndpoints, [
          'http://192.168.1.10:3000',
          'http://192.168.1.11:3000',
        ]);
      });

      // Plan 115 review fix — merge must normalise dirty advertised input
      // the same way setLanEndpoints does, otherwise a whitespace-padded
      // URL sneaks in untrimmed and later fails to dedupe / connect.
      test('mergeLanEndpoints trims, drops empties, and dedupes dirty input',
          () async {
        final p = Preferences(_FakeSecureStorage());
        await p.setLanEndpoints(['http://192.168.1.10:3000']);
        await p.mergeLanEndpoints([
          '  http://192.168.1.10:3000  ', // dirty dup of existing
          '   ', // whitespace-only → dropped
          '', // empty → dropped
          ' http://192.168.1.11:3000 ', // dirty new → trimmed, kept
        ]);
        expect(p.lanEndpoints, [
          'http://192.168.1.10:3000',
          'http://192.168.1.11:3000',
        ]);
      });

      test('mergeLanEndpoints is a no-op when nothing new', () async {
        final store = _FakeSecureStorage();
        final p = Preferences(store);
        var notifs = 0;
        p.addListener(() => notifs++);
        await p.setLanEndpoints(['http://192.168.1.10:3000']);
        notifs = 0;
        await p.mergeLanEndpoints(['http://192.168.1.10:3000']);
        expect(notifs, 0); // no change → no notification
      });

      test('corrupt persisted blob hydrates as empty (never blocks boot)',
          () async {
        final store = _FakeSecureStorage();
        await store.write(key: 'prefs.lan_endpoints', value: 'not-json{');
        final p = Preferences(store);
        await p.load();
        expect(p.lanEndpoints, isEmpty);
      });
    });

    group('plan 115 — lastGoodRelayUrl', () {
      test('defaults to null and round-trips WITHOUT notifying', () async {
        final store = _FakeSecureStorage();
        final p = Preferences(store);
        var notifs = 0;
        p.addListener(() => notifs++);
        expect(p.lastGoodRelayUrl, isNull);

        await p.setLastGoodRelayUrl('http://192.168.1.10:3000');
        expect(p.lastGoodRelayUrl, 'http://192.168.1.10:3000');
        expect(notifs, 0); // internal bookkeeping → no UI rebuild

        final p2 = Preferences(store);
        await p2.load();
        expect(p2.lastGoodRelayUrl, 'http://192.168.1.10:3000');
      });

      test('clearing sends null and removes the key', () async {
        final store = _FakeSecureStorage();
        final p = Preferences(store);
        await p.setLastGoodRelayUrl('http://192.168.1.10:3000');
        await p.setLastGoodRelayUrl(null);
        expect(p.lastGoodRelayUrl, isNull);
        expect(await store.read(key: 'prefs.last_good_relay_url'), isNull);
      });
    });

    group('collapseToolCalls', () {
      test('defaults to true before load()', () {
        final p = Preferences(_FakeSecureStorage());
        expect(p.collapseToolCalls, isTrue);
      });

      test('load() hydrates from storage', () async {
        final store = _FakeSecureStorage();
        await store.write(
            key: 'prefs.collapse_tool_calls', value: 'false');
        final p = Preferences(store);
        await p.load();
        expect(p.collapseToolCalls, isFalse);
      });

      test('load() defaults to true when key is absent', () async {
        final p = Preferences(_FakeSecureStorage());
        await p.load();
        expect(p.collapseToolCalls, isTrue);
      });

      test('setCollapseToolCalls writes to storage and notifies', () async {
        final store = _FakeSecureStorage();
        final p = Preferences(store);
        var notifs = 0;
        p.addListener(() => notifs++);

        await p.setCollapseToolCalls(false);
        expect(p.collapseToolCalls, isFalse);
        expect(
            await store.read(key: 'prefs.collapse_tool_calls'), 'false');
        expect(notifs, 1);
      });
    });
  });
}
