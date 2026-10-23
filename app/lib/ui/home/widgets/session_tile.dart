import 'dart:async';

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
  /// relay itself is reachable. Drives the green dot.
  final bool isLive;

  /// `true` when the WS to the relay is currently retrying / down.
  /// Overrides `isLive` and renders an amber "reconnecting" dot —
  /// the app has no fresh signal on any room right now.
  final bool isReconnecting;

  /// Plan-18 follow-up — `true` when the agent in this room is
  /// currently producing a response. Blue dot — second-highest priority
  /// colour after [isWaitingForInput].
  final bool isWorking;

  /// Plan/134 — `true` when the agent is blocked on a user-facing
  /// ctx.ui prompt (any extension's). Beats `isWorking` in the tri-state
  /// derivation: the room isn't computing, it's waiting for the human.
  /// Renders amber — distinct from the blue working dot.
  final bool isWaitingForInput;
  final RoomInfo? room;

  /// Plan/107b — on-demand git snapshot for this session (when fetched).
  /// When both this and the room's model are available, the subtitle
  /// alternates every 3 seconds (branch summary ↔ selected model) in
  /// lock-step across ALL tiles; with only one of the two, that one
  /// wins statically (git → model → "Last paired").
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
    this.isWaitingForInput = false,
    this.isSelected = false,
    this.onLongPress,
    this.notifyOnDone = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final contextFraction = _contextFraction(room?.contextUsage);
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
                  isSelected ? 18 - _leftBarWidth : 18, 14, 18, 14,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _Avatar(name: _avatarName()),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _TitleBlock(peer: peer, room: room, git: git),
                    ),
                    if (room?.keeper ?? false) ...[
                      // Plan/140 C — durable-history mirror: the room is served
                      // from the transcript by the PC's keeper; no live agent.
                      Icon(LucideIcons.archive, size: 13, color: colors.muted),
                      const SizedBox(width: 8),
                    ],
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
                      isWaitingForInput: isWaitingForInput,
                    ),
                  ],
                ),
              ),
            ],
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
  final bool isWaitingForInput;
  const _PresenceDot({
    required this.isLive,
    required this.isReconnecting,
    this.isWorking = false,
    this.isWaitingForInput = false,
  });

  @override
  Widget build(BuildContext context) {
    // Plan/134 — 5-state dot. Priority high → low:
    //   waiting (blocked on a prompt) → amber (distinct from working blue)
    //   working (agent streaming)     → blue
    //   reconnecting (relay down)     → amber
    //   live (relay up + announced)   → green
    //   else (cached / offline)       → grey
    //
    // `waiting` and `reconnecting` share the amber family but can never
    // mislead: waiting implies a live link, and the two states answer
    // different questions ("the agent needs you" vs "we lost the relay").
    // The chat pill disambiguates with a label.
    final colors = context.colors;
    final Color color = isWaitingForInput
        ? colors.warning
        : isWorking
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

/// One clock for the whole list: every [_TitleBlock] listens to the same
/// notifier, so all tiles flip between the branch (git) phase and the
/// model phase in lock-step: a coordinated alternation, not per-tile
/// flicker. Ref-counted: the timer only runs while tiles are mounted,
/// and the phase resets to "branch" when the last one goes away.
class _SubtitleClock {
  static const interval = Duration(seconds: 3);
  static final ValueNotifier<bool> showGitPhase = ValueNotifier<bool>(true);
  static Timer? _timer;
  static int _refs = 0;

  static void retain() {
    _refs++;
    _timer ??= Timer.periodic(interval, (_) {
      showGitPhase.value = !showGitPhase.value;
    });
  }

  static void release() {
    _refs = _refs > 0 ? _refs - 1 : 0;
    if (_refs == 0 && _timer != null) {
      _timer!.cancel();
      _timer = null;
      // Reopening the list starts on the branch phase for a stable
      // first paint.
      if (!showGitPhase.value) showGitPhase.value = true;
    }
  }
}

class _TitleBlock extends StatefulWidget {
  final PeerRecord peer;
  final RoomInfo? room;
  final GitStatus? git;
  const _TitleBlock({required this.peer, required this.room, this.git});

  @override
  State<_TitleBlock> createState() => _TitleBlockState();
}

class _TitleBlockState extends State<_TitleBlock> {
  @override
  void initState() {
    super.initState();
    _SubtitleClock.retain();
  }

  @override
  void dispose() {
    _SubtitleClock.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final peer = widget.peer;
    final r = widget.room;
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
        _buildSubtitle(context),
      ],
    );
  }

  /// Plan/107b + model alternation: with BOTH a git snapshot and a
  /// published model, the line flips every 3 seconds between the
  /// posh-git summary (branch / ahead / behind / dirty / stash) and
  /// the selected model, crossfading in sync with every other tile.
  /// With only one of the two it renders statically (git beats model,
  /// as before); with neither it falls back to "Last paired" so the
  /// row keeps a stable height.
  Widget _buildSubtitle(BuildContext context) {
    final colors = context.colors;
    final git = widget.git;
    final model = widget.room?.model;
    final hasModel = model != null && model.isNotEmpty;

    Widget gitLine() => Text.rich(
          TextSpan(children: gitStatusSpans(git!, colors)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
    Widget modelLine() => Text(
          _modelLabel(model!, widget.room?.contextUsage?.contextWindow),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: colors.accent,
            fontSize: 12,
            fontFamily: kMonoFamily,
          ),
        );

    if (git != null && hasModel) {
      return ValueListenableBuilder<bool>(
        valueListenable: _SubtitleClock.showGitPhase,
        builder: (context, showGit, _) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: showGit
              ? KeyedSubtree(key: const ValueKey('git'), child: gitLine())
              : KeyedSubtree(
                  key: const ValueKey('model'), child: modelLine()),
        ),
      );
    }
    if (git != null) return gitLine();
    if (hasModel) return modelLine();
    return Text(
      'Last paired: ${_relativeTime(widget.peer.pairedAt)}',
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
            borderRadius:
                const BorderRadius.horizontal(right: Radius.circular(6)),
          ),
        ),
      ),
    );
  }
}

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
