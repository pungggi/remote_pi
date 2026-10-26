import 'dart:async';

/// Agenda as tentativas de reconexão de um host remoto com backoff e um
/// **gate de foco**: o tique só dispara a tentativa se o gate estiver aberto
/// (o workspace daquele host é o selecionado). Fechado, a tentativa fica
/// **adiada** sem timer nenhum rodando; [resume] a dispara na hora quando o
/// foco volta.
///
/// Motivação: cada host com túnel caído tentava SSH a cada 30s pra sempre,
/// mesmo com o usuário em outro workspace o dia inteiro. Com N hosts fora
/// do ar isso era um `ssh` sendo spawnado a cada poucos segundos, à toa.
/// Reconectar ainda "nunca desiste" (decisão do usuário), só que espera ser
/// visto de novo.
///
/// Só a POLÍTICA mora aqui (backoff, gate, adiado). Quem tenta de fato é
/// [onAttempt]; puro Dart, testável com `fake_async`.
class ReconnectScheduler {
  ReconnectScheduler({
    required this.onAttempt,
    this.isFocused = _alwaysFocused,
    List<Duration>? backoff,
  }) : _backoff = backoff ?? defaultBackoff;

  static bool _alwaysFocused() => true;

  /// Backoff crescente que nunca desiste: 1s, 2s, 4s, 8s, 15s e daí 30s fixo.
  /// O teto no intervalo (e não no número de tentativas) é o que mantém
  /// "insiste pra sempre" sem martelar a rede.
  static const List<Duration> defaultBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  /// Executa uma tentativa. Chamado no tique do timer (gate aberto) ou no
  /// [resume] com tentativa adiada.
  final void Function() onAttempt;

  /// `true` = pode tentar agora. Lido no tique, não no agendamento: o foco
  /// pode mudar durante a espera.
  final bool Function() isFocused;

  final List<Duration> _backoff;
  Timer? _timer;
  int _step = 0;
  bool _deferred = false;
  bool _disposed = false;

  /// Uma tentativa está esperando o foco voltar.
  bool get isDeferred => _deferred;

  /// Um timer de backoff está armado.
  bool get isScheduled => _timer != null;

  /// Próximo intervalo que [schedule] vai usar (pra UI/diagnóstico).
  Duration get nextDelay => _backoff[_step.clamp(0, _backoff.length - 1)];

  /// Agenda a próxima tentativa. No-op se já há timer armado ou tentativa
  /// adiada (as duas já garantem que alguém vai tentar).
  void schedule() {
    if (_disposed || _timer != null || _deferred) return;
    final delay = nextDelay;
    if (_step < _backoff.length - 1) _step++;
    _timer = Timer(delay, _tick);
  }

  void _tick() {
    _timer = null;
    if (_disposed) return;
    if (!isFocused()) {
      // Sem foco: nada de rede. Fica marcado e o [resume] resolve.
      _deferred = true;
      return;
    }
    onAttempt();
  }

  /// O host voltou a ter foco: se havia tentativa adiada, tenta AGORA (o
  /// usuário está olhando, então a espera do backoff não faz sentido).
  void resume() {
    if (_disposed || !_deferred) return;
    _deferred = false;
    _step = 0;
    onAttempt();
  }

  /// Conexão estabelecida: zera o backoff e descarta o que estava pendente.
  void reset() {
    _step = 0;
    _deferred = false;
    _timer?.cancel();
    _timer = null;
  }

  /// Cancela timer e adiado sem mexer no passo (pra `reconnectNow`, que zera
  /// por conta própria).
  void cancel() {
    _deferred = false;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}
