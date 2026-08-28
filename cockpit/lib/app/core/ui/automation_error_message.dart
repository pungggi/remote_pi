import 'package:cockpit/app/core/domain/exceptions/automation_error.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter/widgets.dart';

/// Traduz um [AutomationError] para a frase mostrada ao usuário.
///
/// É **aqui** que a mensagem nasce: `data/` e as ViewModels só produzem
/// [AutomationErrorKind] + dados variáveis, porque não têm `BuildContext` para
/// traduzir. Toda camada acima da UI que precisar exibir o erro passa por esta
/// função.
String automationErrorMessage(BuildContext context, AutomationError error) {
  final tr = context.t.automation.error;
  // Sem harness conhecido (falha antes de escolher um), evita "null" na frase.
  final harness = error.harness ?? '';
  final detail = error.detail?.trim() ?? '';

  return switch (error.kind) {
    AutomationErrorKind.unavailable =>
      error.model != null
          ? tr.modelUnavailable(model: error.model!, harness: harness)
          : tr.unavailable(harness: harness),
    AutomationErrorKind.authentication => tr.authentication(
      harness: harness,
      detail: detail,
    ),
    AutomationErrorKind.timeout => tr.timeout(
      harness: harness,
      seconds: error.timeoutSeconds ?? 0,
    ),
    AutomationErrorKind.cancelled => tr.cancelled,
    AutomationErrorKind.process =>
      detail.isEmpty
          ? tr.processNoDetail(harness: harness)
          : tr.process(harness: harness, detail: detail),
    AutomationErrorKind.invalidResponse => tr.invalidResponse,
    AutomationErrorKind.busy => tr.busy,
    AutomationErrorKind.noWorkspace => tr.noWorkspace,
    AutomationErrorKind.fileOutsideWorkspace => tr.fileOutsideWorkspace,
    AutomationErrorKind.fileUnreadable => tr.fileUnreadable(detail: detail),
    AutomationErrorKind.binaryFile => tr.binaryFile,
    AutomationErrorKind.noFileChanges => tr.noFileChanges,
    AutomationErrorKind.noStagedChanges => tr.noStagedChanges,
    AutomationErrorKind.multipleRepositories => tr.multipleRepositories,
    AutomationErrorKind.diffUnavailable =>
      detail.isEmpty ? tr.diffUnavailable : detail,
    AutomationErrorKind.notConfigured => tr.notConfigured,
  };
}
