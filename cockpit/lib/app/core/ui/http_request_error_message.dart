import 'package:cockpit/app/cockpit/domain/exceptions/http_request_error.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter/widgets.dart';

/// Traduz um [HttpRequestError] para a frase mostrada ao usuário.
///
/// É **aqui** que a mensagem nasce: `data/` e as ViewModels só produzem
/// [HttpRequestErrorKind] + dados variáveis, porque não têm `BuildContext`.
/// Texto de terceiros (mensagem do socket/SO) entra como `detail` e é
/// interpolado **cru**, sem tradução.
String httpRequestErrorMessage(BuildContext context, HttpRequestError error) {
  final tr = context.t.cockpit.httpView.error;
  final detail = error.detail?.trim() ?? '';

  return switch (error.kind) {
    HttpRequestErrorKind.noRequest => tr.noRequest,
    HttpRequestErrorKind.invalidUrl => tr.invalidUrl(url: detail),
    HttpRequestErrorKind.unresolvedVariable => tr.unresolvedVariable(
      name: error.variable ?? '',
    ),
    HttpRequestErrorKind.bodyFileUnreadable =>
      detail.isEmpty
          ? tr.bodyFileMissing(path: error.path ?? '')
          : tr.bodyFileUnreadable(path: error.path ?? '', detail: detail),
    HttpRequestErrorKind.connectionFailed =>
      detail.isEmpty
          ? tr.connectionFailedNoDetail
          : tr.connectionFailed(detail: detail),
    HttpRequestErrorKind.timeout => tr.timeout(
      seconds: error.timeoutSeconds ?? 0,
    ),
    HttpRequestErrorKind.responseTooLarge => tr.responseTooLarge(
      bytes: error.limitBytes ?? 0,
    ),
  };
}
