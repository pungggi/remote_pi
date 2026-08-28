import 'dart:math' as math;
import 'dart:typed_data';

/// Ring buffer de scrollback cru por sessão (decisão da Wave 0: o servidor
/// retém BYTES, não grid — o emulador vive no cliente; reattach = replay).
///
/// Endereçado por offset absoluto do stream: `totalLength` cresce para
/// sempre; o buffer retém os últimos [capacity] bytes. Um attach a partir de
/// offset anterior ao retido recebe só o trecho disponível (o cliente sabe
/// que perdeu o início pelo offset do primeiro chunk).
class ScrollbackBuffer {
  ScrollbackBuffer({this.capacity = 4 * 1024 * 1024})
    : _buffer = Uint8List(capacity);

  final int capacity;
  final Uint8List _buffer;

  int _totalLength = 0;

  /// Total de bytes já escritos desde o início da sessão.
  int get totalLength => _totalLength;

  /// Offset absoluto do byte mais antigo ainda retido.
  int get retainedFrom => math.max(0, _totalLength - capacity);

  void add(Uint8List bytes) {
    var data = bytes;
    var skipped = 0;
    if (data.length >= capacity) {
      // Só os últimos `capacity` bytes importam; `skipped` mantém a posição
      // do ring alinhada ao offset absoluto dos bytes efetivamente escritos.
      skipped = data.length - capacity;
      data = Uint8List.sublistView(data, skipped);
    }
    final start = (_totalLength + skipped) % capacity;
    final firstPart = math.min(data.length, capacity - start);
    _buffer.setRange(start, start + firstPart, data);
    if (firstPart < data.length) {
      _buffer.setRange(0, data.length - firstPart, data, firstPart);
    }
    _totalLength += bytes.length;
  }

  /// Bytes retidos a partir do offset absoluto [fromOffset] (clampado ao
  /// que ainda existe). Retorna também o offset real do primeiro byte.
  ({int offset, Uint8List bytes}) read({int fromOffset = 0}) {
    final from = math.max(fromOffset, retainedFrom);
    final length = _totalLength - from;
    if (length <= 0) return (offset: _totalLength, bytes: Uint8List(0));

    final out = Uint8List(length);
    final start = from % capacity;
    final firstPart = math.min(length, capacity - start);
    out.setRange(0, firstPart, Uint8List.sublistView(_buffer, start));
    if (firstPart < length) {
      out.setRange(firstPart, length, _buffer);
    }
    return (offset: from, bytes: out);
  }
}
