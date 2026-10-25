import 'dart:io';

import 'package:cockpit/app/cockpit/data/remote/host_shell/host_shell.dart';
import 'package:cockpit/app/cockpit/data/remote/remote_host_connector.dart';
import 'package:cockpit/app/cockpit/domain/entities/remote_host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('probe que lança não fecha o gate e o retry pode concluir', () async {
    final gate = ServerFreshnessProbeGate();
    var attempts = 0;

    await expectLater(
      gate.run(() async {
        attempts++;
        throw StateError('transport dropped');
      }),
      throwsStateError,
    );
    expect(gate.completed, isFalse);

    expect(
      await gate.run(() async {
        attempts++;
        return true;
      }),
      isTrue,
    );
    expect(gate.completed, isTrue);
    expect(attempts, 2);
  });

  test('probe concluído roda uma vez só', () async {
    final gate = ServerFreshnessProbeGate();
    var attempts = 0;

    expect(
      await gate.run(() async {
        attempts++;
        return false;
      }),
      isFalse,
    );
    expect(
      await gate.run(() async {
        attempts++;
        return true;
      }),
      isFalse,
    );
    expect(attempts, 1);
  });

  group('server bootstrap freshness (#260)', () {
    late Directory root;
    late ClientBundle bundle;
    late String localDigest;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('cockpit-freshness');
      final bin = Directory('${root.path}/bin')..createSync();
      final server = File('${bin.path}/cockpit-server')
        ..writeAsStringSync('new-server');
      bundle = ClientBundle(root: root.path, serverBinary: server.path);
      localDigest = (await bundle.buildManifest()).digest;
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    RemoteHostConnector connector() => RemoteHostConnector(
      RemoteHost(id: 'test', name: 'test', sshTarget: 'user@host'),
      localServerBinaryResolver: ({String? os, String? arch}) =>
          bundle.serverBinary,
    );

    test('installed stale binary is killed and replaced by digest', () async {
      final shell = _FakeHostShell(remoteDigest: 'old-digest');
      final subject = connector();
      addTearDown(subject.dispose);

      await subject.installAndStartServerForTest(shell);

      expect(shell.operations, [
        'installed',
        'digest',
        'kill',
        'install',
        'start',
      ]);
      expect(shell.uploaded?.serverBinary, bundle.serverBinary);
    });

    test('installed fresh binary is started without replacement', () async {
      final shell = _FakeHostShell(remoteDigest: localDigest);
      final subject = connector();
      addTearDown(subject.dispose);

      await subject.installAndStartServerForTest(shell);

      expect(shell.operations, ['installed', 'digest', 'start']);
      expect(shell.uploaded, isNull);
    });
  });
}

class _FakeHostShell extends HostShell {
  _FakeHostShell({required this.remoteDigest})
    : super(
        probe: const HostProbe(
          family: HostOsFamily.posix,
          os: 'linux',
          arch: 'x64',
          home: '/home/test',
        ),
        exec: _execNotUsed,
      );

  final String? remoteDigest;
  final operations = <String>[];
  ClientBundle? uploaded;

  @override
  String get serverBinaryPath =>
      '/home/test/.cockpit/server/bin/cockpit-server';

  @override
  String get bootLogPath => '/home/test/.cockpit/server-boot.log';

  @override
  bool get installsFromHostBundle => false;

  @override
  Future<RemoteEndpoint?> readEndpoint() async => null;

  @override
  Future<RemoteEndpoint?> awaitEndpoint() async => null;

  @override
  Future<bool> serverInstalled() async {
    operations.add('installed');
    return true;
  }

  @override
  Future<String?> serverSha256() async => null;

  @override
  Future<String?> bundleManifestSha256() async {
    operations.add('digest');
    return remoteDigest;
  }

  @override
  Future<void> killServer() async => operations.add('kill');

  @override
  Future<void> installFromClient(ClientBundle bundle) async {
    operations.add('install');
    uploaded = bundle;
  }

  @override
  Future<bool> installFromHost() async => false;

  @override
  Future<void> startServer({required int idleSeconds}) async =>
      operations.add('start');

  @override
  Future<String> tailBootLog({int bytes = 2000}) async => '';
}

Future<(int, String, String)> _execNotUsed(
  String command, {
  List<int>? stdinBytes,
}) => throw UnimplementedError(command);
