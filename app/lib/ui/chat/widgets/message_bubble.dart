import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/copy_button.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:app/ui/chat/widgets/linkified_text.dart';
import 'package:app/ui/chat/widgets/message_stamp.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// ---------------------------------------------------------------------------
// UserBubble — right-aligned dark card
// ---------------------------------------------------------------------------

class UserBubble extends StatelessWidget {
  final UserMsg message;

  /// Plan/172 — show the clock stamp (when the message was sent / accepted)
  /// under the bubble. Off by default: the transcript passes the user's
  /// "Show message timestamps" setting down; a bare bubble shows no stamp.
  final bool showStamp;
  const UserBubble(this.message, {super.key, this.showStamp = false});

  @override
  Widget build(BuildContext context) {
    // Plan/24-fix-app-source-of-truth: render the lifecycle stage of
    // the bubble. `pending` (sent over WS, Pi hasn't echoed yet) gets
    // reduced opacity + a small spinner; `failed` (no echo in 15s) gets
    // a red exclamation badge so the user knows to retry.
    final isPending = message.status == UserMsgStatus.pending;
    final isFailed = message.status == UserMsgStatus.failed;
    final isSteering = message.steering;
    final isFollowUp = message.followUp;
    final hasStatus = isPending || isSteering || isFailed;
    // Plan/172 — the stamp shares the status caption's row (one muted line
    // under the bubble either way). A pending send already shows the phone's
    // send time; the Pi's echo then replaces it (see SyncService).
    final hasStamp = showStamp && message.ts != null;
    // Plan/30 — when an image is attached the bubble becomes an ImageBubble
    // (thumbnail + caption); otherwise the existing text card.
    final image = message.image;
    final colors = context.colors;
    final typo = context.typo;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Opacity(
              opacity: isPending ? 0.6 : 1.0,
              child: image != null
                  ? ImageBubble(
                      image: image,
                      caption: message.text,
                      isFailed: isFailed,
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: colors.userBubble,
                        borderRadius: BorderRadius.circular(12),
                        border: isFailed
                            ? Border.all(color: colors.error, width: 1)
                            : isSteering
                            ? Border.all(
                                color: colors.accent.withValues(alpha: 0.5),
                                width: 1,
                              )
                            : isFollowUp
                            ? Border.all(
                                color: colors.muted.withValues(alpha: 0.5),
                                width: 1,
                              )
                            : null,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 10,
                      ),
                      // Selectable (so the user can copy their own message) AND
                      // link-aware — bare HTTP(S) URLs become tappable. The
                      // agent reply is handled by AgentMarkdown.
                      // Plan/127 — steer/follow-up bubbles carry a type glyph
                      // (route / clock) so the delivery mode is visible at a
                      // glance; normal bubbles render text-only as before.
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (isSteering || isFollowUp) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 2, right: 7),
                              child: Icon(
                                isSteering
                                    ? LucideIcons.route
                                    : LucideIcons.clock,
                                size: 13,
                                color: isSteering
                                    ? colors.accent
                                    : colors.muted,
                              ),
                            ),
                          ],
                          Flexible(
                            child: LinkifiedText(
                              message.text,
                              style: typo.sansBody.copyWith(
                                color: colors.text,
                              ),
                              linkStyle: typo.sansBody.copyWith(
                                color: colors.accent,
                                decoration: TextDecoration.underline,
                                decorationColor: colors.accent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            if (hasStatus || hasStamp)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isPending || isSteering) ...[
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          color: colors.muted,
                          strokeWidth: 1.2,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isFollowUp
                            ? 'queued · next turn'
                            : isSteering
                            ? 'steering…'
                            : 'sending…',
                        style: typo.sansBody.copyWith(
                          color: colors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ] else if (isFailed) ...[
                      Icon(
                        LucideIcons.circleAlert,
                        size: 12,
                        color: colors.error,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'not delivered',
                        style: typo.sansBody.copyWith(
                          color: colors.error,
                          fontSize: 11,
                        ),
                      ),
                    ],
                    if (hasStamp)
                      Padding(
                        padding: EdgeInsets.only(left: hasStatus ? 7 : 0),
                        child: MessageStamp(message.ts),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CompactionBubble — centered system card (plan/32)
// ---------------------------------------------------------------------------

/// A system message distinct from user/assistant: shows that the Pi compacted
/// the context, with the recap summary and the reclaimed token count. Mirrors
/// the TUI's CompactionSummaryMessageComponent.
class CompactionBubble extends StatelessWidget {
  final CompactionMsg message;
  const CompactionBubble(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = message.tokensBefore;
    final summary = message.summary;
    final colors = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.check, size: 13, color: colors.success),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Context compacted',
                      style: TextStyle(
                        fontFamily: kMonoFamily,
                        fontSize: 12,
                        color: colors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (tokens != null)
                    Text(
                      '~$tokens tokens',
                      style: TextStyle(
                        fontFamily: kMonoFamily,
                        fontSize: 11,
                        color: colors.muted,
                      ),
                    ),
                ],
              ),
              if (summary.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  summary,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 12,
                    color: colors.muted2,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AssistantBubble — left-aligned monospace text
// ---------------------------------------------------------------------------

class AssistantBubble extends StatelessWidget {
  final AssistantMsg message;

  /// Plan/172 — show the clock stamp (when the LLM reply started) beside the
  /// Copy button. Off by default; see [UserBubble.showStamp].
  final bool showStamp;
  const AssistantBubble(this.message, {super.key, this.showStamp = false});

  @override
  Widget build(BuildContext context) {
    // Plan/32b — agent output is rendered as Markdown (GFM + code blocks),
    // spanning the FULL content width (the message list already pads 16px on
    // each side) — unlike the user's right-aligned chat bubble, which stays
    // capped. Selectable so prose/code can be copied.
    final hasCopy = message.text.isNotEmpty;
    // Plan/172 — the stamp is when the reply STARTED (the Pi's
    // assistant-message time), the same value a replay of this row carries.
    final hasStamp = showStamp && message.ts != null;
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AgentMarkdown(message.text, selectable: true),
          // One-tap copy of the whole reply (hidden when empty: a finalized
          // turn that produced no text has nothing to copy) + the stamp.
          if (hasCopy || hasStamp)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  if (hasCopy) CopyButton(text: message.text, label: 'Copy'),
                  if (hasStamp)
                    Padding(
                      padding: EdgeInsets.only(left: hasCopy ? 10 : 2),
                      child: MessageStamp(message.ts),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
