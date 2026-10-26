import 'dart:io';

import 'package:cockpit/app/core/data/lsp/lsp_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('runFormatterCommand', () {
    late File file;

    setUp(() {
      file = File('${Directory.systemTemp.createTempSync('fmt').path}/x.ts')
        ..writeAsStringSync('const a=1');
    });
    tearDown(() {
      if (file.parent.existsSync()) file.parent.deleteSync(recursive: true);
    });

    test('falha sem o placeholder %FILE%', () async {
      final r = await runFormatterCommand('prettier --write', file.path);
      expect(r.isFailure, isTrue);
    });

    test('falha com comando vazio', () async {
      final r = await runFormatterCommand('   ', file.path);
      expect(r.isFailure, isTrue);
    });

    test('sucesso quando o comando sai com código 0', () async {
      // `true` ignora argumentos e sai 0 — exercita o caminho feliz sem um
      // formatador real nem modificar o arquivo.
      final command = Platform.isWindows ? 'cmd /c exit 0 %FILE%' : 'true %FILE%';
      final r = await runFormatterCommand(command, file.path);
      expect(r.isSuccess, isTrue);
    });

    test('falha quando o comando sai com código != 0', () async {
      final command = Platform.isWindows ? 'cmd /c exit 1 %FILE%' : 'false %FILE%';
      final r = await runFormatterCommand(command, file.path);
      expect(r.isFailure, isTrue);
    });
  });
}
