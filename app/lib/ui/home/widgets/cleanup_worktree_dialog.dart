import 'package:app/protocol/protocol.dart' show WireWorktree;
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

  const CleanupWorktreeDialog({
    super.key,
    required this.sessionTitle,
    required this.worktree,
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
          const SizedBox(height: 12),
          Text(
            'Removes the folder and the branch on the computer. Uncommitted '
            'work in that folder is lost. A dirty worktree is refused by git, '
            'so nothing is deleted until it is clean.',
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
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) =>
        CleanupWorktreeDialog(sessionTitle: sessionTitle, worktree: worktree),
  );
  return ok == true;
}
