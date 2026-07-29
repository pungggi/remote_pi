import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Plan/108 + plan/112b — "New worktree" branch-name prompt.
///
/// The [TextEditingController] is owned by this [StatefulWidget]'s [State]
/// (created in [initState], disposed in [dispose]) on purpose. The earlier
/// inline version created the controller as a local and disposed it via
/// `showDialog(...).whenComplete(controller.dispose)` — but `whenComplete`
/// runs synchronously right after `Navigator.pop` resolves, *before* the
/// dialog's `EditableTextState` has finished its deferred focus teardown (a
/// microtask). When a focus change fired on the still-subscribed
/// `EditableTextState` after that early disposal — e.g. the reconnect storm
/// from `HomeViewModel.openTerminal`'s `switchTo` — it touched the disposed
/// controller ("A TextEditingController was used after being disposed") and
/// cascaded into `_dependents.isEmpty`. Owning the controller in [State]
/// disposes it *during* element teardown (depth-first: children first),
/// after the `EditableText` has unsubscribed.
class BranchNameDialog extends StatefulWidget {
  const BranchNameDialog({super.key});

  @override
  State<BranchNameDialog> createState() => _BranchNameDialogState();
}

class _BranchNameDialogState extends State<BranchNameDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AlertDialog(
      backgroundColor: colors.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.border),
      ),
      title: Text(
        'New worktree',
        style: TextStyle(fontFamily: kMonoFamily, fontSize: 15, color: colors.text),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Creates a git worktree off this project on a new branch, '
            'then opens a terminal running pi inside it.',
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            style: TextStyle(fontFamily: kMonoFamily, fontSize: 14, color: colors.text),
            decoration: InputDecoration(
              hintText: 'branch name',
              hintStyle: TextStyle(fontFamily: kMonoFamily, color: colors.muted),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text('Cancel', style: TextStyle(fontFamily: kMonoFamily, color: colors.muted)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text('Create', style: TextStyle(fontFamily: kMonoFamily, color: colors.accent)),
        ),
      ],
    );
  }
}
