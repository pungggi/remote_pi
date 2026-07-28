// Plan 115 — unit tests for the endpoint model + pure selection logic.
//
// The connect-time wiring (real connectivity probe + real WS dial) is
// verified on device; these tests cover the deterministic ordering,
// classification, last-good bias, and cellular-skip that the factory
// delegates to.
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/relay_endpoint.dart';
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
  group('isTailscaleCgnatHost', () {
    test('matches the 100.64.0.0/10 CGNAT range', () {
      expect(isTailscaleCgnatHost('100.64.0.1'), isTrue);
      expect(isTailscaleCgnatHost('100.127.255.255'), isTrue);
      expect(isTailscaleCgnatHost('100.75.161.17'), isTrue);
    });
    test('rejects hosts outside the range', () {
      expect(isTailscaleCgnatHost('100.63.255.255'), isFalse); // just below
      expect(isTailscaleCgnatHost('100.128.0.0'), isFalse); // just above
      expect(isTailscaleCgnatHost('192.168.1.10'), isFalse);
      expect(isTailscaleCgnatHost('10.0.0.1'), isFalse);
      expect(isTailscaleCgnatHost('relay.example.com'), isFalse);
      expect(isTailscaleCgnatHost('not-an-ip'), isFalse);
    });
  });

  group('classifyEndpointKind', () {
    test('tailscale for CGNAT hosts, manual otherwise', () {
      expect(classifyEndpointKind('http://100.75.161.17:3000'),
          EndpointKind.tailscale);
      expect(classifyEndpointKind('http://192.168.1.10:3000'),
          EndpointKind.manual);
      expect(classifyEndpointKind('https://relay.example.com'),
          EndpointKind.manual);
    });
  });

  group('resolveRelayEndpoints', () {
    test('LAN candidates come first, then the primary', () async {
      final p = Preferences(_FakeStore());
      await p.setRelayUrl('http://100.75.161.17:3000'); // tailscale
      await p.setLanEndpoints(['http://192.168.1.10:3000']);

      final out = resolveRelayEndpoints(p);
      expect(out.map((e) => e.kind), [
        EndpointKind.lan,
        EndpointKind.tailscale,
      ]);
      expect(out.first.url, 'http://192.168.1.10:3000');
      expect(out.last.url, 'http://100.75.161.17:3000');
    });

    test('dedupes a LAN entry equal to the primary', () async {
      final p = Preferences(_FakeStore());
      await p.setRelayUrl('http://192.168.1.10:3000');
      await p.setLanEndpoints(['http://192.168.1.10:3000']);

      final out = resolveRelayEndpoints(p);
      // LAN wins the dedup; the primary is dropped (same URL).
      expect(out, hasLength(1));
      expect(out.single.kind, EndpointKind.lan);
    });

    test('empty when nothing configured', () async {
      final p = Preferences(_FakeStore());
      expect(resolveRelayEndpoints(p), isEmpty);
    });

    test('primary alone still yields one candidate (manual)', () async {
      final p = Preferences(_FakeStore());
      await p.setRelayUrl('https://relay.example.com');
      final out = resolveRelayEndpoints(p);
      expect(out, hasLength(1));
      expect(out.single.kind, EndpointKind.manual);
    });
  });

  group('selectEndpointOrder', () {
      final lan = RelayEndpoint(
        url: 'http://192.168.1.10:3000',
        kind: EndpointKind.lan,
      );
      final ts = RelayEndpoint(
        url: 'http://100.75.161.17:3000',
        kind: EndpointKind.tailscale,
      );
      final manual = RelayEndpoint(
        url: 'https://relay.example.com',
        kind: EndpointKind.manual,
      );
      final base = [lan, ts, manual];

    test('keeps preference order when no last-good', () {
      expect(selectEndpointOrder(base), base);
    });

    test('moves last-good to the front, keeps the rest in order', () {
      final out = selectEndpointOrder(base, lastGood: ts.url);
      expect(out.first, ts);
      expect(out.sublist(1), [lan, manual]);
    });

    test('no-op when last-good not in the list', () {
      final out =
          selectEndpointOrder(base, lastGood: 'http://10.0.0.99:3000');
      expect(out, base);
    });

    test('no-op when last-good already first', () {
      final out = selectEndpointOrder(base, lastGood: lan.url);
      expect(out, base);
    });

    test('skipLan drops every lan endpoint', () {
      final out = selectEndpointOrder(base, skipLan: true);
      expect(out, [ts, manual]);
      expect(out.any((e) => e.kind == EndpointKind.lan), isFalse);
    });

    test('skipLan + last-good compose: winner first, lan gone', () {
      // last-good is the tailscale entry; LAN dropped; manual remains.
      final out =
          selectEndpointOrder(base, lastGood: ts.url, skipLan: true);
      expect(out, [ts, manual]);
    });

    test('skipLan on a LAN-only list yields empty (falls to primary)', () {
      // Mirrors the cellular case where only LAN candidates exist but the
      // primary is empty — the factory's endpoints list would be empty and
      // it throws "not configured". Here we just assert the skip behavior.
      expect(selectEndpointOrder([lan], skipLan: true), isEmpty);
    });
  });

  // Single-endpoint migration smoke test: a peer paired before plan 115 has
  // only a primary relayUrl and no LAN list. It must still resolve to one
  // connectable endpoint (the DoD "legacy peer still works" criterion at the
  // preferences layer).
  test('legacy single-endpoint record still resolves one endpoint', () async {
    final p = Preferences(_FakeStore());
    await p.setRelayUrl('http://100.75.161.17:3000');
    expect(p.lanEndpoints, isEmpty);
    final out = resolveRelayEndpoints(p);
    expect(out, hasLength(1));
    expect(out.single.url, 'http://100.75.161.17:3000');
    expect(out.single.kind, EndpointKind.tailscale);
  });
}
