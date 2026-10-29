import 'package:app/data/preferences/preferences.dart' show HomeGroupBy;
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter/foundation.dart' show listEquals, mapEquals;

sealed class HomeState {
  const HomeState();
}

class HomeLoading extends HomeState {
  const HomeLoading();
}

class HomeNoPeer extends HomeState {
  const HomeNoPeer();
}

/// Plan 17 — single row on Home: a Pi room (per-cwd session) bound to
/// a paired Mac. Multiple HomeItems per peer when the Mac runs more
/// than one Pi session. When `roomId == 'main'` (the only room from a
/// legacy/single-cwd Pi), the UI may collapse the cwd subtitle.
class HomeItem {
  final PeerRecord peer;
  final RoomInfo room;

  const HomeItem({required this.peer, required this.room});

  /// Display name preference: explicit room.name → cwd basename →
  /// `<peer-nickname>` → fallback session_name.
  String get displayName {
    if (room.name != null && room.name!.isNotEmpty) return room.name!;
    final cwd = room.cwd;
    if (cwd != null && cwd.isNotEmpty) {
      final last = cwd.split('/').where((s) => s.isNotEmpty).toList();
      if (last.isNotEmpty) return last.last;
    }
    if (peer.nickname != null && peer.nickname!.isNotEmpty) {
      return peer.nickname!;
    }
    return peer.sessionName;
  }

  @override
  bool operator ==(Object other) =>
      other is HomeItem &&
      other.peer.remoteEpk == peer.remoteEpk &&
      other.room == room;

  @override
  int get hashCode => Object.hash(peer.remoteEpk, room);
}

/// One labelled section in the grouped Home session list.
class HomeGroup {
  final String label;
  final List<HomeItem> items;
  final bool isFallback;

  const HomeGroup({
    required this.label,
    required this.items,
    this.isFallback = false,
  });
}

/// Groups sessions by model or repository while retaining their existing
/// tiles and actions. Fallback sections sort last so known values stay
/// prominent; keeper mirrors sort after live sessions within each section.
List<HomeGroup> groupHomeItems(
  Iterable<HomeItem> source,
  HomeGroupBy groupBy, {
  GitStatus? Function(HomeItem item)? gitFor,
}) {
  final groups = <String, HomeGroup>{};
  for (final item in source) {
    final git = gitFor?.call(item) ?? item.room.git;
    final grouping = _grouping(item, groupBy, git);
    final group = groups.putIfAbsent(
      grouping.key,
      () => HomeGroup(
        label: grouping.label,
        items: <HomeItem>[],
        isFallback: grouping.isFallback,
      ),
    );
    group.items.add(item);
  }

  final result = groups.values.toList();
  for (final group in result) {
    group.items.sort((a, b) {
      if (a.room.keeper != b.room.keeper) return a.room.keeper ? 1 : -1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
  }
  result.sort((a, b) {
    if (a.isFallback != b.isFallback) return a.isFallback ? 1 : -1;
    return a.label.toLowerCase().compareTo(b.label.toLowerCase());
  });
  return result;
}

/// Grouping identity for one item: the dedupe [key] (stable, full), the
/// display [label], and whether the item lands in a fallback section.
class _ItemGrouping {
  final String key;
  final String label;
  final bool isFallback;
  const _ItemGrouping({
    required this.key,
    required this.label,
    required this.isFallback,
  });
}

_ItemGrouping _grouping(HomeItem item, HomeGroupBy groupBy, GitStatus? git) {
  switch (groupBy) {
    case HomeGroupBy.model:
      final model = item.room.model?.trim();
      final known = model != null && model.isNotEmpty;
      final label = known ? model : 'Unknown model';
      return _ItemGrouping(
        key: '${known ? 'value' : 'fallback'}:${label.toLowerCase()}',
        label: label,
        isFallback: !known,
      );
    case HomeGroupBy.repository:
      if (git == null) {
        return const _ItemGrouping(
          key: 'fallback:no-git',
          label: 'No git repository',
          isFallback: true,
        );
      }
      var identity = git.repository?.trim();
      if (identity == null || identity.isEmpty) {
        // Older extensions publish git status without repository identity.
        // Their cwd basename is a better fallback than calling a repo non-git.
        final cwd = item.room.cwd?.replaceAll('\\', '/').trim();
        final segments = cwd == null || cwd.isEmpty
            ? const <String>[]
            : cwd.split('/').where((part) => part.isNotEmpty).toList();
        identity = segments.isEmpty ? null : segments.last;
      }
      if (identity == null || identity.isEmpty) {
        return const _ItemGrouping(
          key: 'value:unknown',
          label: 'Unknown repository',
          isFallback: false,
        );
      }
      // The section header shows the REPO NAME only — never the owner slug,
      // branch, or worktree. The full identity (`owner/repo`) still keys the
      // group so same-named repositories from different owners never merge.
      final repoName = identity
          .replaceAll('\\', '/')
          .split('/')
          .where((part) => part.isNotEmpty)
          .last;
      return _ItemGrouping(
        key: 'value:${identity.toLowerCase()}',
        label: repoName,
        isFallback: false,
      );
  }
}

/// Paired peers + their live rooms + presence. Items are derived from
/// `roomsByPeer`: a peer with no announced rooms yet still gets one
/// synthetic item (`roomId='main'`) so the user can enter chat — that
/// covers legacy Pis and the pre-room-announce window after reconnect.
class HomeList extends HomeState {
  final List<PeerRecord> peers;
  final Map<String, PresenceState> statusByEpk;
  final Map<String, List<RoomInfo>> roomsByPeer;

  /// Selected organization for the session-list sections.
  final HomeGroupBy groupBy;

  /// Plan/107b — on-demand git status snapshot per session, keyed
  /// `"${standardB64(epk)}|$roomId"`. Populated by [HomeViewModel] when
  /// the user lands on the session list (or pulls to refresh); each entry
  /// rides the existing active-peer-scoped `git_status_request` channel.
  /// `null` = fetched but not a repo / unavailable; absent = not fetched.
  final Map<String, GitStatus?> gitByKey;

  /// Plan 116 — shown when the relay has been non-Online for > 60 s,
  /// nudging the user to the connection-reliability page. Reset to false
  /// when the connection recovers or the user dismisses it.
  final bool showReliabilityBanner;

  /// Security fix 2026-08 (H2) — shown while the app is Online over a
  /// NON-confidential transport (`ws://` to a non-loopback host, i.e. the
  /// default LAN dial). Anyone on the same network can read the traffic.
  /// Not dismissable — it's a property of the connection, not a nudge.
  final bool showInsecureTransportBanner;

  const HomeList({
    required this.peers,
    this.statusByEpk = const {},
    this.roomsByPeer = const {},
    this.groupBy = HomeGroupBy.model,
    this.gitByKey = const {},
    this.showReliabilityBanner = false,
    this.showInsecureTransportBanner = false,
  });

  HomeList copyWith({
    List<PeerRecord>? peers,
    Map<String, PresenceState>? statusByEpk,
    Map<String, List<RoomInfo>>? roomsByPeer,
    HomeGroupBy? groupBy,
    Map<String, GitStatus?>? gitByKey,
    bool? showReliabilityBanner,
    bool? showInsecureTransportBanner,
  }) => HomeList(
    peers: peers ?? this.peers,
    statusByEpk: statusByEpk ?? this.statusByEpk,
    roomsByPeer: roomsByPeer ?? this.roomsByPeer,
    groupBy: groupBy ?? this.groupBy,
    gitByKey: gitByKey ?? this.gitByKey,
    showReliabilityBanner: showReliabilityBanner ?? this.showReliabilityBanner,
    showInsecureTransportBanner:
        showInsecureTransportBanner ?? this.showInsecureTransportBanner,
  );

  /// Flatten to a single ordered list of items: one row per (peer, room).
  /// **Plan-17 follow-up**: peers without any currently-announced rooms
  /// produce ZERO items. Earlier behaviour created a synthetic 'main'
  /// tile for legacy compatibility, but that tile pointed at a (peer,
  /// 'main') destination the Pi was no longer listening on — sending
  /// there got dropped by the relay AND the row felt like a ghost. The
  /// user only wants live rooms in the list.
  ///
  /// Ordering: peers are sorted by display name (nickname → sessionName
  /// → epk prefix), case-insensitive. Within each peer, rooms are
  /// sorted by their display name (room.name → cwd basename → roomId),
  /// also case-insensitive. Keeps the list stable and predictable as
  /// the relay reorders its push payloads.
  List<HomeItem> items({String Function(String)? normalizeEpk}) {
    final sortedPeers = [...peers]
      ..sort(
        (a, b) =>
            _peerLabel(a).toLowerCase().compareTo(_peerLabel(b).toLowerCase()),
      );
    final out = <HomeItem>[];
    for (final p in sortedPeers) {
      final key = normalizeEpk != null
          ? normalizeEpk(p.remoteEpk)
          : p.remoteEpk;
      final rooms = roomsByPeer[key];
      if (rooms == null || rooms.isEmpty) continue;
      final sortedRooms = [...rooms]
        ..sort(
          (a, b) => _roomLabel(
            a,
          ).toLowerCase().compareTo(_roomLabel(b).toLowerCase()),
        );
      for (final r in sortedRooms) {
        // Plan/120 — the device room is a supervisor system daemon, not a
        // user session. Filter it from the Home list.
        if (r.roomId == kDeviceRoom) continue;
        out.add(HomeItem(peer: p, room: r));
      }
    }
    return out;
  }

  static String _peerLabel(PeerRecord p) {
    if (p.nickname != null && p.nickname!.isNotEmpty) return p.nickname!;
    if (p.sessionName.isNotEmpty) return p.sessionName;
    return p.remoteEpk;
  }

  static String _roomLabel(RoomInfo r) {
    if (r.name != null && r.name!.isNotEmpty) return r.name!;
    final cwd = r.cwd;
    if (cwd != null && cwd.isNotEmpty) {
      final segs = cwd.split('/').where((s) => s.isNotEmpty).toList();
      if (segs.isNotEmpty) return segs.last;
    }
    return r.roomId;
  }

  @override
  bool operator ==(Object other) =>
      other is HomeList &&
      other.showReliabilityBanner == showReliabilityBanner &&
      other.showInsecureTransportBanner == showInsecureTransportBanner &&
      other.groupBy == groupBy &&
      listEquals(other.peers, peers) &&
      mapEquals(other.statusByEpk, statusByEpk) &&
      mapEquals(other.roomsByPeer, roomsByPeer) &&
      mapEquals(other.gitByKey, gitByKey);

  @override
  int get hashCode => Object.hash(
    showReliabilityBanner,
    showInsecureTransportBanner,
    groupBy,
    Object.hashAll(peers),
    Object.hashAllUnordered(
      statusByEpk.entries.map((e) => '${e.key}:${e.value.runtimeType}'),
    ),
    Object.hashAllUnordered(
      roomsByPeer.entries.map((e) => '${e.key}:${e.value.length}'),
    ),
    gitByKey.length,
  );
}
