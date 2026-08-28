import 'package:cockpit/app/core/domain/exceptions/file_operation_error.dart';
import 'package:cockpit/app/core/ui/file_operation_error_message.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> _messageFor(
  WidgetTester tester,
  FileOperationError error, {
  AppLocale locale = AppLocale.en,
}) async {
  LocaleSettings.setLocale(locale);
  late String result;
  await tester.pumpWidget(
    TranslationProvider(
      child: Builder(
        builder: (context) {
          result = fileOperationErrorMessage(context, error);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return result;
}

void main() {
  testWidgets('interpola o nome no idioma ativo', (tester) async {
    const error = FileOperationError(
      FileOperationErrorKind.alreadyExists,
      name: 'main.dart',
    );

    expect(await _messageFor(tester, error), contains('main.dart'));

    final ptBr = await _messageFor(tester, error, locale: AppLocale.ptBr);
    expect(ptBr, contains('main.dart'));
    expect(ptBr, contains('Já existe'));
  });

  testWidgets('stderr de terceiro passa cru, sem tradução', (tester) async {
    final message = await _messageFor(
      tester,
      const FileOperationError(
        FileOperationErrorKind.osFailure,
        detail: 'fatal: pathspec did not match',
      ),
      locale: AppLocale.ptBr,
    );
    expect(message, contains('fatal: pathspec did not match'));
  });

  testWidgets('todo kind tem tradução em todos os locales', (tester) async {
    for (final locale in AppLocale.values) {
      for (final kind in FileOperationErrorKind.values) {
        final message = await _messageFor(
          tester,
          FileOperationError(kind, name: 'f.txt', detail: 'd', exitCode: 2),
          locale: locale,
        );
        expect(message.trim(), isNotEmpty, reason: 'kind $kind em $locale');
      }
    }
    LocaleSettings.setLocale(AppLocale.en);
  });
}
