import 'package:app/protocol/protocol.dart' show GhRef, WireWorktree;
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Plan/148 — confirmation for "Delete worktree & branch".
///
/// Destructive and irreversible, so it names the concrete target instead of
/// asking a generic "are you sure?": the branch, the base repo and the folder
/// that will disappear. The dirty-state caveat is spelled out because the most
/// common failure ("git refused, nothing removed") must not look like a bug.
///
/// Body is a plain [StatelessWidget] so a widget test can pump it without
/// going through a full Home page.
class CleanupWorktreeDialog extends StatelessWidget {
  /// Session title shown as the first row, so the user can pattern-match the
  /// dialog against the tile they long-pressed.
  final String sessionTitle;
  final WireWorktree worktree;

  /// Plan/149 — the session's linked GitHub ref (if any). Shown as its own
  /// row so the dialog names EVERYTHING the session is tied to, and an
  /// OPEN-state PR upgrades the warning: deleting the branch likely kills
  /// review state on a live PR.
  final GhRef? ghRef;

  const CleanupWorktreeDialog({
    super.key,
    required this.sessionTitle,
    required this.worktree,
    this.ghRef,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mono = TextStyle(fontFamily: kMonoFamily, fontSize: 12);
    return AlertDialog(
      backgroundColor: colors.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.border),
      ),
      title: Text(
        'Delete worktree & branch?',
        style: TextStyle(
          fontFamily: kMonoFamily,
          fontSize: 15,
          color: colors.text,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(context, 'Session', sessionTitle, colors.text, mono),
          const SizedBox(height: 6),
          _row(context, 'Branch', worktree.branch, colors.accent, mono),
          const SizedBox(height: 6),
          _row(context, 'Base repo', worktree.base, colors.muted, mono),
          const SizedBox(height: 6),
          _row(context, 'Folder', worktree.path, colors.muted, mono),
          if (ghRef?.display != null) ...[
            const SizedBox(height: 6),
            _row(
              context,
              'Linked',
              ghRef!.label,
              _isOpenPr(ghRef!) ? colors.warning : colors.muted,
              mono,
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Removes the folder and the branch on the computer. Uncommitted '
            'work in that folder is lost. A dirty worktree is refused by git, '
            'so nothing is deleted until it is clean.',
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
          // Plan/149 — the linked PR is still open (or unknown state): the
          // branch this deletion removes is the one the PR is built on.
          if (_isOpenPr(ghRef)) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_outlined,
                    size: 14, color: colors.warning),
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
          const SizedBox(height: 6),
          Text(
            'The chat history stays on the computer, so the session may '
            'reappear in this list as an archive entry.',
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            'Cancel',
            style: TextStyle(fontFamily: kMonoFamily, color: colors.muted),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            'Delete',
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
    Color color,
    TextStyle mono,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 10, color: context.colors.muted),
        ),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: mono.copyWith(color: color),
        ),
      ],
    );
  }
}

/// Shows [CleanupWorktreeDialog]; `true` only when the user confirmed.
Future<bool> showCleanupWorktreeDialog(
  BuildContext context, {
  required String sessionTitle,
  required WireWorktree worktree,
  GhRef? ghRef,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => CleanupWorktreeDialog(
      sessionTitle: sessionTitle,
      worktree: worktree,
      ghRef: ghRef,
    ),
  );
  return ok == true;
}
