import 'dart:async';

/// Agrupa o `pty.ack` de uma sessão REMOTA por volume de crédito, em vez de
/// mandar um por chunk entregue.
///
/// No caminho local o ack é uma chamada FFI; no remoto vira uma mensagem
/// JSON, um pacote SSH cifrado e um write no uplink do celular — um por chunk
/// recebido dobrava o número de pacotes de uma rajada. A janela de créditos do
/// servidor é de 256 KB, então confirmar a cada [threshold] bytes mantém a
/// leitura remota longe de pausar.
///
/// Latência do eco não muda: ack só regula quanto o servidor pode ler à
/// frente. O que garante que crédito miúdo nunca fica preso (e o servidor
/// nunca espera por ele) é o [trailing]: um resto abaixo do limiar sai depois
/// de uma pausa curta sem novas entregas.
class PtyAckBatcher {
  PtyAckBatcher({
    required this.send,
    this.threshold = 32 * 1024,
    this.trailing = const Duration(milliseconds: 50),
  });

  /// Envia o ack de [bytes] créditos.
  final void Function(int bytes) send;
  final int threshold;
  final Duration trailing;

  int _credit = 0;
  Timer? _timer;
  bool _disposed = false;

  int get pending => _credit;

  /// Registra [bytes] de crédito a confirmar.
  void add(int bytes) {
    if (_disposed || bytes <= 0) return;
    _credit += bytes;
    if (_credit >= threshold) {
      flush();
      return;
    }
    _timer ??= Timer(trailing, () {
      _timer = null;
      flush();
    });
  }

  /// Confirma tudo que está pendente agora.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_credit <= 0) return;
    final credit = _credit;
    _credit = 0;
    send(credit);
  }

  /// Cancela o envio pendente e devolve o crédito retido, sem confirmar —
  /// pra quem perdeu o transporte devolver esse crédito ao contador e
  /// confirmá-lo na conexão seguinte.
  int reset() {
    _timer?.cancel();
    _timer = null;
    final credit = _credit;
    _credit = 0;
    return credit;
  }

  /// Descarta o pendente (sessão morta: não há a quem confirmar).
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _credit = 0;
  }
}
