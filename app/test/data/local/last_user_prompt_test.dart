// Grouped Home (by-model) — LocalBoxes.lastUserPrompt(): the most recent
// user row (by ts, not storage seq) as the tile's prompt preview source.

import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

MessageRecord _row(int seq, MsgRole role, String text, {int ts = 0}) =>
    MessageRecord(
      id: 'id-$seq',
      seq: seq,
      role: role,
      text: text,
      ts: DateTime.fromMillisecondsSinceEpoch(ts),
    );

Future<void> _put(
  LocalBoxes boxes,
  String epk,
  String roomId,
  MessageRecord row,
) async {
  final box = await boxes.msgsBox(epk, roomId);
  await box.put(row.seq, row.toJson());
}

void main() {
  group('lastUserPrompt', () {
    late Directory dir;
    late LocalBoxes boxes;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('rp_last_prompt_');
      await LocalBoxes.initForTest(dir.path);
      boxes = LocalBoxes();
    });
    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test(
      'returns the newest user row by ts, not the last-inserted seq',
      () async {
        // Backward history paging: an OLDER user page arrived LAST (higher
        // seq) — the preview must still show the chronologically newest.
        await _put(
          boxes,
          'A',
          'r1',
          _row(0, MsgRole.user, 'first prompt', ts: 100),
        );
        await _put(
          boxes,
          'A',
          'r1',
          _row(1, MsgRole.assistant, 'answer', ts: 200),
        );
        await _put(
          boxes,
          'A',
          'r1',
          _row(2, MsgRole.user, 'second prompt', ts: 300),
        );
        await _put(
          boxes,
          'A',
          'r1',
          _row(3, MsgRole.user, 'older page', ts: 150),
        );

        expect(boxes.lastUserPrompt('A', 'r1'), 'second prompt');
      },
    );

    test('skips tool/assistant/compaction rows and image-only sends', () async {
      await _put(
        boxes,
        'A',
        'r1',
        _row(0, MsgRole.user, 'real prompt', ts: 100),
      );
      await _put(
        boxes,
        'A',
        'r1',
        _row(1, MsgRole.user, '', ts: 200),
      ); // image-only
      await _put(
        boxes,
        'A',
        'r1',
        _row(2, MsgRole.assistant, 'latest text', ts: 300),
      );

      expect(boxes.lastUserPrompt('A', 'r1'), 'real prompt');
    });

    test('null for unknown sessions, closed boxes, and empty text', () async {
      expect(boxes.lastUserPrompt('A', 'missing'), isNull);
      await _put(boxes, 'A', 'r1', _row(0, MsgRole.assistant, 'only', ts: 1));
      expect(boxes.lastUserPrompt('A', 'r1'), isNull);
    });

    test('sessions are isolated by (epk, roomId)', () async {
      await _put(boxes, 'A', 'r1', _row(0, MsgRole.user, 'in r1', ts: 100));
      await _put(
        boxes,
        'B',
        'r1',
        _row(0, MsgRole.user, 'other peer', ts: 100),
      );
      expect(boxes.lastUserPrompt('A', 'r1'), 'in r1');
      expect(boxes.lastUserPrompt('B', 'r1'), 'other peer');
    });
  });
}
