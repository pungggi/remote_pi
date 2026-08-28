import 'package:cockpit/app/core/domain/exceptions/automation_error.dart';
import 'package:cockpit/app/core/ui/automation_error_message.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Monta um contexto sob `TranslationProvider` e devolve a frase traduzida.
Future<String> _messageFor(
  WidgetTester tester,
  AutomationError error, {
  AppLocale locale = AppLocale.en,
}) async {
  LocaleSettings.setLocale(locale);
  late String result;
  await tester.pumpWidget(
    TranslationProvider(
      child: Builder(
        builder: (context) {
          result = automationErrorMessage(context, error);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return result;
}

void main() {
  testWidgets('interpola harness e modelo no idioma ativo', (tester) async {
    const error = AutomationError(
      AutomationErrorKind.unavailable,
      harness: 'Claude Code',
      model: 'retired-model',
    );

    final en = await _messageFor(tester, error);
    expect(en, contains('retired-model'));
    expect(en, contains('Claude Code'));
    expect(en, contains('Settings'));

    final ptBr = await _messageFor(tester, error, locale: AppLocale.ptBr);
    expect(ptBr, contains('retired-model'));
    expect(ptBr, contains('Configurações'));
  });

  testWidgets('sem modelo cai na frase de harness ausente', (tester) async {
    final message = await _messageFor(
      tester,
      const AutomationError(
        AutomationErrorKind.unavailable,
        harness: 'Codex CLI',
      ),
    );
    expect(message, contains('Codex CLI'));
    expect(message, contains('PATH'));
  });

  testWidgets('process sem detail usa a variante genérica', (tester) async {
    final withDetail = await _messageFor(
      tester,
      const AutomationError(
        AutomationErrorKind.process,
        harness: 'Pi',
        detail: 'boom',
      ),
    );
    final withoutDetail = await _messageFor(
      tester,
      const AutomationError(AutomationErrorKind.process, harness: 'Pi'),
    );

    expect(withDetail, contains('boom'));
    expect(withoutDetail, isNot(contains('boom')));
    expect(withoutDetail, contains('Pi'));
  });

  testWidgets('todo kind tem tradução em todos os locales', (tester) async {
    for (final locale in AppLocale.values) {
      for (final kind in AutomationErrorKind.values) {
        final message = await _messageFor(
          tester,
          AutomationError(kind, harness: 'Pi', detail: 'd', timeoutSeconds: 60),
          locale: locale,
        );
        expect(
          message.trim(),
          isNotEmpty,
          reason: 'kind $kind sem texto em ${locale.languageTag}',
        );
      }
    }
    LocaleSettings.setLocale(AppLocale.en);
  });
}
