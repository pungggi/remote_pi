import 'package:app/protocol/protocol.dart' show GhRef, WireWorktree;
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Plan/158 — what the user confirmed in [CleanupSessionDialog]. `null`
/// (from [showCleanupSessionDialog]) means cancelled. [removeWorktree] is
/// only meaningful when a tracked worktree was matched; [deleteHistory] is
/// the opt-in PC transcript wipe (default OFF by dialog construction).
class CleanupSessionRequest {
  final bool removeWorktree;
  final bool deleteHistory;

  const CleanupSessionRequest({
    required this.removeWorktree,
    required this.deleteHistory,
  });
}

/// Plan/158 — the consolidated "Clean up session?" confirmation.
///
/// Replaces plan/148's worktree-only dialog: one dialog itemizes EVERY
/// destructive step so a single decision covers the whole cleanup —
///
/// - **Worktree folder + branch**: shown only when the session's folder is a
///   tracked worktree (tap-time registry match); checked by default because
///   leaving the folder behind is the clutter case, but unchecked-able.
/// - **Chat history on the computer**: opt-in, OFF by default (user decision
///   2026-11-06) — cleanup's job is to stop the session from SHOWING; the
///   transcript survives as backup unless explicitly asked for.
/// - **Fixed (no checkbox)**: the PC forgets the session (no resurrection)
///   and the phone copy is removed. These ARE the cleanup.
class CleanupSessionDialog extends StatefulWidget {
  /// Session title shown as the first row, so the user can pattern-match the
  /// dialog against the tile they long-pressed.
  final String sessionTitle;

  /// Tracked-worktree match for this session's folder, or `null` (main
  /// checkout / unregistered folder) — the worktree row is hidden then.
  final WireWorktree? worktree;

  /// The session's linked GitHub ref, when known — an OPEN-state PR upgrades
  /// the warning: deleting the branch likely kills review state.
  final GhRef? ghRef;

  const CleanupSessionDialog({
    super.key,
    required this.sessionTitle,
    this.worktree,
    this.ghRef,
  });

  @override
  State<CleanupSessionDialog> createState() => _CleanupSessionDialogState();
}

class _CleanupSessionDialogState extends State<CleanupSessionDialog> {
  bool _worktreeChecked = true;
  bool _historyChecked = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mono = TextStyle(fontFamily: kMonoFamily, fontSize: 12);
    final worktree = widget.worktree;
    final ghRef = widget.ghRef;
    return AlertDialog(
      backgroundColor: colors.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.border),
      ),
      title: Text(
        'Clean up session?',
        style: TextStyle(
          fontFamily: kMonoFamily,
          fontSize: 15,
          color: colors.text,
        ),
      ),
      content: SingleChildScrollView(
        // Scrollable: with both checkbox rows + a PR warning the content can
        // exceed the dialog cap on small screens (plan/148 review finding 7
        // mindset — never a clipped dialog).
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          _row(context, 'Session', widget.sessionTitle, colors.text, mono),
          if (worktree != null) ...[
            const SizedBox(height: 6),
            _row(context, 'Branch', worktree.branch, colors.accent, mono),
            const SizedBox(height: 6),
            _row(context, 'Folder', worktree.path, colors.muted, mono),
          ],
          if (ghRef?.display != null) ...[
            const SizedBox(height: 6),
            _row(
              context,
              'Linked',
              ghRef!.label,
              _isOpenPr(ghRef) ? colors.warning : colors.muted,
              mono,
            ),
          ],
          const SizedBox(height: 10),
          if (worktree != null)
            _CheckRow(
              key: const Key('cleanup-worktree-check'),
              checked: _worktreeChecked,
              title: 'Delete worktree folder & branch',
              subtitle: 'Removes the folder and the branch on the computer. '
                  'Uncommitted work is lost; a dirty worktree is refused by '
                  'git, so nothing is deleted until it is clean.',
              onChanged: (v) => setState(() => _worktreeChecked = v),
            ),
          _CheckRow(
            key: const Key('cleanup-history-check'),
            checked: _historyChecked,
            title: 'Delete chat history on the computer',
            subtitle: 'Also removes the conversation transcripts. Off by '
                'default: the history stays as a backup unless you ask.',
            onChanged: (v) => setState(() => _historyChecked = v),
          ),
          const SizedBox(height: 10),
          Text(
            'Always: the computer forgets this session, so it will not '
            'reappear in this list — and the copy on this phone is removed.',
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
          if (_isOpenPr(ghRef)) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_outlined,
                  size: 14,
                  color: colors.warning,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'This session is linked to ${ghRef!.label}, which may '
                    'still be open — deleting the branch can break the PR. '
                    'Check it on GitHub first.',
                    style: TextStyle(fontSize: 12, color: colors.warning),
                  ),
                ),
              ],
            ),
          ],
        ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(
            'Cancel',
            style: TextStyle(fontFamily: kMonoFamily, color: colors.muted),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            CleanupSessionRequest(
              removeWorktree: worktree != null && _worktreeChecked,
              deleteHistory: _historyChecked,
            ),
          ),
          child: Text(
            'Clean up',
            style: TextStyle(fontFamily: kMonoFamily, color: colors.error),
          ),
        ),
      ],
    );
  }

  /// `true` when the linked ref is a PR whose state is open or unknown
  /// (unknown counts: pre-149 links and never-refreshed PRs never carry
  /// a state, and erring loud beats silently killing a review branch).
  static bool _isOpenPr(GhRef? ref) {
    if (ref?.pr == null) return false;
    final state = ref!.pr!.state?.toUpperCase();
    return state == null || state == 'OPEN';
  }

  Widget _row(
    BuildContext context,
    String label,
    String value,
    Color valueColor,
    TextStyle style,
  ) {
    final colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
        ),
        Expanded(
          child: Text(value, style: style.copyWith(color: valueColor)),
        ),
      ],
    );
  }
}

/// One checkbox line of the dialog. Stateless on purpose: the dialog owns
/// the checked tallies (it builds the final [CleanupSessionRequest]); this
/// row only renders + forwards taps.
class _CheckRow extends StatelessWidget {
  final bool checked;
  final String title;
  final String subtitle;
  final ValueChanged<bool> onChanged;

  const _CheckRow({
    super.key,
    required this.checked,
    required this.title,
    required this.subtitle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: () => onChanged(!checked),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: checked,
                onChanged: (v) => onChanged(v ?? false),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 13, color: colors.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11, color: colors.muted),
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

/// Shows [CleanupSessionDialog]; returns the confirmed request or `null`.
Future<CleanupSessionRequest?> showCleanupSessionDialog(
  BuildContext context, {
  required String sessionTitle,
  WireWorktree? worktree,
  GhRef? ghRef,
}) {
  return showDialog<CleanupSessionRequest>(
    context: context,
    builder: (_) => CleanupSessionDialog(
      sessionTitle: sessionTitle,
      worktree: worktree,
      ghRef: ghRef,
    ),
  );
}
