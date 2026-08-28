import 'dart:typed_data';

import 'package:cockpit_engine/src/pty/scrollback_buffer.dart';
import 'package:test/test.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  test('retém tudo enquanto cabe e lê por offset', () {
    final buffer = ScrollbackBuffer(capacity: 16);
    buffer.add(bytes([1, 2, 3]));
    buffer.add(bytes([4, 5]));

    expect(buffer.totalLength, 5);
    expect(buffer.read().bytes, [1, 2, 3, 4, 5]);
    expect(buffer.read(fromOffset: 3).offset, 3);
    expect(buffer.read(fromOffset: 3).bytes, [4, 5]);
    expect(buffer.read(fromOffset: 5).bytes, isEmpty);
  });

  test('descarta o início quando estoura a capacidade (wrap)', () {
    final buffer = ScrollbackBuffer(capacity: 8);
    buffer.add(bytes(List.generate(6, (i) => i))); // 0..5
    buffer.add(bytes(List.generate(6, (i) => 10 + i))); // 10..15

    expect(buffer.totalLength, 12);
    expect(buffer.retainedFrom, 4);
    final read = buffer.read();
    expect(read.offset, 4);
    expect(read.bytes, [4, 5, 10, 11, 12, 13, 14, 15]);
    // Pedir antes do retido clampa para o retido.
    expect(buffer.read(fromOffset: 0).offset, 4);
  });

  test('chunk maior que a capacidade retém só o final', () {
    final buffer = ScrollbackBuffer(capacity: 4);
    buffer.add(bytes(List.generate(10, (i) => i)));
    expect(buffer.totalLength, 10);
    expect(buffer.read().offset, 6);
    expect(buffer.read().bytes, [6, 7, 8, 9]);
  });
}
