import 'dart:async';
import 'dart:typed_data';

/// Junta chunks de saída de UMA sessão de PTY em rajada, sem atrasar chunk
/// isolado.
///
/// Cada `PtyOutput` custa uma linha JSON+base64, um write no socket e, no
/// cliente remoto, um pacote SSH inteiro pra decifrar. O PTY nativo entrega
/// chunks pequenos; um redraw de TUI virava centenas de mensagens.
///
/// Política (Nagle invertido): **ocioso → manda na hora** (eco de tecla sai
/// com zero de atraso); depois de mandar, abre uma janela curta em que o que
/// chegar é acumulado e sai junto no fim dela. Uma rajada contínua sai como
/// um lote por janela; digitação nunca espera. Chunks da mesma sessão são
/// contíguos em offset, então o lote leva o offset do primeiro.
class PtyOutputCoalescer {
  PtyOutputCoalescer(
    this._emit, {
    this.window = const Duration(milliseconds: 8),
  });

  final void Function(int offset, Uint8List bytes) _emit;

  /// Janela de acumulação após cada envio.
  final Duration window;

  final BytesBuilder _pending = BytesBuilder(copy: false);
  int _pendingOffset = 0;
  Timer? _timer;
  bool _disposed = false;

  void add(int offset, Uint8List bytes) {
    if (_disposed || bytes.isEmpty) return;
    if (_timer == null) {
      _emit(offset, bytes);
      _arm();
      return;
    }
    if (_pending.isEmpty) _pendingOffset = offset;
    _pending.add(bytes);
  }

  /// Despeja o que estiver acumulado agora (antes de um `exited`, por ex.).
  void flush() {
    if (_pending.isEmpty) return;
    final bytes = _pending.takeBytes();
    _emit(_pendingOffset, bytes);
  }

  void _arm() {
    _timer = Timer(window, () {
      _timer = null;
      if (_pending.isEmpty || _disposed) return;
      flush();
      _arm();
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }
}
