import 'package:app/data/preferences/preferences.dart' show HomeGroupBy;
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/git_status_span.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A row in the Home list.
///
/// Carries session status in the leading slot/avatar color, driven by
/// [ConnectionManager.presenceStream]: green = online, grey = offline.
/// Working, waiting, and provider-error states reuse the same surface instead
/// of adding a separate presence dot.
///
/// Plan/147 — when the room publishes `context_usage`, a subtle
/// full-height background wedge (width = used fraction of the model's
/// context window) paints behind the row, so scanning the online list
/// shows at a glance which sessions are filling up their context.
class SessionTile extends StatelessWidget {
  /// Plan/tablet + Plan/147 — width of the left selection bar. Three
  /// places must agree on it: the border itself, where the context
  /// fill wedge starts (past the bar), and the content inset trim.
  static const double _leftBarWidth = 3;

  final PeerRecord peer;

  /// `true` when the room is announced live on the relay AND the
  /// relay itself is reachable. Drives the green status color.
  final bool isLive;

  /// `true` when the WS to the relay is currently retrying / down.
  /// Overrides `isLive` and renders an amber "reconnecting" status —
  /// the app has no fresh signal on any room right now.
  final bool isReconnecting;

  /// Plan-18 follow-up — `true` when the agent in this room is
  /// currently producing a response. Blue status — second-highest priority
  /// colour after [isWaitingForInput].
  final bool isWorking;

  /// Plan/134 — `true` when the agent is blocked on a user-facing
  /// ctx.ui prompt (any extension's). Beats `isWorking` in the tri-state
  /// derivation: the room isn't computing, it's waiting for the human.
  /// Renders amber — distinct from the blue working status.
  final bool isWaitingForInput;
  final RoomInfo? room;

  /// Paired-device label shown when grouped sections contain sessions from
  /// more than one computer. Null keeps the single-device tile compact.
  final String? deviceLabel;

  /// Plan/107b — on-demand git snapshot for this session (when fetched).
  /// When both this and the room's model/prompt are available, the
  /// subtitle cycles between them on a horizontal swipe (plan/160, git
  /// first); with only one of the two, that one wins statically
  /// (git → model → "Last paired").
  final GitStatus? git;

  /// Grouped-Home display mode. **By repository**: the tile title shows
  /// the git BRANCH where the folder/repo name used to sit — the group
  /// header already carries the repository, so the branch is what tells
  /// worktree sessions apart (an explicit room name still wins). **By
  /// provider** (plan/161): the model never renders on the tile (the
  /// model sub-label owns it); the subtitle shows the last user prompt
  /// preview instead.
  final HomeGroupBy groupBy;

  /// Grouped Home (provider mode) — single-line preview of the session's
  /// last user prompt (already collapsed + capped by the view model).
  /// `null` when unknown; the subtitle then falls back to git / "Last
  /// paired".
  final String? lastPrompt;

  /// Plan/160 — when the session's last agent response landed. Joins the
  /// cyclable subtitle lines (git → secondary → last response); null when
  /// the session has no response yet.
  final DateTime? lastResponseAt;

  /// Plan/160 — position in the cyclable subtitle lines, remembered per
  /// session by the Home list (raw counter; the tile normalizes it
  /// against however many lines are currently available).
  final int subtitlePhase;

  /// Plan/160 — swipe feedback: +1 = swipe left (next line), -1 = swipe
  /// right (previous). Null → no gesture (caller has no phase storage).
  final void Function(int delta)? onCycleSubtitle;

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
  /// this session. Paints a small bell glyph on the trailing edge so the
  /// state is visible at a glance on the Home list.
  final bool notifyOnDone;

  /// Plan/149 — unread message count (msgs box rows past the session's
  /// read marker). Drives the slot's third line + bold emphasis.
  final int unread;

  /// Plan/149 — opens the linked GitHub ref's URL (slot tap). Null when
  /// the ref has no URL (display-only slot).
  final VoidCallback? onOpenRef;

  const SessionTile({
    super.key,
    required this.peer,
    required this.isLive,
    required this.onOpen,
    this.room,
    this.deviceLabel,
    this.git,
    this.groupBy = HomeGroupBy.provider,
    this.lastPrompt,
    this.isReconnecting = false,
    this.isWorking = false,
    this.isWaitingForInput = false,
    this.isSelected = false,
    this.onLongPress,
    this.notifyOnDone = false,
    this.unread = 0,
    this.onOpenRef,
    this.subtitlePhase = 0,
    this.onCycleSubtitle,
    this.lastResponseAt,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final statusColor = _statusColor(colors);
    final contextFraction = _contextFraction(room?.contextUsage);
    final tile = Material(
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
                width: _leftBarWidth,
              ),
            ),
          ),
          child: Stack(
            children: [
              // Plan/147 — context fill: a full-height wedge behind the
              // row whose width mirrors the model's context-window usage.
              // Starts past the 3px left border (accent when selected,
              // transparent otherwise) so it aligns with the content.
              if (contextFraction != null)
                Positioned.fill(
                  left: _leftBarWidth,
                  child: _ContextFill(
                    fraction: contextFraction,
                    tint: _contextTint(colors, contextFraction),
                  ),
                ),
              Padding(
                // Trim the left inset by the selection bar so content
                // stays aligned whether selected or not.
                padding: EdgeInsets.fromLTRB(
                  isSelected ? 18 - _leftBarWidth : 18,
                  14,
                  18,
                  14,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Plan/149 — the session slot replaces the avatar as
                    // soon as the session has ANY slot content (linked ref,
                    // stats, unread). A bare session keeps its initial.
                    if (_slotHasContent)
                      _SessionSlot(
                        ghRef: room?.ghRef,
                        stats: room?.stats,
                        unread: unread,
                        statusColor: statusColor,
                        onOpen: onOpenRef,
                      )
                    else
                      _Avatar(name: _avatarName(), statusColor: statusColor),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _TitleBlock(
                        peer: peer,
                        room: room,
                        git: git,
                        deviceLabel: deviceLabel,
                        groupBy: groupBy,
                        lastPrompt: lastPrompt,
                        lastResponseAt: lastResponseAt,
                        phase: subtitlePhase,
                      ),
                    ),
                    if (room?.keeper ?? false) ...[
                      // Plan/140 C — durable-history mirror: the room is served
                      // from the transcript by the PC's keeper; no live agent.
                      Icon(LucideIcons.archive, size: 13, color: colors.muted),
                      if (notifyOnDone) const SizedBox(width: 8),
                    ],
                    if (notifyOnDone)
                      // Plan/132 — muted bell so it never competes with the
                      // status color; it's a state marker, not an alert.
                      Icon(LucideIcons.bell, size: 13, color: colors.muted),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Plan/160 — cycling registers only when there is something to cycle
    // through and the caller stores the position. Horizontal drags never
    // fight the vertical list scroll (different axes) and leave tap /
    // long-press to the InkWell above.
    final cycle = onCycleSubtitle;
    if (cycle == null || _cyclableLines < 2) return tile;
    // Direction = net horizontal displacement during the drag (not release
    // velocity): a slow, deliberate swipe cycles just as reliably as a
    // fling, and widget-test drags (velocity 0) hit the same path.
    var dragDx = 0.0;
    return GestureDetector(
      onHorizontalDragStart: (_) => dragDx = 0,
      onHorizontalDragUpdate: (details) => dragDx += details.delta.dx,
      onHorizontalDragEnd: (_) {
        if (dragDx < -_swipeCycleMinDx) cycle(1);
        if (dragDx > _swipeCycleMinDx) cycle(-1);
      },
      child: tile,
    );
  }

  /// Plan/160 — how many subtitle lines the swipe can cycle through (git
  /// summary + secondary); gates the horizontal drag gesture. Must stay
  /// in sync with [_TitleBlock._buildSubtitle].
  int get _cyclableLines {
    final hasGit = git != null;
    final hasSecondary = groupBy == HomeGroupBy.provider
        ? (lastPrompt?.trim().isNotEmpty ?? false)
        : (room?.model ?? '').isNotEmpty;
    return (hasGit ? 1 : 0) +
        (hasSecondary ? 1 : 0) +
        (lastResponseAt != null ? 1 : 0);
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

  /// Plan/149 — slot content exists when anything but "nothing" would
  /// render: a linked ref, known stats, or unread messages. Otherwise the
  /// tile keeps the plain initial avatar.
  bool get _slotHasContent =>
      (room?.ghRef?.display != null) || (room?.stats != null) || unread > 0;

  /// The slot owns the status color now that the separate dot is gone.
  /// Priority high → low: provider error, waiting, working, reconnecting,
  /// live, offline. A cached error only applies to a live room: dead rooms
  /// stay grey and a relay reconnect keeps its amber state.
  Color _statusColor(AppColors colors) {
    if (isLive && (room?.providerError ?? false)) return colors.error;
    if (isWaitingForInput) return colors.warning;
    if (isWorking) return colors.working;
    if (isReconnecting) return colors.warning;
    if (isLive) return colors.success;
    return colors.muted;
  }
}

/// Plan/149 — the session slot: a 44×44 rounded square with three mono
/// lines instead of a letter avatar. Line assignment:
///
///   with ref:   [PR #70 / #12] [T3]        [M7 · 2]
///   without:    [T3]           [M7]       [2]
///
/// Unknown values (pre-149 extension: no stats) render as `·`; a session
/// with neither ref, stats nor unread keeps the initial avatar (never an
/// empty square). Tapping opens the ref's URL when it has one.
/// Border, tinted fill, and every line share the session status color;
/// unread uses font weight rather than introducing a second hue.
class _SessionSlot extends StatelessWidget {
  final GhRef? ghRef;
  final SessionStats? stats;
  final int unread;
  final Color statusColor;
  final VoidCallback? onOpen;

  const _SessionSlot({
    required this.ghRef,
    required this.stats,
    required this.unread,
    required this.statusColor,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final display = ghRef?.display;
    final hasRef = display != null;
    final s = stats;

    final String l1;
    final String l2;
    final String l3;
    if (hasRef) {
      l1 = ghRef!.label;
      l2 = s != null ? 'T${s.turns}' : '·';
      // PR #71 review — without stats (pre-149 extension / legacy tile), a
      // positive unread must still surface on the ref line, not collapse
      // to '·' (linking a session must never hide its unread).
      l3 = s != null
          ? (unread > 0 ? 'M${s.userMsgs}·$unread' : 'M${s.userMsgs}')
          : (unread > 0 ? '$unread' : '·');
    } else {
      l1 = s != null ? 'T${s.turns}' : '·';
      l2 = s != null ? 'M${s.userMsgs}' : '·';
      l3 = unread > 0 ? '$unread' : '·';
    }

    return GestureDetector(
      // No URL → the slot is display-only; the row tap still opens the
      // chat (never swallow the tap).
      onTap: onOpen,
      behavior: onOpen != null
          ? HitTestBehavior.opaque
          : HitTestBehavior.deferToChild,
      child: Container(
        key: const ValueKey('session-tile-session-slot'),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: statusColor.withValues(alpha: 0.10),
          border: Border.all(color: statusColor),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _slotLine(l1, statusColor, emphasis: true),
            const SizedBox(height: 1),
            _slotLine(l2, statusColor),
            const SizedBox(height: 1),
            _slotLine(l3, statusColor, emphasis: unread > 0),
          ],
        ),
      ),
    );
  }

  Widget _slotLine(String text, Color statusColor, {bool emphasis = false}) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      // No explicit lineHeight: with three 8.5px lines the default leading
      // already stacks them inside 44px; forcing one clips the last line.
      style: TextStyle(
        color: statusColor,
        fontFamily: kMonoFamily,
        fontSize: 8.5,
        fontWeight: emphasis ? FontWeight.w600 : FontWeight.w400,
      ),
    );
  }
}

class _TitleBlock extends StatelessWidget {
  final PeerRecord peer;
  final RoomInfo? room;
  final GitStatus? git;
  final String? deviceLabel;
  final HomeGroupBy groupBy;
  final String? lastPrompt;

  /// Plan/160 — when the session's last agent response landed (the last
  /// cyclable subtitle line).
  final DateTime? lastResponseAt;

  const _TitleBlock({
    required this.peer,
    required this.room,
    this.git,
    this.deviceLabel,
    this.groupBy = HomeGroupBy.provider,
    this.lastPrompt,
    this.lastResponseAt,
    this.phase = 0,
  });

  /// Plan/160 — swiped subtitle position (see [SessionTile.subtitlePhase]).
  final int phase;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final peer = this.peer;
    final r = room;
    // Title preference: a name the user actually chose → (by-repo: git
    // branch) → cwd basename → peer nickname → session name. The cwd path
    // line was dropped on purpose — the tile now shows just title +
    // subtitle (model / paired date).
    final String title;
    if (r != null) {
      final name = r.name?.trim();
      if (name != null && name.isNotEmpty && !_isAutoDerivedName(r)) {
        title = name;
      } else if (groupBy == HomeGroupBy.repository) {
        // By-repo: the group header already names the repository, so the
        // title slot carries the BRANCH — the piece that actually tells
        // worktree sessions of the same repo apart.
        final branch = git?.branch.trim();
        if (branch != null && branch.isNotEmpty) {
          title = branch;
        } else {
          title = _fallbackTitle(r, peer);
        }
      } else {
        title = _fallbackTitle(r, peer);
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
        if (deviceLabel != null) ...[
          const SizedBox(height: 3),
          Text(
            deviceLabel!,
            key: const ValueKey('session-tile-device-label'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.muted2,
              fontSize: 10,
              fontFamily: kMonoFamily,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        const SizedBox(height: 3),
        _buildSubtitle(context),
      ],
    );
  }

  static String _fallbackTitle(RoomInfo r, PeerRecord peer) {
    if (r.cwd != null && r.cwd!.isNotEmpty) {
      final segs = r.cwd!.split('/').where((s) => s.isNotEmpty).toList();
      if (segs.isNotEmpty) return segs.last;
    }
    if (peer.nickname?.isNotEmpty == true) return peer.nickname!;
    return peer.sessionName;
  }

  /// PR #81 review — the Pi always publishes a room name: `_displayName(cwd)`
  /// (mesh broker name, configured `agent_name`, or `basename(cwd)`), so an
  /// unrenamed room arrives with a NONEMPTY `name` that is just the folder
  /// name restated. This returns whether [r]'s name is such an auto-derived
  /// identity (cwd basename, the legacy `parent/folder` shape, or either
  /// with the broker's runtime `#N` collision suffix) — those must not beat
  /// the by-repo branch title. A name the user chose (anything else) wins.
  static bool _isAutoDerivedName(RoomInfo r) {
    final cwd = r.cwd?.replaceAll('\\', '/').trim();
    if (cwd == null || cwd.isEmpty) return false;
    final segments = cwd
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) return false;
    final base = segments.last;
    final parent = segments.length >= 2 ? segments[segments.length - 2] : null;
    final name = r.name?.trim();
    if (name == null || name.isEmpty) return true;
    final clean = name.replaceFirst(RegExp(r'#\d+$'), '');
    return clean == base || (parent != null && clean == '$parent/$base');
  }

  /// Plan/107b + plan/160: with BOTH a git snapshot and a secondary line
  /// (model by-repo / last user prompt by-model), a horizontal swipe on
  /// the tile cycles between them (git first), crossfading. With only one
  /// of the two it renders statically (git beats model, as before); with
  /// neither it falls back to "Last paired" so the row keeps a stable
  /// height.
  Widget _buildSubtitle(BuildContext context) {
    final colors = context.colors;
    final git = this.git;
    final model = room?.model;
    final hasModel = model != null && model.isNotEmpty;
    final prompt = lastPrompt?.trim();
    final hasPrompt = prompt != null && prompt.isNotEmpty;

    Widget gitLine() => Text.rich(
      TextSpan(children: gitStatusSpans(git!, colors)),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    Widget modelLine() => Text(
      _modelLabel(model!, room?.contextUsage?.contextWindow),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: colors.accent,
        fontSize: 12,
        fontFamily: kMonoFamily,
      ),
    );
    Widget promptLine() => Text(
      prompt!,
      key: const ValueKey('session-tile-last-prompt'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: colors.muted,
        fontSize: 12,
        fontFamily: kMonoFamily,
      ),
    );
    Widget responseLine() => Text(
      'Last response: ${_relativeTimeFrom(lastResponseAt!)}',
      key: const ValueKey('session-tile-last-response'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: colors.muted,
        fontSize: 12,
        fontFamily: kMonoFamily,
      ),
    );

    Widget? secondaryLine() {
      // Provider-grouped (plan/161: the model sub-label owns the model
      // name): the prompt replaces the model phase entirely. By-repo keeps
      // the model line.
      if (groupBy == HomeGroupBy.provider) {
        return hasPrompt ? promptLine() : null;
      }
      return hasModel ? modelLine() : null;
    }

    final cyclable = <Widget>[
      if (git != null)
        KeyedSubtree(key: const ValueKey('git'), child: gitLine()),
      if (secondaryLine() case final secondary?)
        KeyedSubtree(
          key: const ValueKey('session-tile-subtitle-secondary'),
          child: secondary,
        ),
      if (lastResponseAt != null) responseLine(),
    ];
    if (cyclable.length > 1) {
      // Plan/160 — normalized against the CURRENT line count, so an
      // arriving/departing git snapshot or prompt degrades gracefully
      // instead of going out of range.
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: cyclable[_phaseIndex(phase, cyclable.length)],
      );
    }
    if (cyclable.isNotEmpty) return cyclable.first;
    return Text(
      'Last paired: ${_relativeTime(peer.pairedAt)}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: colors.muted,
        fontSize: 12,
        fontFamily: kMonoFamily,
      ),
    );
  }
}

/// `claude-sonnet-4-5 · 200k` — model display name plus the model's
/// context window (from the live `context_usage` meta), so a glance at
/// the Home list shows WHICH model runs and how much runway it has.
/// Windows below 1k render no suffix — `(400/1000).round()` would paint
/// a misleading `· 0k`. Without usage the plain truncated name renders,
/// exactly as before.
String _modelLabel(String name, int? contextWindow) {
  final suffix = (contextWindow == null || contextWindow < 1000)
      ? ''
      : ' · ${(contextWindow / 1000).round()}k';
  final trimmed = name.length <= 24 ? name : '${name.substring(0, 21)}…';
  return '$trimmed$suffix';
}

/// Plan/147 — fraction of the model's context window in use, or null
/// when unknown (`context_usage` starts flowing after the first LLM
/// response). Prefers the SDK-reported `percent`, falls back to
/// `tokens / contextWindow`; a null `percent` right after compaction
/// still yields a bar from raw token counts.
double? _contextFraction(ContextUsage? usage) {
  if (usage == null) return null;
  final double? raw = usage.percent != null
      ? usage.percent! / 100
      : usage.tokens != null
      ? usage.tokens! / usage.contextWindow
      : null;
  if (raw == null) return null;
  return raw.clamp(0.0, 1.0);
}

/// Pressure tint for the context fill. The 17/24/35/50 ladder is
/// user-tuned (plan/147 device review): a pi session gets compacted or
/// wrapped LONG before the raw window fills, so by the time the chat
/// meter would call 70% "warm", this list already needs to point at the
/// session — 50% of the window is "compact now" territory.
///
/// Prominence rises monotonically: the alpha steps up at EVERY threshold
/// and the hue escalates accent → warning → error.
///
/// The tint switches INSTANTLY between bands (no color tween): pressure
/// bands are discrete states — like the chat pill — while the width
/// animation below already eases the continuous part of the signal.
Color _contextTint(AppColors colors, double fraction) {
  if (fraction >= 0.50) return colors.error.withValues(alpha: 0.18);
  if (fraction >= 0.35) return colors.warning.withValues(alpha: 0.14);
  if (fraction >= 0.24) return colors.warning.withValues(alpha: 0.10);
  if (fraction >= 0.17) return colors.accent.withValues(alpha: 0.09);
  return colors.accent.withValues(alpha: 0.05);
}

/// Plan/147 — the context-window fill behind a tile: a full-height wedge
/// anchored left, its width the used fraction of the model's context
/// window. The width eases between values so a long-running turn visibly
/// "fills" the tile instead of snapping at response boundaries.
class _ContextFill extends StatelessWidget {
  final double fraction;
  final Color tint;

  const _ContextFill({required this.fraction, required this.tint});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedFractionallySizedBox(
        key: const ValueKey('session-tile-context-fill'),
        widthFactor: fraction.clamp(0.0, 1.0),
        heightFactor: 1.0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            // Soft right edge: reads as a gauge, not a stuck overlay;
            // flush on the left where it meets the tile border.
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(6),
            ),
          ),
        ),
      ),
    );
  }
}

/// Plan/160 — minimum net horizontal displacement (logical px) before a
/// drag counts as a cycle swipe. The recognizer's own touch slop already
/// filters jitter; this only rejects sub-slop drags held past recognition.
const double _swipeCycleMinDx = 16;

/// Plan/160 — positive modulo: swiping back from line 0 wraps to the last
/// line instead of going negative (Dart's `%` keeps the sign).
int _phaseIndex(int phase, int lineCount) =>
    lineCount <= 1 ? 0 : ((phase % lineCount) + lineCount) % lineCount;

class _Avatar extends StatelessWidget {
  final String name;
  final Color statusColor;
  const _Avatar({required this.name, required this.statusColor});

  @override
  Widget build(BuildContext context) {
    final initial = _initial(name);
    return Container(
      key: const ValueKey('session-tile-avatar'),
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Legacy fallback tiles must not lose status when the dot is absent.
        color: statusColor.withValues(alpha: 0.10),
        border: Border.all(color: statusColor),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: statusColor,
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

/// Plan/160 — relative time for a [DateTime] (the last-response line);
/// same buckets as [_relativeTime].
String _relativeTimeFrom(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}mo ago';
  return dt.toUtc().toIso8601String().substring(0, 10);
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
