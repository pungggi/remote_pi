import 'package:app/data/device/reliability_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isTailscaleCgnat — plan 116', () {
    test('Tailscale CGNAT addresses (100.64.0.0/10) are detected', () {
      expect(isTailscaleCgnat('http://100.64.0.1:3000'), isTrue);
      expect(isTailscaleCgnat('http://100.75.161.17:3000'), isTrue);
      expect(isTailscaleCgnat('http://100.127.255.255:3000'), isTrue);
    });

    test('addresses outside the CGNAT range are NOT Tailscale', () {
      // 100.0–100.63 and 100.128+ are public, not CGNAT.
      expect(isTailscaleCgnat('http://100.63.255.255:3000'), isFalse);
      expect(isTailscaleCgnat('http://100.128.0.0:3000'), isFalse);
      // RFC1918 LAN is not Tailscale.
      expect(isTailscaleCgnat('http://192.168.1.10:3000'), isFalse);
      expect(isTailscaleCgnat('http://10.0.0.5:3000'), isFalse);
      // Hostnames are not CGNAT IPs.
      expect(isTailscaleCgnat('http://relay.example.com:3000'), isFalse);
    });

    test('empty / malformed URLs are safe (false)', () {
      expect(isTailscaleCgnat(''), isFalse);
      expect(isTailscaleCgnat('not a url'), isFalse);
    });

    test('non-IPv4 hosts in the 100.6x range are NOT Tailscale (review #2)', () {
      // Only octets 1–2 being in range must NOT be enough — all four
      // octets must be valid 0–255 integers.
      expect(isTailscaleCgnat('http://100.70.foo.bar'), isFalse);
      expect(isTailscaleCgnat('http://100.70.1'), isFalse);
      expect(isTailscaleCgnat('http://100.75.300.1'), isFalse); // octet > 255
      expect(isTailscaleCgnat('http://100.75.-1.1'), isFalse); // negative
    });

    test('scheme-agnostic: the host is what matters (http/https/ws/wss)', () {
      expect(isTailscaleCgnat('http://100.75.161.17:3000'), isTrue);
      expect(isTailscaleCgnat('https://100.75.161.17:3000'), isTrue);
    });
  });
}
