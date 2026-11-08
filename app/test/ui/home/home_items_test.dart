// Plan 17 — HomeList.items() flattens peers × rooms into tile rows.

import 'package:app/data/preferences/preferences.dart' show HomeGroupBy;
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:flutter_test/flutter_test.dart';

PeerRecord _peer(String epk, {String name = 'Pi'}) => PeerRecord(
  remoteEpk: epk,
  sessionName: name,
  relayUrl: 'ws://x',
  pairedAt: '2026-01-01T00:00:00Z',
);

void main() {
  group('HomeList.items()', () {
    test('peer without announced rooms produces ZERO items — Home only '
        'shows what is currently live on the relay (no ghost "main" tile)', () {
      final list = HomeList(peers: [_peer('A')]);
      final items = list.items();
      expect(items, isEmpty);
    });

    test('peer with N rooms produces N items (one row per cwd)', () {
      final list = HomeList(
        peers: [_peer('A')],
        roomsByPeer: {
          'A': [
            const RoomInfo(roomId: 'r1', startedAt: 1, cwd: '/one'),
            const RoomInfo(roomId: 'r2', startedAt: 2, cwd: '/two'),
          ],
        },
      );
      final items = list.items();
      expect(items, hasLength(2));
      expect(items.map((i) => i.room.roomId).toList(), ['r1', 'r2']);
    });

    test('multiple peers each contribute their own group of rows; the '
        'flat list keeps peer-order from `peers`', () {
      final list = HomeList(
        peers: [_peer('A'), _peer('B')],
        roomsByPeer: {
          'A': [const RoomInfo(roomId: 'a1', startedAt: 1)],
          'B': [
            const RoomInfo(roomId: 'b1', startedAt: 1),
            const RoomInfo(roomId: 'b2', startedAt: 2),
          ],
        },
      );
      final items = list.items();
      expect(items.map((i) => i.peer.remoteEpk).toList(), ['A', 'B', 'B']);
      expect(items.map((i) => i.room.roomId).toList(), ['a1', 'b1', 'b2']);
    });

    test('HomeItem.displayName prefers room.name → cwd basename', () {
      final namedRoom = HomeItem(
        peer: _peer('A'),
        room: const RoomInfo(
          roomId: 'r1',
          startedAt: 1,
          name: 'project-alpha',
          cwd: '/whatever',
        ),
      );
      expect(namedRoom.displayName, 'project-alpha');

      final cwdRoom = HomeItem(
        peer: _peer('A'),
        room: const RoomInfo(
          roomId: 'r1',
          startedAt: 1,
          cwd: '/Users/jacob/projects/remote_pi/app',
        ),
      );
      expect(cwdRoom.displayName, 'app');
    });
  });

  group('groupHomeItems()', () {
    test('groups by model and puts unknown models last', () {
      final list = HomeList(
        peers: [_peer('A')],
        roomsByPeer: {
          'A': [
            const RoomInfo(
              roomId: 'a',
              startedAt: 1,
              name: 'Project A',
              model: 'GLH-5.3',
            ),
            const RoomInfo(
              roomId: 'b',
              startedAt: 2,
              name: 'Project B',
              model: 'GLH-5.3',
            ),
            const RoomInfo(
              roomId: 'z',
              startedAt: 3,
              name: 'Project Z',
              model: 'Kimi K3.1 Pro',
            ),
            const RoomInfo(roomId: 'legacy', startedAt: 4, name: 'Legacy'),
          ],
        },
      );

      // Plan/161 — the provider enum value drives the MODEL level (the
      // nesting inside a provider section).
      final groups = groupHomeItems(list.items(), HomeGroupBy.provider);
      expect(groups.map((group) => group.label), [
        'GLH-5.3',
        'Kimi K3.1 Pro',
        'Unknown model',
      ]);
      expect(groups.first.items.map((item) => item.room.roomId), ['a', 'b']);
      expect(groups.last.isFallback, isTrue);
    });

    test('groups worktrees by repository and non-git sessions separately', () {
      const reflex = GitStatus(branch: 'main', repository: 'pungggi/pi-reflex');
      const ps = GitStatus(branch: 'main', repository: 'pungggi/pi-ps');
      final list = HomeList(
        peers: [_peer('A')],
        roomsByPeer: {
          'A': [
            const RoomInfo(
              roomId: 'a',
              startedAt: 1,
              name: 'Project A',
              git: reflex,
            ),
            const RoomInfo(
              roomId: 'z',
              startedAt: 2,
              name: 'Project Z',
              git: reflex,
            ),
            const RoomInfo(
              roomId: 'b',
              startedAt: 3,
              name: 'Project B',
              git: ps,
            ),
            const RoomInfo(roomId: 'scratch', startedAt: 4, name: 'Scratch'),
          ],
        },
      );

      final groups = groupHomeItems(list.items(), HomeGroupBy.repository);
      expect(groups.map((group) => group.label), [
        'pi-ps',
        'pi-reflex',
        'No git repository',
      ]);
      expect(groups[1].items.map((item) => item.room.roomId), ['a', 'z']);
      expect(groups.last.isFallback, isTrue);
    });

    test(
      'repository labels show the repo NAME only — no owner slug, '
      'branch, or worktree — while same-named repos stay separate groups',
      () {
        final list = HomeList(
          peers: [_peer('A')],
          roomsByPeer: {
            'A': [
              const RoomInfo(
                roomId: 'fork',
                startedAt: 1,
                git: GitStatus(
                  branch: 'feat/x',
                  repository: 'pungggi/remote_pi',
                ),
              ),
              const RoomInfo(
                roomId: 'upstream',
                startedAt: 2,
                git: GitStatus(
                  branch: 'main',
                  repository: 'jacobaraujo7/remote_pi',
                ),
              ),
            ],
          },
        );

        final groups = groupHomeItems(list.items(), HomeGroupBy.repository);
        // Same display label, but never merged into one section.
        expect(groups, hasLength(2));
        expect(groups.map((g) => g.label), ['remote_pi', 'remote_pi']);
        expect(groups.map((g) => g.items.map((i) => i.room.roomId).single), [
          'fork',
          'upstream',
        ]);
      },
    );

    test('uses an on-demand git snapshot when the room has none', () {
      final item = HomeItem(
        peer: _peer('A'),
        room: const RoomInfo(roomId: 'a', startedAt: 1),
      );
      final groups = groupHomeItems(
        [item],
        HomeGroupBy.repository,
        gitFor: (_) =>
            const GitStatus(branch: 'main', repository: 'pungggi/pi-reflex'),
      );
      expect(groups.single.label, 'pi-reflex');
    });

    test('legacy git snapshots fall back to cwd instead of no-repository', () {
      final list = HomeList(
        peers: [_peer('A')],
        roomsByPeer: {
          'A': [
            const RoomInfo(
              roomId: 'a',
              startedAt: 1,
              cwd: r'C:\src\local-repo',
              git: GitStatus(branch: 'main'),
            ),
          ],
        },
      );

      final groups = groupHomeItems(list.items(), HomeGroupBy.repository);
      expect(groups.single.label, 'local-repo');
      expect(groups.single.isFallback, isFalse);
    });
  });

  group('groupHomeItemsByProvider() (plan/161)', () {
    test('nests model groups under one provider section; usage scope is the section', () {
      final list = HomeList(
        peers: [_peer('A')],
        roomsByPeer: {
          'A': const [
            RoomInfo(roomId: 'a', startedAt: 1, model: 'GLM 4.7', provider: 'zai'),
            RoomInfo(roomId: 'b', startedAt: 2, model: 'GLM 4.7', provider: 'zai'),
            RoomInfo(roomId: 'c', startedAt: 3, model: 'GLM 4.6', provider: 'zai'),
            RoomInfo(roomId: 'd', startedAt: 4, model: 'Kimi K3.1', provider: 'kimi-coding'),
          ],
        },
      );

      final sections = groupHomeItemsByProvider(list.items());
      expect(sections.map((s) => s.label), ['Kimi', 'z.ai'],
          reason: 'pretty names, alphabetical, fallback last');

      final zai = sections.singleWhere((s) => s.slug == 'zai');
      expect(zai.models.map((m) => m.label), ['GLM 4.6', 'GLM 4.7'],
          reason: 'model groups sorted inside the section');
      expect(zai.itemCount, 3);
      expect(
        zai.models.first.items.map((i) => i.room.roomId),
        ['c'],
        reason: 'tiles keep their group ordering',
      );
      expect(zai.models.last.items.map((i) => i.room.roomId), ['a', 'b']);
    });

    test('rooms without a provider land in the fallback section, last', () {
      final list = HomeList(
        peers: [_peer('A')],
        roomsByPeer: {
          'A': const [
            RoomInfo(roomId: 'old', startedAt: 1, model: 'GLM 4.7'),
            RoomInfo(roomId: 'none', startedAt: 2),
            RoomInfo(roomId: 'z', startedAt: 3, model: 'Kimi K3.1', provider: 'kimi-coding'),
          ],
        },
      );

      final sections = groupHomeItemsByProvider(list.items());
      expect(sections.map((s) => s.label), ['Kimi', 'Unknown provider']);
      final fallback = sections.last;
      expect(fallback.isFallback, isTrue);
      expect(fallback.slug, isNull);
      expect(fallback.models.map((m) => m.label), ['GLM 4.7', 'Unknown model']);
    });

    test('unknown slugs display as the raw slug', () {
      expect(providerDisplayName('zai'), 'z.ai');
      expect(providerDisplayName('anthropic'), 'Anthropic');
      expect(providerDisplayName('acme-llm'), 'acme-llm');
    });

    test('section-scoped usage: ANY online item of the provider supplies the header', () {
      const usage = PlanUsage(provider: 'zai', fetchedAt: 1, windows: [
        PlanUsageWindow(kind: 'time', label: '5h', percent: 10, minutes: 300),
      ]);
      final list = HomeList(
        peers: [_peer('A')],
        roomsByPeer: {
          'A': const [
            // Usage sits on the GLM 4.6 room. The header is section-scoped,
            // so the quota must surface for the whole z.ai section even
            // though a DIFFERENT model group's room carries it.
            RoomInfo(
              roomId: 'a',
              startedAt: 1,
              model: 'GLM 4.7',
              provider: 'zai',
            ),
            RoomInfo(
              roomId: 'b',
              startedAt: 2,
              model: 'GLM 4.6',
              provider: 'zai',
              planUsage: usage,
            ),
          ],
        },
      );

      final zai = groupHomeItemsByProvider(list.items()).single;
      final got = firstOnlinePlanUsage(
        zai.items,
        (it) => it.room.roomId == 'b',
      );
      expect(got?.provider, 'zai');
      // All offline → hidden (plan/156 gating, now section-scoped).
      expect(firstOnlinePlanUsage(zai.items, (_) => false), isNull);
    });
  });
}
