import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStore implements FlutterSecureStorage {
  final Map<String, String> _m = {};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _m[key];
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
      _m.remove(key);
    } else {
      _m[key] = value;
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
  }) async =>
      _m.remove(key);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  group('relay_config — isValidRelayUrl', () {
    test('accepts http:// and https:// with non-empty host', () {
      expect(isValidRelayUrl('http://localhost'), isTrue);
      expect(isValidRelayUrl('http://127.0.0.1:8080'), isTrue);
      expect(isValidRelayUrl('https://relay.example.com'), isTrue);
      // Overlay-network form (Tailscale hands out 100.64.0.0/10) — the shape
      // used to reach the relay from outside the WLAN.
      expect(isValidRelayUrl('http://100.100.100.100:3000'), isTrue);
    });

    test('rejects ws:// and wss:// — those are conversions only', () {
      expect(isValidRelayUrl('ws://localhost'), isFalse);
      expect(isValidRelayUrl('wss://relay.example.com'), isFalse);
    });

    test('rejects empty, unsupported schemes, missing host', () {
      expect(isValidRelayUrl(''), isFalse);
      expect(isValidRelayUrl('ftp://example.com'), isFalse);
      expect(isValidRelayUrl('foo'), isFalse);
      expect(isValidRelayUrl('https://'), isFalse,
          reason: 'no host segment');
      expect(isValidRelayUrl('http://'), isFalse,
          reason: 'no host segment');
    });
  });

  group('relay_config — relayUrlValidationMessage', () {
    test('returns null for valid http(s) URLs', () {
      expect(relayUrlValidationMessage('https://relay.example.com'), isNull);
      expect(relayUrlValidationMessage('http://localhost:3000'), isNull);
    });

    test('returns ws-specific hint for ws:// and wss://', () {
      final ws = relayUrlValidationMessage('ws://localhost');
      expect(ws, kRelayUrlInvalidScheme);
      expect(ws, contains('http://'));
      expect(ws, contains('ws://'));

      final wss = relayUrlValidationMessage('wss://relay.example.com');
      expect(wss, kRelayUrlInvalidScheme);
    });

    test('returns generic message for empty / malformed input', () {
      expect(relayUrlValidationMessage(''), kRelayUrlInvalidGeneric);
      expect(relayUrlValidationMessage('foo'), kRelayUrlInvalidGeneric);
      expect(relayUrlValidationMessage('ftp://x.com'), kRelayUrlInvalidGeneric);
      expect(relayUrlValidationMessage('https://'), kRelayUrlInvalidGeneric);
    });
  });

  group('relay_config — toWsRelayUrl', () {
    test('translates http(s) to ws(s)', () {
      expect(toWsRelayUrl('https://relay.example.com'),
          'wss://relay.example.com');
      expect(toWsRelayUrl('http://localhost:8080'),
          'ws://localhost:8080');
    });

    test('passes ws(s) through unchanged (legacy QR / PeerRecord)', () {
      expect(toWsRelayUrl('wss://relay.example.com'),
          'wss://relay.example.com');
      expect(toWsRelayUrl('ws://localhost'), 'ws://localhost');
    });
  });

  group('relay_config — resolveRelayUrl', () {
    test('returns prefs.relayUrl when set', () async {
      final p = Preferences(_FakeStore());
      await p.setRelayUrl('https://custom.example.com');
      expect(resolveRelayUrl(p), 'https://custom.example.com');
    });

    test('falls back to kDefaultRelayUrl when override is null', () async {
      final p = Preferences(_FakeStore());
      expect(p.relayUrl, isNull);
      expect(resolveRelayUrl(p), kDefaultRelayUrl);
    });

    test('there is no default relay — plan/102', () {
      // The fork operates no public relay and does not borrow the upstream
      // project's. Empty means "not configured"; the pairing QR supplies it.
      expect(kDefaultRelayUrl, isEmpty);
    });

    test('an unconfigured relay never passes as connectable', () {
      // The guard that keeps "" from being treated as a usable endpoint.
      expect(isValidRelayUrl(kDefaultRelayUrl), isFalse);
    });

    group('relayTransportIsSecure (security fix 2026-08)', () {
      test('https/wss are confidential', () {
        expect(relayTransportIsSecure('https://relay.example.com:3000'), isTrue);
        expect(relayTransportIsSecure('wss://relay.example.com'), isTrue);
      });

      test('ws/http to loopback is confidential (nothing to sniff)', () {
        expect(relayTransportIsSecure('http://127.0.0.1:3000'), isTrue);
        expect(relayTransportIsSecure('http://localhost:3000'), isTrue);
        expect(relayTransportIsSecure('ws://[::1]:3000'), isTrue);
      });

      test('the default LAN dial (RFC1918 ws://) is NOT confidential', () {
        expect(relayTransportIsSecure('http://192.168.1.10:3000'), isFalse);
        expect(relayTransportIsSecure('http://10.0.0.5:3000'), isFalse);
        expect(relayTransportIsSecure('http://172.16.0.2:3000'), isFalse);
      });

      test('tailnet dials (Tailscale CGNAT / MagicDNS / v6 ULA) are confidential', () {
        // Banner/overlay alignment (2026-08-31): the banner's advice — "use
        // https:// or an overlay (Tailscale) relay" — and the README's
        // documented remote setup both point at these dials; WireGuard
        // encrypts them regardless of the plaintext scheme.
        expect(relayTransportIsSecure('http://100.75.161.17:3000'), isTrue);
        expect(relayTransportIsSecure('http://100.64.0.1:3000'), isTrue,
            reason: 'strict literal at the range\u2019s low edge');
        expect(relayTransportIsSecure('http://100.100.100.100:3000'), isTrue);
        expect(
            relayTransportIsSecure('http://100.127.255.255:3000'), isTrue);
        expect(relayTransportIsSecure('http://chico.tail5d4821.ts.net'),
            isTrue);
        expect(relayTransportIsSecure('ws://[fd7a:115c:a1e0::4f37:a112]:3000'),
            isTrue);
      });

      test('CGNAT range boundaries hold (fail closed outside 100.64/10)', () {
        expect(relayTransportIsSecure('http://100.63.255.255:3000'), isFalse);
        expect(relayTransportIsSecure('http://100.128.0.0:3000'), isFalse);
        expect(relayTransportIsSecure('http://101.64.0.1:3000'), isFalse);
      });

      test('tailnet lookalikes are NOT confidential', () {
        // Registry apex, not a node name.
        expect(relayTransportIsSecure('http://ts.net:3000'), isFalse);
        // ts.net must be the SUFFIX, not a mid-name.
        expect(relayTransportIsSecure('http://evil.ts.net.example.com:3000'),
            isFalse);
        // Five octets is not an IPv4 literal.
        expect(relayTransportIsSecure('http://100.64.0.0.1:3000'), isFalse);
        // Non-numeric octets fail closed, not crash.
        expect(relayTransportIsSecure('http://100.abc.0.1:3000'), isFalse);
      });

      test('four-label DNS names posing as CGNAT are NOT confidential', () {
        // PR #60 review fix — the first cut validated only the first two
        // octets, so any 4-label hostname starting "100.64"–"100.127" was
        // misread as a tailnet IPv4 and the banner was suppressed.
        expect(relayTransportIsSecure('http://100.64.relay.evil:3000'), isFalse);
        expect(relayTransportIsSecure('http://100.64.1.attacker:3000'), isFalse);
        expect(
            relayTransportIsSecure('http://100.64.1.attacker.example:3000'),
            isFalse,
            reason: 'the reviewer\u2019s 5-label example — never reached the '
                'branch, kept as a regression guard');
        expect(relayTransportIsSecure('http://100.64.999.1:3000'), isFalse,
            reason: '999 is not a valid octet');
        expect(relayTransportIsSecure('http://100.64.1e2.1:3000'), isFalse,
            reason: 'int.tryParse("1e2") == 100 — exponent form is a DNS '
                'label here, not an octet');
        expect(relayTransportIsSecure('http://0100.64.0.1:3000'), isFalse,
            reason: 'leading-zero label is a hostname, not a strict literal');
      });

      test('garbage is classified insecure (fail closed)', () {
        expect(relayTransportIsSecure(''), isFalse);
        expect(relayTransportIsSecure('not a url'), isFalse);
      });
    });
  });
}
