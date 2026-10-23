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
      'pressure tint: ≥70% shifts away from the relaxed tint, ≥90% again',
      (tester) async {
        final decors = <BoxDecoration>[];
        for (final percent in [50, 80, 95]) {
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
        // Subtle but distinct: each pressure band paints a different tint.
        expect(decors[0].color, isNot(decors[1].color));
        expect(decors[1].color, isNot(decors[2].color));
        // …and every tint stays a low-alpha background hint (≤ 0.15).
        for (final d in decors) {
          expect(d.color!.a, lessThan(0.15));
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
}
