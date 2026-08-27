import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/git_status_span.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A row in the Home list.
///
/// Renders an inline presence dot (plano 12) driven by
/// [ConnectionManager.presenceStream]: green = online, grey = offline,
/// no dot = relay hasn't reported yet.
class SessionTile extends StatelessWidget {
  final PeerRecord peer;

  /// `true` when the room is announced live on the relay AND the
  /// relay itself is reachable. Drives the green dot.
  final bool isLive;

  /// `true` when the WS to the relay is currently retrying / down.
  /// Overrides `isLive` and renders an amber "reconnecting" dot —
  /// the app has no fresh signal on any room right now.
  final bool isReconnecting;

  /// Plan-18 follow-up — `true` when the agent in this room is
  /// currently producing a response. Highest-priority colour (blue).
  final bool isWorking;
  final RoomInfo? room;

  /// Plan/107b — on-demand git snapshot for this session (when fetched).
  /// When present, replaces the model subtitle with a compact posh-git
  /// summary (branch / ahead / behind / dirty / stash).
  final GitStatus? git;
  final VoidCallback onOpen;

  /// Plan/tablet — `true` when this is the session shown in the tablet's
  /// detail pane. Paints the accent left-bar + faint fill from the mock.
  /// Always `false` on phone (no persistent selection there).
  final bool isSelected;

  /// Plan-17 follow-up — long-press context menu. Caller wires the
  /// dialog (rename + delete-offline). Optional; when null the tile
  /// only responds to tap.
  final VoidCallback? onLongPress;

  /// Plan/132 — `true` when completion notifications are toggled on for
  /// this session. Paints a small bell glyph next to the presence dot so
  /// the state is visible at a glance on the Home list.
  final bool notifyOnDone;

  const SessionTile({
    super.key,
    required this.peer,
    required this.isLive,
    required this.onOpen,
    this.room,
    this.git,
    this.isReconnecting = false,
    this.isWorking = false,
    this.isSelected = false,
    this.onLongPress,
    this.notifyOnDone = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.bg,
      child: InkWell(
        onTap: onOpen,
        onLongPress: onLongPress,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isSelected
                ? colors.accent.withValues(alpha: 0.06)
                : colors.bg,
            border: Border(
              left: BorderSide(
                color: isSelected ? colors.accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Padding(
            // Trim the left inset by the 3px accent bar so content stays
            // aligned whether selected or not.
            padding: EdgeInsets.fromLTRB(isSelected ? 15 : 18, 14, 18, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _Avatar(name: _avatarName()),
                const SizedBox(width: 14),
                Expanded(
                  child: _TitleBlock(peer: peer, room: room, git: git),
                ),
                if (notifyOnDone) ...[
                  // Plan/132 — muted bell so it never competes with the
                  // presence dot; it's a state marker, not an alert.
                  Icon(LucideIcons.bell, size: 13, color: colors.muted),
                  const SizedBox(width: 8),
                ],
                _PresenceDot(
                  isLive: isLive,
                  isReconnecting: isReconnecting,
                  isWorking: isWorking,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _avatarName() {
    final r = room;
    if (r != null) {
      if (r.name != null && r.name!.isNotEmpty) return r.name!;
      final cwd = r.cwd;
      if (cwd != null && cwd.isNotEmpty) {
        final segs = cwd.split('/').where((s) => s.isNotEmpty).toList();
        if (segs.isNotEmpty) return segs.last;
      }
    }
    if (peer.nickname?.isNotEmpty == true) return peer.nickname!;
    return peer.sessionName;
  }
}

class _PresenceDot extends StatelessWidget {
  final bool isLive;
  final bool isReconnecting;
  final bool isWorking;
  const _PresenceDot({
    required this.isLive,
    required this.isReconnecting,
    this.isWorking = false,
  });

  @override
  Widget build(BuildContext context) {
    // Plan-18 follow-up — 4-state dot. Priority high → low:
    //   working (agent streaming)   → blue
    //   reconnecting (relay down)   → amber
    //   live (relay up + announced) → green
    //   else (cached / offline)     → grey
    final colors = context.colors;
    final Color color = isWorking
        ? colors.working
        : isReconnecting
        ? colors.warning
        : isLive
        ? colors.success
        : colors.muted;
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

class _TitleBlock extends StatelessWidget {
  final PeerRecord peer;
  final RoomInfo? room;
  final GitStatus? git;
  const _TitleBlock({required this.peer, required this.room, this.git});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final r = room;
    // Title preference: explicit room.name → cwd basename → peer
    // nickname → session name. The cwd path line was dropped on purpose
    // — the tile now shows just title + subtitle (model / paired date).
    final String title;
    if (r != null) {
      if (r.name != null && r.name!.isNotEmpty) {
        title = r.name!;
      } else if (r.cwd != null && r.cwd!.isNotEmpty) {
        final segs = r.cwd!.split('/').where((s) => s.isNotEmpty).toList();
        title = segs.isNotEmpty ? segs.last : r.cwd!;
      } else if (peer.nickname?.isNotEmpty == true) {
        title = peer.nickname!;
      } else {
        title = peer.sessionName;
      }
    } else {
      title = peer.nickname?.isNotEmpty == true
          ? peer.nickname!
          : peer.sessionName;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: colors.text,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 3),
        // Plan/107b — a fetched git snapshot takes precedence over the
        // model subtitle (it's the glanceable status the user asked for
        // in the session list); otherwise fall back to the model /
        // "Last paired" so the row keeps a stable height.
        Builder(
          builder: (_) {
            if (git != null) {
              return Text.rich(
                TextSpan(children: gitStatusSpans(git!, colors)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            }
            final model = room?.model;
            final hasModel = model != null && model.isNotEmpty;
            return Text(
              hasModel
                  ? _truncateModel(model)
                  : 'Last paired: ${_relativeTime(peer.pairedAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: hasModel ? colors.accent : colors.muted,
                fontSize: 12,
                fontFamily: kMonoFamily,
              ),
            );
          },
        ),
      ],
    );
  }
}

String _truncateModel(String name) =>
    name.length <= 24 ? name : '${name.substring(0, 21)}…';

class _Avatar extends StatelessWidget {
  final String name;
  const _Avatar({required this.name});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final initial = _initial(name);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colors.surface,
        border: Border.all(color: colors.border),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: colors.accent,
          fontFamily: kMonoFamily,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

String _initial(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  return trimmed.characters.first.toUpperCase();
}

String _relativeTime(String isoUtc) {
  final parsed = DateTime.tryParse(isoUtc);
  if (parsed == null) return isoUtc;
  final now = DateTime.now().toUtc();
  final diff = now.difference(parsed);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return isoUtc.substring(0, 10);
}
