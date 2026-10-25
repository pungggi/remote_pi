import 'package:cockpit/app/cockpit/data/remote/host_shell/host_shell.dart';
import 'package:cockpit/app/cockpit/data/remote/ssh_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SshTunnel forwarding plan (#260)', () {
    for (final isWindows in [false, true]) {
      test('TCP remote uses matching local TCP on '
          '${isWindows ? 'Windows' : 'POSIX'}', () async {
        final plan = await SshTunnel.forwardPlan(
          remote: const TcpEndpoint(port: 4242, token: 'secret'),
          isWindows: isWindows,
        );

        expect(plan.useTcp, isTrue);
        expect(plan.localPath, isEmpty);
        expect(plan.localPort, isNotNull);
        expect(plan.argument, '127.0.0.1:${plan.localPort}:127.0.0.1:4242');
      });
    }

    test('POSIX keeps Unix-to-Unix forwarding for a Unix endpoint', () async {
      final plan = await SshTunnel.forwardPlan(
        remote: const UnixSocketEndpoint('/home/u/.cockpit/server.sock'),
        isWindows: false,
      );

      expect(plan.useTcp, isFalse);
      expect(plan.localPort, isNull);
      expect(plan.localPath, endsWith('.sock'));
      expect(plan.argument, '${plan.localPath}:/home/u/.cockpit/server.sock');
    });

    test('Windows uses local TCP with a Unix remote destination', () async {
      final plan = await SshTunnel.forwardPlan(
        remote: const UnixSocketEndpoint('/home/u/.cockpit/server.sock'),
        isWindows: true,
      );

      expect(plan.useTcp, isTrue);
      expect(plan.localPath, isEmpty);
      expect(plan.localPort, isNotNull);
      expect(
        plan.argument,
        '127.0.0.1:${plan.localPort}:/home/u/.cockpit/server.sock',
      );
    });
  });
}
