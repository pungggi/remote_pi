import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/settings/states/settings_state.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoopTransport implements PeerTransport {
  @override Future<void> send(Uint8List data) async {}
  @override Future<Uint8List> receive() => Completer<Uint8List>().future;
  @override Future<void> close() async {}
}

PlainPeerChannel _channel() => PlainPeerChannel(transport: _NoopTransport());

ConnectionManager _conn({_FakeStorage? storage}) {
  return ConnectionManager(
    factory: (_, _) async => _channel(),
    storage: storage ?? _FakeStorage([]),
  );
}

class _FakeStorage extends PairingStorage {
  List<PeerRecord> peers;
  final Map<String, List<PersistedRoom>> _roomsByEpk = {};
  _FakeStorage(this.peers);

  @override
  Future<List<PeerRecord>> listPeers() async => List.of(peers);

  @override
  Future<void> savePeer(PeerRecord r) async {
    peers = [r, ...peers.where((p) => p.remoteEpk != r.remoteEpk)];
  }

  @override
  Future<void> deletePeer(String epk) async {
    peers = peers.where((p) => p.remoteEpk != epk).toList();
  }

  @override
  Future<void> deletePeerSilent(String epk) async {
    peers = peers.where((p) => p.remoteEpk != epk).toList();
  }

  // Plan 115 — room-cache stubs so ConnectionManager.boot() (now exercised by
  // the clearLanUrl reconnect test) never reaches the real FlutterSecureStorage
  // platform channel. Mirrors the fake in connection_manager_test.dart.
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {
    _roomsByEpk[epk] = List.of(rooms);
  }

  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async =>
      List.of(_roomsByEpk[epk] ?? const []);

  @override
  Future<void> deleteRooms(String epk) async {
    _roomsByEpk.remove(epk);
  }
}

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
  }) async => _store.remove(key);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

PeerRecord _peerA() => const PeerRecord(
  remoteEpk: 'epk_A',
  sessionName: 'Pi A',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);

void main() {
  group('SettingsViewModel', () {
    test('initial state is SettingsLoading', () {
      final storage = _FakeStorage([_peerA()]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      expect(vm.state, isA<SettingsLoading>());
      vm.dispose();
    });

    test('empty storage → SettingsNoPeer', () async {
      final storage = _FakeStorage([]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, isA<SettingsNoPeer>());
      vm.dispose();
    });

    test('peers loaded → SettingsList', () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      final s = vm.state as SettingsList;
      expect(s.peers.single.remoteEpk, 'epk_A');

      vm.dispose();
    });

    test('revoke deletes peer + clears selectedPeerEpk if it matched',
        () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = Preferences(_FakeSecureStorage());
      await prefs.setSelectedPeerEpk('epk_A');

      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.revoke('epk_A');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(storage.peers, isEmpty);
      expect(prefs.selectedPeerEpk, isNull);
      expect(vm.state, isA<SettingsNoPeer>());

      vm.dispose();
    });

    test('revoke does NOT touch selectedPeerEpk if different', () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = Preferences(_FakeSecureStorage());
      await prefs.setSelectedPeerEpk('epk_other');

      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.revoke('epk_A');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(prefs.selectedPeerEpk, 'epk_other');

      vm.dispose();
    });

    test('setNickname updates state and storage', () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.setNickname('epk_A', 'Casa');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final s = vm.state as SettingsList;
      expect(s.peers.single.nickname, 'Casa');
      expect(storage.peers.single.nickname, 'Casa');

      vm.dispose();
    });

    test('setNickname with null clears the nickname', () async {
      final storage = _FakeStorage([
        _peerA().copyWith(nickname: 'Casa'),
      ]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.setNickname('epk_A', null);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect((vm.state as SettingsList).peers.single.nickname, isNull);
      expect(storage.peers.single.nickname, isNull);

      vm.dispose();
    });

    test('setNickname with whitespace clears the nickname', () async {
      final storage = _FakeStorage([
        _peerA().copyWith(nickname: 'Casa'),
      ]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.setNickname('epk_A', '   ');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect((vm.state as SettingsList).peers.single.nickname, isNull);

      vm.dispose();
    });

    test('setNickname is a no-op for unknown epk', () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.setNickname('epk_does_not_exist', 'Casa');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(storage.peers.single.nickname, isNull);

      vm.dispose();
    });
  });

  group('SettingsViewModel — plan 14 relay config', () {
    test('saveRelayUrl with valid URL persists override + returns null',
        () async {
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
      await Future<void>.delayed(Duration.zero);

      final err = await vm.saveRelayUrl('https://custom.example');
      expect(err, isNull);
      expect(prefs.relayUrl, 'https://custom.example');
      expect(vm.effectiveRelayUrl, 'https://custom.example');

      vm.dispose();
    });

    test(
      'saveRelayUrl with invalid URL returns error and does NOT persist',
      () async {
        final prefs = Preferences(_FakeSecureStorage());
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);

        final err = await vm.saveRelayUrl('not-a-url');
        expect(err, isNotNull);
        expect(prefs.relayUrl, isNull);

        vm.dispose();
      },
    );

    test('saveRelayUrl rejects ws:// / wss:// with the scheme-specific hint',
        () async {
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
      await Future<void>.delayed(Duration.zero);

      final err = await vm.saveRelayUrl('wss://relay.example');
      expect(err, isNotNull);
      expect(err, contains('ws://'));
      expect(err, contains('http://'));
      expect(prefs.relayUrl, isNull);

      vm.dispose();
    });

    test(
      'saveRelayUrl with empty / null is rejected (URL is now required) and '
      'does NOT clear the existing override',
      () async {
        final prefs = Preferences(_FakeSecureStorage());
        await prefs.setRelayUrl('https://x.example');
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);

        // Empty → error, override untouched.
        final emptyErr = await vm.saveRelayUrl('');
        expect(emptyErr, isNotNull);
        expect(prefs.relayUrl, 'https://x.example');

        // Whitespace-only → same (trimmed to empty).
        final blankErr = await vm.saveRelayUrl('   ');
        expect(blankErr, isNotNull);
        expect(prefs.relayUrl, 'https://x.example');

        // null → same.
        final nullErr = await vm.saveRelayUrl(null);
        expect(nullErr, isNotNull);
        expect(prefs.relayUrl, 'https://x.example');

        vm.dispose();
      },
    );

    test(
      'relayUrlOverride is empty until something sets a relay — plan/102',
      () async {
        final prefs = Preferences(_FakeSecureStorage());
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);

        // No override and no default to fall back on: the field starts blank
        // and the app has nowhere to connect until pairing supplies a relay.
        expect(vm.relayUrlOverride, isEmpty);
        expect(vm.effectiveRelayUrl, isEmpty);

        vm.dispose();
      },
    );

    test('saving an empty relay is rejected, not silently accepted', () async {
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
      await Future<void>.delayed(Duration.zero);

      expect(await vm.saveRelayUrl(''), isNotNull);
      expect(await vm.saveRelayUrl('   '), isNotNull);
      expect(prefs.relayUrl, isNull);

      vm.dispose();
    });

    test('clearRelayUrl drops the stored relay (WLAN changed)', () async {
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
      await Future<void>.delayed(Duration.zero);

      expect(await vm.saveRelayUrl('http://192.168.0.67:3000'), isNull);
      expect(prefs.relayUrl, 'http://192.168.0.67:3000');

      await vm.clearRelayUrl();

      expect(prefs.relayUrl, isNull);
      expect(vm.relayUrlOverride, isEmpty);

      vm.dispose();
    });

    // ── Plan 115 — LAN endpoint field ────────────────────────────────
    group('plan 115 — lanUrl', () {
      test('lanUrlOverride is empty until a LAN endpoint is set', () async {
        final prefs = Preferences(_FakeSecureStorage());
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);
        expect(vm.lanUrlOverride, isEmpty);
        vm.dispose();
      });

      test('saveLanUrl with a valid URL persists it as the single LAN '
          'candidate', () async {
        final prefs = Preferences(_FakeSecureStorage());
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);

        expect(await vm.saveLanUrl('http://192.168.1.10:3000'), isNull);
        expect(prefs.lanEndpoints, ['http://192.168.1.10:3000']);
        expect(vm.lanUrlOverride, 'http://192.168.1.10:3000');
        vm.dispose();
      });

      test('saveLanUrl with an invalid URL returns an error and does '
          'NOT persist', () async {
        final prefs = Preferences(_FakeSecureStorage());
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);

        expect(await vm.saveLanUrl('ws://192.168.1.10:3000'), isNotNull);
        expect(prefs.lanEndpoints, isEmpty);
        vm.dispose();
      });

      test('saveLanUrl with blank clears the LAN list (opt out)', () async {
        final prefs = Preferences(_FakeSecureStorage());
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);

        await vm.saveLanUrl('http://192.168.1.10:3000');
        expect(prefs.lanEndpoints, isNotEmpty);

        expect(await vm.saveLanUrl('  '), isNull);
        expect(prefs.lanEndpoints, isEmpty);
        expect(vm.lanUrlOverride, isEmpty);
        vm.dispose();
      });

      test('clearLanUrl empties the LAN candidate list', () async {
        final prefs = Preferences(_FakeSecureStorage());
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);

        await vm.saveLanUrl('http://192.168.1.10:3000');
        await vm.clearLanUrl();
        expect(prefs.lanEndpoints, isEmpty);
        vm.dispose();
      });

      // Plan 115 review fix — Clear must rebuild the connection so the
      // change takes effect now (the active link may be on a LAN endpoint
      // that is no longer a candidate). Mirrors saveLanUrl.
      test('clearLanUrl rebuilds the connection so it takes effect now',
          () async {
        final states = <ConnectionStatus>[];
        final storage = _FakeStorage([_peerA()]);
        final conn = _conn(storage: storage);
        conn.statusStream.listen(states.add);
        final prefs = Preferences(_FakeSecureStorage());
        await prefs.setLanEndpoints(['http://192.168.1.10:3000']);
        final vm = SettingsViewModel(storage, prefs, conn);
        await Future<void>.delayed(Duration.zero);

        // Bring the connection up so the reconnect is observable.
        await conn.boot();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(conn.status, isA<StatusOnline>());

        await vm.clearLanUrl();
        // boot() is fire-and-forget in clearLanUrl; let its emissions settle.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // disconnect() → StatusNoPeer, boot() → StatusConnecting then Online.
        expect(states.any((s) => s is StatusNoPeer), isTrue);
        expect(states.any((s) => s is StatusConnecting), isTrue);
        expect(prefs.lanEndpoints, isEmpty);

        vm.dispose();
        conn.dispose();
      });
    });
  });
}
