import 'dart:typed_data';

import 'package:cockpit/app/cockpit/ui/session/document_host.dart';
import 'package:cockpit/app/cockpit/ui/widgets/panel_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('panel resource loading', () {
    test('encoded parent traversal is rejected before any file read', () async {
      final host = _FakeHost();

      final bytes = await readPanelResource(
        host: host,
        projectId: 'remote-b',
        documentDirectory: '/remote/docs',
        relativePath: Uri.decodeComponent('..%2f..%2fsecret'),
      );

      expect(bytes, isNull);
      expect(host.paths, isEmpty);
    });

    test('Windows-style traversal and absolute paths are rejected', () async {
      final host = _FakeHost();

      for (final path in [r'..\..\secret', r'C:\secret', '/etc/passwd']) {
        final bytes = await readPanelResource(
          host: host,
          projectId: 'remote-b',
          documentDirectory: '/remote/docs',
          relativePath: path,
        );
        expect(bytes, isNull, reason: path);
      }
      expect(host.paths, isEmpty);
    });

    test('sibling assets are read from the issuing remote workspace', () async {
      final expected = Uint8List.fromList([1, 2, 3, 4]);
      final host = _FakeHost()..response = expected;

      final bytes = await readPanelResource(
        host: host,
        projectId: 'remote-b',
        documentDirectory: '/remote/docs',
        relativePath: 'assets/app.js',
      );

      expect(bytes, same(expected));
      expect(host.paths, ['/remote/docs/assets/app.js']);
      expect(host.workspaceIds, ['remote-b']);
    });
  });
}

class _FakeHost implements DocumentHost {
  Uint8List? response;
  final paths = <String>[];
  final workspaceIds = <String?>[];

  @override
  Future<Uint8List?> readBytesAt(String path, {String? workspaceId}) async {
    paths.add(path);
    workspaceIds.add(workspaceId);
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
