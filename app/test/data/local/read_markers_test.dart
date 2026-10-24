// Plan/149 — read markers + unread counting: unread is DERIVED (msgs box
// rows past the marker, plan/111 verdict: never a stored counter), the
// marker only ever moves forward, and it survives a restart (durable box).

import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory dir;
  late LocalBoxes boxes;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('rp_v2_unread_');
    await LocalBoxes.initForTest(dir.path);
    boxes = LocalBoxes();
  });

  tearDown(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> seed(String roomId, List<int> seqs) async {
    final box = await boxes.msgsBox('epk1', roomId);
    for (final s in seqs) {
      await box.put(s, {'id': 'm$s', 'seq': s});
    }
  }

  test('unread counts msgs box rows past the marker', () async {
    await seed('main', [1, 2, 3, 4, 5]);
    // A session whose box was never opened reads 0 (callers await
    // msgsBox first — the Home VM does exactly that).
    expect(boxes.unreadCount('epk1', 'never-opened'), 0);
    await boxes.msgsBox('epk1', 'main');
    expect(boxes.unreadCount('epk1', 'main'), 5, reason: 'no marker yet');

    boxes.markRead('epk1', 'main', 3);
    expect(boxes.unreadCount('epk1', 'main'), 2);
  });

  test('markRead never moves the marker backwards', () async {
    await seed('main', [1, 2, 3]);
    await boxes.msgsBox('epk1', 'main');
    boxes.markRead('epk1', 'main', 3);
    boxes.markRead('epk1', 'main', 1); // stale replay racing an open chat
    expect(boxes.unreadCount('epk1', 'main'), 0);
  });

  test('markers are per-session and survive a simulated restart', () async {
    await seed('main', [1, 2]);
    await seed('other', [1, 2, 3]);
    boxes.markRead('epk1', 'main', 2);
    boxes.markRead('epk1', 'other', 1);

    // Re-open (initForTest re-opens common boxes; markers are durable and
    // NOT wiped like `runtime`).
    await LocalBoxes.initForTest(dir.path);
    await boxes.msgsBox('epk1', 'main');
    await boxes.msgsBox('epk1', 'other');
    expect(boxes.unreadCount('epk1', 'main'), 0);
    expect(boxes.unreadCount('epk1', 'other'), 2);
  });
}
