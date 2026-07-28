// Regression test for the transcript reverse-ListView slot → message-index
// mapping (see `messageIndexForSlot` in chat_page.dart).
//
// Pre-existing bug: when the "Load more" tile was present, the inline formula
// subtracted an extra 1, which duplicated the newest message and dropped the
// oldest. These tests pin the correct, exhaustive behaviour.
import 'package:app/ui/chat/chat_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('messageIndexForSlot', () {
    test('no streaming, no load-more: newest at bottom, oldest at top', () {
      // M=3 → slots 0,1,2 render msg 2,1,0 (slot 0 is the bottom/newest)
      expect(messageIndexForSlot(0, 3, streaming: false), 2);
      expect(messageIndexForSlot(1, 3, streaming: false), 1);
      expect(messageIndexForSlot(2, 3, streaming: false), 0);
    });

    test('streaming: real messages start at slot 1 (slot 0 is the bubble)', () {
      expect(messageIndexForSlot(1, 3, streaming: true), 2);
      expect(messageIndexForSlot(2, 3, streaming: true), 1);
      expect(messageIndexForSlot(3, 3, streaming: true), 0);
    });

    test('load-more does NOT shift message slots '
        '(regression: it duplicated the newest & dropped the oldest)', () {
      // M=3 with a load-more tile → itemCount=4, load-more at slot 3.
      // Real messages occupy slots 0,1,2 and must map to msg 2,1,0.
      final idxs = [
        for (final s in [0, 1, 2]) messageIndexForSlot(s, 3, streaming: false),
      ]..sort();
      expect(idxs, [0, 1, 2]); // no skip, …
      expect(idxs.toSet().length, 3); // … and no duplicate.
    });

    test('every normal slot maps in-range with no dup/skip (all configs)', () {
      for (final m in [1, 2, 3, 10]) {
        for (final streaming in [true, false]) {
          for (final loadMore in [true, false]) {
            final itemCount = m + (streaming ? 1 : 0) + (loadMore ? 1 : 0);
            final idxs = <int>[];
            for (var i = 0; i < itemCount; i++) {
              if (streaming && i == 0) continue; // streaming bubble
              if (loadMore && i == itemCount - 1) continue; // load-more tile
              idxs.add(messageIndexForSlot(i, m, streaming: streaming));
            }
            expect(idxs..sort(), [
              for (var j = 0; j < m; j++) j,
            ], reason: 'm=$m streaming=$streaming loadMore=$loadMore');
            // Belt-and-suspenders: never out of range, never repeated.
            for (final v in idxs) {
              expect(v, inInclusiveRange(0, m - 1));
            }
            expect(idxs.toSet().length, m);
          }
        }
      }
    });
  });
}
