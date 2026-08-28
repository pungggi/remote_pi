/// Motivos pelos quais uma automação (hoje: gerar mensagem de commit) falha.
///
/// Os primeiros vêm do gateway (spawn do CLI); `noWorkspace`..`notConfigured`
/// vêm da ViewModel, antes de qualquer processo nascer. Um enum só porque a UI
/// traduz todos no mesmo lugar.
enum AutomationErrorKind {
  // Gateway / processo
  unavailable,
  authentication,
  timeout,
  cancelled,
  process,
  invalidResponse,
  busy,
  // ViewModel / pré-condições do repositório
  noWorkspace,
  fileOutsideWorkspace,
  fileUnreadable,
  binaryFile,
  noFileChanges,
  noStagedChanges,
  multipleRepositories,
  diffUnavailable,
  notConfigured,
}

/// Falha de automação **sem texto de usuário embutido**.
///
/// A camada de dados e a ViewModel não têm `BuildContext` e portanto não podem
/// traduzir nada: elas descrevem *o que* houve ([kind]) e os dados variáveis
/// ([harness], [model], [detail], [timeoutSeconds]); quem monta a frase é a UI,
/// via `context.t` (ver `automationErrorMessage` em `core/ui`).
///
/// [detail] é texto de terceiros (stderr do CLI, mensagem do SO) — não é
/// traduzível e entra interpolado na frase traduzida.
class AutomationError implements Exception {
  const AutomationError(
    this.kind, {
    this.harness,
    this.model,
    this.detail,
    this.timeoutSeconds,
    this.cause,
  });

  final AutomationErrorKind kind;

  /// Label do harness envolvido (ex.: "Claude Code"), quando faz sentido.
  final String? harness;

  /// Id do modelo envolvido, para os casos de modelo indisponível.
  final String? model;

  /// Texto cru vindo de fora (stderr, erro de FS). Nunca traduzido.
  final String? detail;

  final int? timeoutSeconds;

  final Object? cause;

  @override
  String toString() =>
      'AutomationError($kind'
      '${harness == null ? '' : ', harness: $harness'}'
      '${model == null ? '' : ', model: $model'}'
      '${detail == null ? '' : ', detail: $detail'})';
}
