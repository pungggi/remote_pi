import 'package:cockpit/app/cockpit/domain/entities/file_view.dart';
import 'package:cockpit/app/cockpit/ui/session/file_viewer_session.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/cockpit_cli_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CLI filesystem routing prefers the issuing tab workspace', () {
    final sender = FileViewerSession(
      id: 'tab-b',
      projectId: 'remote-b',
      path: '/remote/docs/example.panel',
      view: const FileViewText(''),
    );

    expect(cliWorkspaceIdFor(sender, 'selected-a'), 'remote-b');
  });

  test('CLI without a sender keeps the selected workspace fallback', () {
    expect(cliWorkspaceIdFor(null, 'selected-a'), 'selected-a');
  });
}
