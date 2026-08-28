/// Motivos de falha ao executar um request de um arquivo `.http`.
enum HttpRequestErrorKind {
  /// O arquivo não tem request nenhum (ou o cursor não caiu em nenhum).
  noRequest,

  /// A URL não é absoluta/parseável depois da interpolação.
  invalidUrl,

  /// Sobrou `{{nome}}` sem valor — nunca mandamos placeholder no ar.
  unresolvedVariable,

  /// `< ./body.json` aponta para arquivo que não existe ou não pôde ser lido.
  bodyFileUnreadable,

  /// DNS/recusa/TLS — não houve resposta.
  connectionFailed,

  /// Estourou o teto de tempo da execução.
  timeout,

  /// A resposta passou do teto de bytes que a aba guarda em memória.
  responseTooLarge,
}

/// Falha tipada da execução de um request.
///
/// `data/` e ViewModel só produzem o [kind] + dados variáveis; a frase nasce em
/// `core/ui/http_request_error_message.dart`. [detail] é texto de terceiros
/// (mensagem do SO/socket) e é exibido **cru**, sem tradução.
class HttpRequestError implements Exception {
  const HttpRequestError(
    this.kind, {
    this.detail,
    this.variable,
    this.path,
    this.timeoutSeconds,
    this.limitBytes,
  });

  final HttpRequestErrorKind kind;
  final String? detail;

  /// Nome da variável não resolvida ([HttpRequestErrorKind.unresolvedVariable]).
  final String? variable;

  /// Caminho do body importado ([HttpRequestErrorKind.bodyFileUnreadable]).
  final String? path;

  final int? timeoutSeconds;
  final int? limitBytes;
}
