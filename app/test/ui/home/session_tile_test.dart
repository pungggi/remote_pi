// Plan/147 — the context-window gauge on the Home tile:
//   * background fill wedge (width = used fraction of the model context
//     window), keyed `session-tile-context-fill`
//   * model subtitle suffix `· Nk` (max tokens behind the model name)
// Pure view widget; `context.colors` falls back to the dark palette
// outside the themed tree, so a bare MaterialApp is enough.

import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/home/widgets/session_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PeerRecord _peer() => PeerRecord(
      remoteEpk: 'A',
      sessionName: 'Pi',
      relayUrl: 'ws://x',
      pairedAt: '2026-01-01T00:00:00Z',
    );

Future<void> _pump(WidgetTester tester, {RoomInfo? room}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SessionTile(peer: _peer(), isLive: true, room: room, onOpen: () {}),
      ),
    ),
  );
}

const _fillKey = ValueKey('session-tile-context-fill');

AnimatedFractionallySizedBox _fill(WidgetTester tester) =>
    tester.widget<AnimatedFractionallySizedBox>(find.byKey(_fillKey));

BoxDecoration _fillDecoration(WidgetTester tester) => tester
    .widget<DecoratedBox>(
      find.descendant(of: find.byKey(_fillKey), matching: find.byType(DecoratedBox)),
    )
    .decoration as BoxDecoration;

void main() {
  group('context fill (plan/147)', () {
    testWidgets(
      'no contextUsage → NO fill wedge; tile degrades to the old look',
      (tester) async {
        await _pump(
          tester,
          room: const RoomInfo(roomId: 'r1', startedAt: 1, model: 'gpt-5.2'),
        );
        expect(find.byKey(_fillKey), findsNothing);
      },
    );

    testWidgets('percent 80 → wedge width matches the fraction', (tester) async {
      await _pump(
        tester,
        room: const RoomInfo(
          roomId: 'r1',
          startedAt: 1,
          contextUsage: ContextUsage(
            tokens: 160000,
            contextWindow: 200000,
            percent: 80,
          ),
        ),
      );
      expect(find.byKey(_fillKey), findsOneWidget);
      expect(_fill(tester).widthFactor, 0.8);
    });

    testWidgets(
      'percent null (post-compaction) → falls back to tokens/contextWindow',
      (tester) async {
        await _pump(
          tester,
          room: const RoomInfo(
            roomId: 'r1',
            startedAt: 1,
            contextUsage: ContextUsage(tokens: 50000, contextWindow: 100000),
          ),
        );
        expect(_fill(tester).widthFactor, 0.5);
      },
    );

    testWidgets(
      'pressure ladder 17/24/35/50 (user-tuned): every band paints a more '
      'prominent tint than the one before',
      (tester) async {
        final decors = <BoxDecoration>[];
        // One probe per band: <17, 17-24, 24-35, 35-50, >=50.
        for (final percent in [10, 20, 30, 40, 60]) {
          await _pump(
            tester,
            room: RoomInfo(
              roomId: 'r1',
              startedAt: 1,
              contextUsage: ContextUsage(
                tokens: percent * 1000,
                contextWindow: 100000,
                percent: percent,
              ),
            ),
          );
          decors.add(_fillDecoration(tester));
        }
        // Distinct at every step and monotonically more prominent:
        // hue escalates accent → warning → error, alpha only rises.
        for (var i = 1; i < decors.length; i++) {
          expect(decors[i].color, isNot(decors[i - 1].color),
              reason: 'band $i must differ from band ${i - 1}');
          expect(decors[i].color!.a, greaterThan(decors[i - 1].color!.a),
              reason: 'band $i must be MORE prominent than band ${i - 1}');
        }
        // Still a background hint, never a solid slab (≤ 0.2).
        for (final d in decors) {
          expect(d.color!.a, lessThan(0.2));
          expect(d.color!.a, greaterThan(0.0));
        }
      },
    );

    testWidgets(
      'lying source clamps: percent 120 → full width, percent 0 → zero',
      (tester) async {
        await _pump(
          tester,
          room: const RoomInfo(
            roomId: 'r1',
            startedAt: 1,
            contextUsage: ContextUsage(
              tokens: 240000,
              contextWindow: 200000,
              percent: 120,
            ),
          ),
        );
        expect(_fill(tester).widthFactor, 1.0);

        await _pump(
          tester,
          room: const RoomInfo(
            roomId: 'r1',
            startedAt: 1,
            contextUsage: ContextUsage(
              tokens: 0,
              contextWindow: 200000,
              percent: 0,
            ),
          ),
        );
        expect(_fill(tester).widthFactor, 0.0);
      },
    );

    testWidgets(
      'fill coexists with the selected-tile highlight (tablet master list)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SessionTile(
                peer: _peer(),
                isLive: true,
                isSelected: true,
                room: const RoomInfo(
                  roomId: 'r1',
                  startedAt: 1,
                  contextUsage: ContextUsage(
                    tokens: 50000,
                    contextWindow: 200000,
                    percent: 25,
                  ),
                ),
                onOpen: () {},
              ),
            ),
          ),
        );
        expect(find.byKey(_fillKey), findsOneWidget);
        expect(_fill(tester).widthFactor, 0.25);
      },
    );
  });

  group('model subtitle max-tokens suffix (plan/147)', () {
    testWidgets(
      'model + contextUsage → subtitle shows "name · Nk" statically '
      '(git null → no alternation clock)',
      (tester) async {
        await _pump(
          tester,
          room: const RoomInfo(
            roomId: 'r1',
            startedAt: 1,
            model: 'claude-sonnet-4-5',
            contextUsage: ContextUsage(
              tokens: 1,
              contextWindow: 200000,
              percent: 1,
            ),
          ),
        );
        expect(find.text('claude-sonnet-4-5 · 200k'), findsOneWidget);
      },
    );

    testWidgets('model without contextUsage → plain truncated name', (tester) async {
      await _pump(
        tester,
        room: const RoomInfo(roomId: 'r1', startedAt: 1, model: 'gpt-5.2'),
      );
      expect(find.text('gpt-5.2'), findsOneWidget);
      expect(find.textContaining('·'), findsNothing);
    });

    testWidgets(
      'sub-1k window (pathological) → no misleading "· 0k" suffix',
      (tester) async {
        await _pump(
          tester,
          room: const RoomInfo(
            roomId: 'r1',
            startedAt: 1,
            model: 'tiny-model',
            contextUsage: ContextUsage(
              tokens: 10,
              contextWindow: 400,
              percent: 3,
            ),
          ),
        );
        expect(find.text('tiny-model'), findsOneWidget);
        expect(find.textContaining('·'), findsNothing);
      },
    );
  });

  group('session slot (plan/149)', () {
    testWidgets(
      'nothing to show → plain initial avatar (never an empty square)',
      (tester) async {
        await _pump(
          tester,
          room: const RoomInfo(roomId: 'r1', startedAt: 1, name: 'alpha'),
        );
        expect(find.text('A'), findsOneWidget); // initial
        expect(find.text('·'), findsNothing); // no slot dot lines
      },
    );

    testWidgets('ref + stats → three mono lines, PR wins the display',
        (tester) async {
      await _pump(
        tester,
        room: const RoomInfo(
          roomId: 'r1',
          startedAt: 1,
          ghRef: GhRef(
            pr: GhRefSlot(
              number: 70,
              url: 'https://github.com/o/r/pull/70',
            ),
          ),
          stats: SessionStats(turns: 3, userMsgs: 7),
        ),
      );
      expect(find.text('PR #70'), findsOneWidget);
      expect(find.text('T3'), findsOneWidget);
      expect(find.text('M7'), findsOneWidget);
    });

    testWidgets('unread renders as its own line without a ref',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionTile(
              peer: _peer(),
              isLive: true,
              onOpen: () {},
              unread: 2,
              room: const RoomInfo(
                roomId: 'r1',
                startedAt: 1,
                stats: SessionStats(turns: 1, userMsgs: 4),
              ),
            ),
          ),
        ),
      );
      expect(find.text('T1'), findsOneWidget);
      expect(find.text('M4'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('ref + stats + unread → msgs line carries the unread count',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionTile(
              peer: _peer(),
              isLive: true,
              onOpen: () {},
              unread: 2,
              room: const RoomInfo(
                roomId: 'r1',
                startedAt: 1,
                ghRef: GhRef(issue: GhRefSlot(number: 12)),
                stats: SessionStats(turns: 1, userMsgs: 4),
              ),
            ),
          ),
        ),
      );
      expect(find.text('#12'), findsOneWidget);
      expect(find.text('M4·2'), findsOneWidget);
    });

    testWidgets('no ref → turns/msgs/unread stack, zero unread renders ·',
        (tester) async {
      await _pump(
        tester,
        room: const RoomInfo(
          roomId: 'r1',
          startedAt: 1,
          stats: SessionStats(turns: 9, userMsgs: 12),
        ),
      );
      expect(find.text('T9'), findsOneWidget);
      expect(find.text('M12'), findsOneWidget);
      expect(find.text('·'), findsOneWidget); // unread line, zero
    });
  });
}
