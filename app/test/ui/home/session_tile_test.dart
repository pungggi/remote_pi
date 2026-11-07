// Plan/147 — the context-window gauge on the Home tile:
//   * background fill wedge (width = used fraction of the model context
//     window), keyed `session-tile-context-fill`
//   * model subtitle suffix `· Nk` (max tokens behind the model name)
// Pure view widget; `context.colors` falls back to the dark palette
// outside the themed tree, so a bare MaterialApp is enough.

import 'package:app/data/preferences/preferences.dart' show HomeGroupBy;
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/widgets/session_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PeerRecord _peer() => PeerRecord(
  remoteEpk: 'A',
  sessionName: 'Pi',
  relayUrl: 'ws://x',
  pairedAt: '2026-01-01T00:00:00Z',
);

Future<void> _pump(
  WidgetTester tester, {
  RoomInfo? room,
  bool isLive = true,
  bool isReconnecting = false,
  bool isWorking = false,
  bool isWaitingForInput = false,
  int unread = 0,
  String? deviceLabel,
  HomeGroupBy groupBy = HomeGroupBy.model,
  GitStatus? git,
  String? lastPrompt,
  DateTime? lastResponseAt,
  int subtitlePhase = 0,
  void Function(int delta)? onCycleSubtitle,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SessionTile(
          peer: _peer(),
          isLive: isLive,
          isReconnecting: isReconnecting,
          isWorking: isWorking,
          isWaitingForInput: isWaitingForInput,
          unread: unread,
          room: room,
          deviceLabel: deviceLabel,
          git: git,
          groupBy: groupBy,
          lastPrompt: lastPrompt,
          lastResponseAt: lastResponseAt,
          subtitlePhase: subtitlePhase,
          onCycleSubtitle: onCycleSubtitle,
          onOpen: () {},
        ),
      ),
    ),
  );
}

const _fillKey = ValueKey('session-tile-context-fill');
const _slotKey = ValueKey('session-tile-session-slot');
const _avatarKey = ValueKey('session-tile-avatar');

const _statusRoom = RoomInfo(
  roomId: 'r1',
  startedAt: 1,
  stats: SessionStats(turns: 3, userMsgs: 7),
);

AnimatedFractionallySizedBox _fill(WidgetTester tester) =>
    tester.widget<AnimatedFractionallySizedBox>(find.byKey(_fillKey));

BoxDecoration _fillDecoration(WidgetTester tester) =>
    tester
            .widget<DecoratedBox>(
              find.descendant(
                of: find.byKey(_fillKey),
                matching: find.byType(DecoratedBox),
              ),
            )
            .decoration
        as BoxDecoration;

BoxDecoration _containerDecoration(WidgetTester tester, Key key) =>
    tester.widget<Container>(find.byKey(key)).decoration! as BoxDecoration;

Color _borderColor(BoxDecoration decoration) =>
    (decoration.border! as Border).top.color;

Color _textColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.color!;

void main() {
  group('device disambiguation', () {
    testWidgets('shows a device label only when supplied', (tester) async {
      await _pump(
        tester,
        room: const RoomInfo(roomId: 'r1', startedAt: 1, name: 'Project A'),
        deviceLabel: 'MacBook Pro',
      );
      expect(
        find.byKey(const ValueKey('session-tile-device-label')),
        findsOneWidget,
      );
      expect(find.text('MacBook Pro'), findsOneWidget);

      await _pump(
        tester,
        room: const RoomInfo(roomId: 'r1', startedAt: 1, name: 'Project A'),
      );
      expect(
        find.byKey(const ValueKey('session-tile-device-label')),
        findsNothing,
      );
    });
  });

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

    testWidgets('percent 80 → wedge width matches the fraction', (
      tester,
    ) async {
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
          expect(
            decors[i].color,
            isNot(decors[i - 1].color),
            reason: 'band $i must differ from band ${i - 1}',
          );
          expect(
            decors[i].color!.a,
            greaterThan(decors[i - 1].color!.a),
            reason: 'band $i must be MORE prominent than band ${i - 1}',
          );
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

  // Grouped-by-model tiles hide the model (the group header owns it), so
  // these pump in REPOSITORY mode, where the tile's model line still renders.
  group('model subtitle max-tokens suffix (plan/147)', () {
    testWidgets('model + contextUsage → subtitle shows "name · Nk" statically '
        '(git null → no alternation clock)', (tester) async {
      await _pump(
        tester,
        groupBy: HomeGroupBy.repository,
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
    });

    testWidgets('model without contextUsage → plain truncated name', (
      tester,
    ) async {
      await _pump(
        tester,
        groupBy: HomeGroupBy.repository,
        room: const RoomInfo(roomId: 'r1', startedAt: 1, model: 'gpt-5.2'),
      );
      expect(find.text('gpt-5.2'), findsOneWidget);
      expect(find.textContaining('·'), findsNothing);
    });

    testWidgets('sub-1k window (pathological) → no misleading "· 0k" suffix', (
      tester,
    ) async {
      await _pump(
        tester,
        groupBy: HomeGroupBy.repository,
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
    });
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

    testWidgets('ref + stats → three mono lines, PR wins the display', (
      tester,
    ) async {
      await _pump(
        tester,
        room: const RoomInfo(
          roomId: 'r1',
          startedAt: 1,
          ghRef: GhRef(
            pr: GhRefSlot(number: 70, url: 'https://github.com/o/r/pull/70'),
          ),
          stats: SessionStats(turns: 3, userMsgs: 7),
        ),
      );
      expect(find.text('PR #70'), findsOneWidget);
      expect(find.text('T3'), findsOneWidget);
      expect(find.text('M7'), findsOneWidget);
    });

    testWidgets('unread renders as its own line without a ref', (tester) async {
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

    testWidgets('ref + stats + unread → msgs line carries the unread count', (
      tester,
    ) async {
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

    testWidgets(
      'ref WITHOUT stats still surfaces unread on the third line (PR #71 review)',
      (tester) async {
        // A legacy/pre-149 tile that got a ref linked must not collapse its
        // unread to '·' — linking a session never hides its unread.
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
                  ghRef: GhRef(pr: GhRefSlot(number: 70)),
                ),
              ),
            ),
          ),
        );
        expect(find.text('PR #70'), findsOneWidget);
        expect(find.text('2'), findsOneWidget);
        expect(find.text('·'), findsOneWidget); // T-line placeholder only
      },
    );

    testWidgets('no ref → turns/msgs/unread stack, zero unread renders ·', (
      tester,
    ) async {
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

  group('session status color', () {
    testWidgets('provider error turns the whole live slot red', (tester) async {
      const colors = AppColors.dark;
      await _pump(
        tester,
        room: _statusRoom.copyWith(providerError: true),
        isWorking: true,
        isWaitingForInput: true,
      );

      final decoration = _containerDecoration(tester, _slotKey);
      expect(_borderColor(decoration), colors.error);
      expect(decoration.color, colors.error.withValues(alpha: 0.10));
      for (final label in ['T3', 'M7', '·']) {
        expect(_textColor(tester, label), colors.error);
      }
    });

    testWidgets('cached provider error keeps reconnecting amber', (
      tester,
    ) async {
      const colors = AppColors.dark;
      await _pump(
        tester,
        room: _statusRoom.copyWith(providerError: true),
        isLive: false,
        isReconnecting: true,
      );

      final decoration = _containerDecoration(tester, _slotKey);
      expect(_borderColor(decoration), colors.warning);
      expect(decoration.color, colors.warning.withValues(alpha: 0.10));
      for (final label in ['T3', 'M7', '·']) {
        expect(_textColor(tester, label), colors.warning);
      }
    });

    testWidgets('cached provider error keeps an offline slot grey', (
      tester,
    ) async {
      const colors = AppColors.dark;
      await _pump(
        tester,
        room: _statusRoom.copyWith(providerError: true),
        isLive: false,
      );

      final decoration = _containerDecoration(tester, _slotKey);
      expect(_borderColor(decoration), colors.muted);
      expect(decoration.color, colors.muted.withValues(alpha: 0.10));
      for (final label in ['T3', 'M7', '·']) {
        expect(_textColor(tester, label), colors.muted);
      }
    });

    testWidgets(
      'slot keeps waiting > working > reconnecting > live > offline',
      (tester) async {
        const colors = AppColors.dark;
        final cases =
            <
              ({
                String name,
                Color color,
                bool isLive,
                bool isReconnecting,
                bool isWorking,
                bool isWaitingForInput,
              })
            >[
              (
                name: 'waiting',
                color: colors.warning,
                isLive: true,
                isReconnecting: true,
                isWorking: true,
                isWaitingForInput: true,
              ),
              (
                name: 'working',
                color: colors.working,
                isLive: true,
                isReconnecting: true,
                isWorking: true,
                isWaitingForInput: false,
              ),
              (
                name: 'reconnecting',
                color: colors.warning,
                isLive: true,
                isReconnecting: true,
                isWorking: false,
                isWaitingForInput: false,
              ),
              (
                name: 'live',
                color: colors.success,
                isLive: true,
                isReconnecting: false,
                isWorking: false,
                isWaitingForInput: false,
              ),
              (
                name: 'offline',
                color: colors.muted,
                isLive: false,
                isReconnecting: false,
                isWorking: false,
                isWaitingForInput: false,
              ),
            ];

        for (final c in cases) {
          await _pump(
            tester,
            room: _statusRoom,
            isLive: c.isLive,
            isReconnecting: c.isReconnecting,
            isWorking: c.isWorking,
            isWaitingForInput: c.isWaitingForInput,
          );
          final decoration = _containerDecoration(tester, _slotKey);
          expect(_borderColor(decoration), c.color, reason: c.name);
          expect(
            decoration.color,
            c.color.withValues(alpha: 0.10),
            reason: '${c.name} fill',
          );
          for (final label in ['T3', 'M7', '·']) {
            expect(
              _textColor(tester, label),
              c.color,
              reason: '${c.name} $label text',
            );
          }
        }
      },
    );

    testWidgets('unread keeps count and emphasis in the same status color', (
      tester,
    ) async {
      const colors = AppColors.dark;
      await _pump(tester, room: _statusRoom, isWorking: true, unread: 2);

      final decoration = _containerDecoration(tester, _slotKey);
      expect(_borderColor(decoration), colors.working);
      expect(decoration.color, colors.working.withValues(alpha: 0.10));
      for (final label in ['T3', 'M7', '2']) {
        expect(_textColor(tester, label), colors.working);
      }
      expect(
        tester.widget<Text>(find.text('M7')).style!.fontWeight,
        FontWeight.w400,
      );
      expect(
        tester.widget<Text>(find.text('2')).style!.fontWeight,
        FontWeight.w600,
      );
    });

    testWidgets('avatar fallback carries status instead of the removed dot', (
      tester,
    ) async {
      const colors = AppColors.dark;
      await _pump(
        tester,
        room: const RoomInfo(roomId: 'r1', startedAt: 1, name: 'alpha'),
        isWorking: true,
      );

      expect(find.byKey(_slotKey), findsNothing);
      final decoration = _containerDecoration(tester, _avatarKey);
      expect(_borderColor(decoration), colors.working);
      expect(decoration.color, colors.working.withValues(alpha: 0.10));
      expect(_textColor(tester, 'A'), colors.working);
    });
  });

  group('grouped display (repo mode)', () {
    testWidgets(
      'by-repo: the title shows the BRANCH where the folder name was — '
      'including when the Pi announced the auto-derived folder name as '
      'room.name (PR #81 review)',
      (tester) async {
        // Real unrenamed rooms are announced with name = _displayName(cwd)
        // (mesh name / agent_name default / basename) — i.e. exactly the
        // folder name restated. That must not beat the branch title.
        await _pump(
          tester,
          groupBy: HomeGroupBy.repository,
          git: const GitStatus(
            branch: 'feat/plan-153-relay-unifiedpush',
            repository: 'pungggi/remote_pi',
          ),
          room: const RoomInfo(
            roomId: 'r1',
            startedAt: 1,
            name: 'remote_pi_off',
            cwd: '/src/pi/packages/remote_pi_off',
          ),
        );

        expect(find.text('feat/plan-153-relay-unifiedpush'), findsOneWidget);
        expect(find.text('remote_pi_off'), findsNothing);
      },
    );

    testWidgets(
      'by-repo: broker #N collision suffix and the legacy parent/folder '
      'name shape are still auto-derived → branch wins',
      (tester) async {
        await _pump(
          tester,
          groupBy: HomeGroupBy.repository,
          git: const GitStatus(branch: 'main', repository: 'pungggi/pi'),
          room: const RoomInfo(
            roomId: 'r1',
            startedAt: 1,
            name: 'remote_pi_off#2',
            cwd: '/src/pi/packages/remote_pi_off',
          ),
        );
        expect(find.text('main'), findsOneWidget);
        expect(find.text('remote_pi_off#2'), findsNothing);

        await _pump(
          tester,
          groupBy: HomeGroupBy.repository,
          git: const GitStatus(branch: 'main', repository: 'pungggi/pi'),
          room: const RoomInfo(
            roomId: 'r1',
            startedAt: 1,
            name: 'packages/remote_pi_off', // legacy defaultAgentName shape
            cwd: '/src/pi/packages/remote_pi_off',
          ),
        );
        expect(find.text('main'), findsOneWidget);
        expect(find.text('packages/remote_pi_off'), findsNothing);
      },
    );

    testWidgets('by-repo: a name the user chose still beats the branch', (
      tester,
    ) async {
      await _pump(
        tester,
        groupBy: HomeGroupBy.repository,
        git: const GitStatus(branch: 'main', repository: 'pungggi/pi'),
        room: const RoomInfo(
          roomId: 'r1',
          startedAt: 1,
          name: 'relay work',
          cwd: '/src/pi/packages/pi_relay',
        ),
      );

      expect(find.text('relay work'), findsOneWidget);
      expect(find.text('main'), findsNothing);
    });

    testWidgets(
      'by-repo: without a git snapshot the folder-name title survives',
      (tester) async {
        await _pump(
          tester,
          groupBy: HomeGroupBy.repository,
          room: const RoomInfo(roomId: 'r1', startedAt: 1, cwd: '/src/scratch'),
        );

        expect(find.text('scratch'), findsOneWidget);
      },
    );

    testWidgets('by-model: the model never renders on the tile — the last user '
        'prompt takes the subtitle instead', (tester) async {
      await _pump(
        tester,
        groupBy: HomeGroupBy.model,
        lastPrompt: 'fix the auth timeout in the relay worker',
        room: const RoomInfo(
          roomId: 'r1',
          startedAt: 1,
          cwd: '/src/scratch',
          model: 'GLH-5.3',
          contextUsage: ContextUsage(tokens: 1000, contextWindow: 200000),
        ),
      );

      expect(
        find.byKey(const ValueKey('session-tile-last-prompt')),
        findsOneWidget,
      );
      expect(
        find.text('fix the auth timeout in the relay worker'),
        findsOneWidget,
      );
      // No model line anywhere on the tile (group header owns it) — the
      // `· 200k` suffix was model-only too.
      expect(find.textContaining('GLH-5.3'), findsNothing);
      expect(find.textContaining('200k'), findsNothing);
    });

    testWidgets(
      'by-model without a known prompt: no model fallback, straight to '
      'the paired subtitle',
      (tester) async {
        await _pump(
          tester,
          groupBy: HomeGroupBy.model,
          room: const RoomInfo(roomId: 'r1', startedAt: 1, model: 'GLH-5.3'),
        );

        expect(find.textContaining('GLH-5.3'), findsNothing);
        expect(find.textContaining('Last paired:'), findsOneWidget);
      },
    );
  });

  // Plan/160 — the subtitle is swipe-cycled per session; no auto-alternation
  // clock exists anymore.
  group('subtitle cycling (plan/160)', () {
    const gitKey = ValueKey('git');
    const secondaryKey = ValueKey('session-tile-subtitle-secondary');

    testWidgets('left swipe requests +1, right swipe requests -1 '
        '(by-repo, git + model available)', (tester) async {
      final deltas = <int>[];
      await _pump(
        tester,
        groupBy: HomeGroupBy.repository,
        git: const GitStatus(branch: 'main'),
        room: const RoomInfo(roomId: 'r1', startedAt: 1, model: 'gpt-5.2'),
        onCycleSubtitle: deltas.add,
      );
      await tester.drag(find.byType(SessionTile), const Offset(-220, 0));
      await tester.pumpAndSettle();
      expect(deltas, [1]);

      await tester.drag(find.byType(SessionTile), const Offset(220, 0));
      await tester.pumpAndSettle();
      expect(deltas, [1, -1]);
    });

    testWidgets('phase 0 → git line; phase 1 → model line (by-repo)', (
      tester,
    ) async {
      Future<void> pumpAt(int phase) => _pump(
        tester,
        groupBy: HomeGroupBy.repository,
        subtitlePhase: phase,
        git: const GitStatus(branch: 'main'),
        room: const RoomInfo(roomId: 'r1', startedAt: 1, model: 'gpt-5.2'),
      );

      await pumpAt(0);
      await tester.pumpAndSettle();
      expect(find.byKey(gitKey), findsOneWidget);
      expect(find.byKey(secondaryKey), findsNothing);
      expect(find.text('gpt-5.2'), findsNothing);

      await pumpAt(1);
      await tester.pumpAndSettle();
      expect(find.byKey(gitKey), findsNothing);
      expect(find.text('gpt-5.2'), findsOneWidget);
    });

    testWidgets('phase wraps: 2 → git again, -1 → secondary (2 lines)', (
      tester,
    ) async {
      Future<void> pumpAt(int phase) => _pump(
        tester,
        groupBy: HomeGroupBy.repository,
        subtitlePhase: phase,
        git: const GitStatus(branch: 'main'),
        room: const RoomInfo(roomId: 'r1', startedAt: 1, model: 'gpt-5.2'),
      );

      await pumpAt(2);
      await tester.pumpAndSettle();
      expect(find.byKey(gitKey), findsOneWidget);

      await pumpAt(-1);
      await tester.pumpAndSettle();
      expect(find.byKey(secondaryKey), findsOneWidget);
      expect(find.byKey(gitKey), findsNothing);
    });

    testWidgets('by-model: cycles git ↔ last prompt, model never shows', (
      tester,
    ) async {
      await _pump(
        tester,
        subtitlePhase: 1,
        git: const GitStatus(branch: 'main'),
        lastPrompt: 'fix the relay keepalive',
        room: const RoomInfo(roomId: 'r1', startedAt: 1, model: 'gpt-5.2'),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('session-tile-last-prompt')),
        findsOneWidget,
      );
      expect(find.text('fix the relay keepalive'), findsOneWidget);
      expect(find.byKey(gitKey), findsNothing);
      // The group header owns the model; it never takes a cycle slot.
      expect(find.textContaining('gpt-5.2'), findsNothing);
    });

    testWidgets(
      'three lines (git + model + last response): phases 0/1/2 and wrap at 3',
      (tester) async {
        final responseAt = DateTime.now().subtract(const Duration(minutes: 5));
        Future<void> pumpAt(int phase) => _pump(
          tester,
          groupBy: HomeGroupBy.repository,
          subtitlePhase: phase,
          git: const GitStatus(branch: 'main'),
          room: const RoomInfo(roomId: 'r1', startedAt: 1, model: 'gpt-5.2'),
          lastResponseAt: responseAt,
        );

        await pumpAt(0);
        await tester.pumpAndSettle();
        expect(find.byKey(gitKey), findsOneWidget);

        await pumpAt(1);
        await tester.pumpAndSettle();
        expect(find.text('gpt-5.2'), findsOneWidget);

        await pumpAt(2);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('session-tile-last-response')),
          findsOneWidget,
        );
        expect(find.textContaining('Last response:'), findsOneWidget);

        await pumpAt(3); // wraps back to git
        await tester.pumpAndSettle();
        expect(find.byKey(gitKey), findsOneWidget);
      },
    );

    testWidgets('response-only tile renders it statically, no swipe gesture', (
      tester,
    ) async {
      final deltas = <int>[];
      await _pump(
        tester,
        groupBy: HomeGroupBy.model,
        room: const RoomInfo(roomId: 'r1', startedAt: 1),
        lastResponseAt: DateTime.now().subtract(const Duration(hours: 2)),
        onCycleSubtitle: deltas.add,
      );
      expect(find.textContaining('Last response:'), findsOneWidget);
      expect(find.textContaining('2h ago'), findsOneWidget);
      await tester.drag(find.byType(SessionTile), const Offset(-220, 0));
      await tester.pumpAndSettle();
      expect(deltas, isEmpty);
    });

    testWidgets(
      'single line (git only) → no drag gesture, callback never fires',
      (tester) async {
        final deltas = <int>[];
        await _pump(
          tester,
          groupBy: HomeGroupBy.repository,
          git: const GitStatus(branch: 'main'),
          room: const RoomInfo(roomId: 'r1', startedAt: 1),
          onCycleSubtitle: deltas.add,
        );
        await tester.drag(find.byType(SessionTile), const Offset(-220, 0));
        await tester.pumpAndSettle();
        expect(deltas, isEmpty);
      },
    );

    testWidgets('no cyclable lines → Last paired fallback, no gesture', (
      tester,
    ) async {
      final deltas = <int>[];
      await _pump(
        tester,
        groupBy: HomeGroupBy.model,
        room: const RoomInfo(roomId: 'r1', startedAt: 1),
        onCycleSubtitle: deltas.add,
      );
      expect(find.textContaining('Last paired:'), findsOneWidget);
      await tester.drag(find.byType(SessionTile), const Offset(-220, 0));
      await tester.pumpAndSettle();
      expect(deltas, isEmpty);
    });
  });
}
