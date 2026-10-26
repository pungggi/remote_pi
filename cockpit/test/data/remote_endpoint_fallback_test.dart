import 'package:cockpit/app/cockpit/data/remote/host_shell/host_shell.dart';
import 'package:cockpit/app/cockpit/data/remote/remote_host_connector.dart';
import 'package:flutter_test/flutter_test.dart';

const _unix = UnixSocketEndpoint('/home/u/.cockpit/server.sock');
const _tcp = TcpEndpoint(port: 4242, token: 'secret');

void main() {
  group('connectWithEndpointFallback (#260)', () {
    test(
      'successful initial transport does not re-read the endpoint',
      () async {
        final service = Object();
        var reads = 0;
        var calls = 0;

        final result = await connectWithEndpointFallback<Object>(
          endpoint: _unix,
          readEndpoint: () async {
            reads++;
            return _tcp;
          },
          connect: (endpoint, attempts) async {
            calls++;
            return service;
          },
        );

        expect(result, same(service));
        expect(calls, 1);
        expect(reads, 0);
      },
    );

    test('failed Unix attempt retries once with announced TCP', () async {
      final service = Object();
      final attempted = <RemoteEndpoint>[];
      final attemptCounts = <int>[];
      var reads = 0;

      final result = await connectWithEndpointFallback<Object>(
        endpoint: _unix,
        attempts: 20,
        readEndpoint: () async {
          reads++;
          return _tcp;
        },
        connect: (endpoint, attempts) async {
          attempted.add(endpoint);
          attemptCounts.add(attempts);
          return endpoint is TcpEndpoint ? service : null;
        },
      );

      expect(result, same(service));
      expect(attempted, hasLength(2));
      expect(attempted[0], same(_unix));
      expect(attempted[1], same(_tcp));
      expect(attemptCounts, [20, 20]);
      expect(reads, 1);
    });

    test(
      'same transport on re-read does not trigger another attempt',
      () async {
        var calls = 0;
        var reads = 0;

        final result = await connectWithEndpointFallback<Object>(
          endpoint: _unix,
          readEndpoint: () async {
            reads++;
            return const UnixSocketEndpoint('/home/u/.cockpit/replaced.sock');
          },
          connect: (endpoint, attempts) async {
            calls++;
            return null;
          },
        );

        expect(result, isNull);
        expect(calls, 1);
        expect(reads, 1);
      },
    );

    test('failed alternate transport is not retried again', () async {
      var calls = 0;
      var reads = 0;

      final result = await connectWithEndpointFallback<Object>(
        endpoint: _unix,
        readEndpoint: () async {
          reads++;
          return _tcp;
        },
        connect: (endpoint, attempts) async {
          calls++;
          return null;
        },
      );

      expect(result, isNull);
      expect(calls, 2);
      expect(reads, 1);
    });
  });
}
