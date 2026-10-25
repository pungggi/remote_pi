import 'package:cockpit/app/cockpit/data/remote/pty_ack_batcher.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('crédito miúdo sai pelo trailing, um ack só', () {
    fakeAsync((async) {
      final sent = <int>[];
      final b = PtyAckBatcher(send: sent.add, threshold: 1000);
      b.add(10);
      b.add(20);
      expect(sent, isEmpty);
      async.elapse(const Duration(milliseconds: 50));
      expect(sent, [30]);
    });
  });

  test('atinge o limiar: ack imediato com tudo acumulado', () {
    fakeAsync((async) {
      final sent = <int>[];
      final b = PtyAckBatcher(send: sent.add, threshold: 1000);
      b.add(600);
      b.add(500);
      expect(sent, [1100]);
      async.elapse(const Duration(milliseconds: 50));
      expect(sent, [1100]); // trailing cancelado junto
    });
  });

  test('reset devolve o pendente sem enviar; dispose descarta', () {
    fakeAsync((async) {
      final sent = <int>[];
      final b = PtyAckBatcher(send: sent.add, threshold: 1000);
      b.add(100);
      expect(b.reset(), 100);
      async.elapse(const Duration(milliseconds: 50));
      expect(sent, isEmpty);
      b.add(100);
      b.dispose();
      async.elapse(const Duration(milliseconds: 50));
      expect(sent, isEmpty);
    });
  });
}
