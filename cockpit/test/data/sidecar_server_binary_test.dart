import 'dart:io';

import 'package:cockpit/app/cockpit/data/terminal/sidecar/sidecar_terminal_connector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regressão do bug que deixou toda aba de terminal ~5,8s mais lenta na 1.28.0:
/// o exe do servidor virou um Mach-O universal (lipo), o `dartaotruntime` não
/// achava mais o snapshot anexado e o sidecar nunca subia. O bundle passou a
/// trazer uma fatia por arquitetura, e é o resolver que escolhe.
void main() {
  late Directory bin;

  setUp(() {
    bin = Directory.systemTemp.createTempSync('cockpit-bundle-bin');
  });
  tearDown(() => bin.deleteSync(recursive: true));

  String touch(String name) {
    final f = File('${bin.path}/$name')..writeAsStringSync('x');
    return f.path;
  }

  test('prefere a fatia da arquitetura pedida', () {
    touch(SidecarTerminalConnector.serverExeName);
    final arm = touch(SidecarTerminalConnector.serverExeFor('arm64'));
    final x64 = touch(SidecarTerminalConnector.serverExeFor('x64'));

    expect(
      SidecarTerminalConnector.serverBinaryIn(bin.path, arch: 'arm64'),
      arm,
    );
    expect(SidecarTerminalConnector.serverBinaryIn(bin.path, arch: 'x64'), x64);
  });

  test('cai no nome sem sufixo (bundle de arquitetura única)', () {
    final plain = touch(SidecarTerminalConnector.serverExeName);

    expect(
      SidecarTerminalConnector.serverBinaryIn(bin.path, arch: 'arm64'),
      plain,
    );
  });

  test('sem binário algum devolve null', () {
    expect(SidecarTerminalConnector.serverBinaryIn(bin.path), isNull);
  });

  test('a fatia pedida ausente não impede achar a outra pelo nome puro', () {
    final plain = touch(SidecarTerminalConnector.serverExeName);
    touch(SidecarTerminalConnector.serverExeFor('x64'));

    expect(
      SidecarTerminalConnector.serverBinaryIn(bin.path, arch: 'arm64'),
      plain,
    );
  });
}
