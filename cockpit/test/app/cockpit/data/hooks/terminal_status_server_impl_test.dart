// Status endpoint file (terminal_status_server_impl): start() must publish
// the live transport endpoint (Windows: ephemeral TCP port + anti-spoof
// token; POSIX: UDS path) so processes OUTSIDE Cockpit PTYs — e.g. the
// remote-pi device daemon serving `api.changeLayout` from the phone — can
// reach the command server; stop() must remove it.
import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/data/hooks/terminal_status_server_impl.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('ckp-endpoint-');
  });
  tearDown(() async {
    if (await home.exists()) await home.delete(recursive: true);
  });

  test('start() publishes the endpoint file; stop() removes it', () async {
    final srv = TerminalStatusServerImpl(home.path);
    await srv.start((_) {});

    final file = File(
      '${home.path}/.cockpit/status-endpoint${kDebugMode ? '-debug' : ''}.json',
    );
    expect(await file.exists(), isTrue,
        reason: 'endpoint file must exist after start()');

    final doc = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (Platform.isWindows) {
      expect(doc['port'], isA<int>());
      expect(doc['token'], isA<String>());
      // Published port/token must be exactly what the PTYs get via hookEnv.
      expect(srv.hookEnv['COCKPIT_STATUS_PORT'], doc['port'].toString());
      expect(srv.hookEnv['COCKPIT_STATUS_TOKEN'], doc['token']);
    } else {
      expect(doc['sock'], isA<String>());
      expect(srv.hookEnv['COCKPIT_STATUS_SOCK'], doc['sock']);
    }

    await srv.stop();
    expect(await file.exists(), isFalse,
        reason: 'endpoint file must be removed on stop()');
  });
}
