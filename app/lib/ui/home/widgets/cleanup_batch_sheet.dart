import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/viewmodels/session_cleanup_report.dart';
import 'package:flutter/material.dart';

/// Plan/158 — "Clean up finished sessions…" batch sheet.
///
/// Three phases inside one sheet (no route pushes, so the flow survives
/// back-swipes):
///
/// 1. **Selecting** — one checkbox per cleanable offline session (all
///    pre-checked), a shared "also delete chat history" toggle (default OFF,
///    same opt-in rule as the single-session dialog), and an honest banner
///    listing PCs that could not be reached (their sessions are skipped).
/// 2. **Running** — progress line; the executor runs per PC with per-item
///    isolation (one failure never aborts the batch).
/// 3. **Results** — one ✓/✗ row per session with the PC's own message.
class CleanupBatchSheet extends StatefulWidget {
  final CleanupBatchPrep prep;

  /// Executes the confirmed selection. Returns one report per plan, in the
  /// same order — [HomeViewModel.cleanupFinishedSessions] semantics.
  final Future<List<SessionCleanupReport>> Function(
    List<SessionCleanupPlan> plans,
    bool deleteHistory,
  ) onConfirm;

  const CleanupBatchSheet({super.key, required this.prep, required this.onConfirm});

  @override
  State<CleanupBatchSheet> createState() => _CleanupBatchSheetState();
}

class _CleanupBatchSheetState extends State<CleanupBatchSheet> {
  late final List<bool> _checked = List.filled(widget.prep.plans.length, true);
  bool _deleteHistory = false;
  bool _running = false;
  List<SessionCleanupReport>? _results;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mono = TextStyle(fontFamily: kMonoFamily, fontSize: 12);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _results == null
                  ? 'Clean up finished sessions?'
                  : _running
                  ? 'Cleaning up…'
                  : 'Cleanup results',
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 15,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 4),
            if (widget.prep.unreachablePeers.isNotEmpty)
                  Text(
                    'Could not reach '
                    '${widget.prep.unreachablePeers.join(', ')} — its '
                    'sessions were skipped.',
                    style: TextStyle(fontSize: 12, color: colors.warning),
                  ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _results == null ? _selectionRows(colors, mono) : _resultRows(colors, mono),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _footer(colors),
          ],
        ),
      ),
    );
  }

  List<Widget> _selectionRows(AppColors colors, TextStyle mono) {
    if (widget.prep.plans.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'No finished sessions to clean up.',
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
        ),
      ];
    }
    return [
      for (var i = 0; i < widget.prep.plans.length; i++)
        _PlanRow(
          key: Key('cleanup-batch-row-$i'),
          plan: widget.prep.plans[i],
          checked: _checked[i],
          mono: mono,
          onChanged: (v) => setState(() => _checked[i] = v),
        ),
    ];
  }

  List<Widget> _resultRows(AppColors colors, TextStyle mono) {
    final results = _results!;
    // Pair by identity (epk, roomId), not by index: the VM groups work per
    // PC and _run may have run a SUBSET of the plans, so index pairing
    // would show the wrong titles (PR #94 review, HIGH).
    final titleByKey = {
      for (final p in widget.prep.plans) '${p.epk}|${p.roomId}': p.sessionTitle,
    };
    return [
      for (final r in results)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                r.ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 16,
                color: r.ok ? colors.accent : colors.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titleByKey['${r.epk}|${r.roomId}'] ?? r.roomId,
                      style: TextStyle(fontSize: 13, color: colors.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      r.message,
                      style: TextStyle(fontSize: 11, color: colors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ];
  }

  Widget _footer(AppColors colors) {
    final plans = widget.prep.plans;
    final selected = [
      for (var i = 0; i < plans.length; i++)
        if (_checked[i]) plans[i],
    ];
    if (_results != null) {
      return Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Done',
            style: TextStyle(fontFamily: kMonoFamily, color: colors.accent),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (plans.isNotEmpty)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  'Also delete chat history on the computers',
                  style: TextStyle(fontSize: 13, color: colors.text),
                ),
                subtitle: Text(
                  'Off by default: transcripts stay as a backup unless you '
                  'ask.',
                  style: TextStyle(fontSize: 11, color: colors.muted),
                ),
                value: _deleteHistory,
                onChanged: (v) => setState(() => _deleteHistory = v),
              ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _running ? null : () => Navigator.of(context).pop(),
              child: Text(
                'Cancel',
                style: TextStyle(fontFamily: kMonoFamily, color: colors.muted),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed:
                  _running || selected.isEmpty ? null : () => _run(selected),
              child: Text(
                selected.isEmpty
                    ? 'Clean up'
                    : 'Clean up ${selected.length}',
                style: TextStyle(fontFamily: kMonoFamily, color: colors.error),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _run(List<SessionCleanupPlan> selected) async {
    setState(() => _running = true);
    // cleanupFinishedSessions isolates per-item ActionFailures into reports,
    // but an unexpected exception (a bug) must not leave the sheet stuck on
    // "Cleaning up…" forever (PR #94 review).
    List<SessionCleanupReport> results;
    try {
      results = await widget.onConfirm(selected, _deleteHistory);
    } catch (e) {
      results = [
        for (final p in selected)
          SessionCleanupReport(
            epk: p.epk,
            roomId: p.roomId,
            ok: false,
            message: 'Unexpected error: $e',
          ),
      ];
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _results = results;
    });
  }
}

/// One selectable session row of the selection phase.
class _PlanRow extends StatelessWidget {
  final SessionCleanupPlan plan;
  final bool checked;
  final TextStyle mono;
  final ValueChanged<bool> onChanged;

  const _PlanRow({
    super.key,
    required this.plan,
    required this.checked,
    required this.mono,
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
              child: Checkbox(value: checked, onChanged: (v) => onChanged(v ?? false)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          plan.sessionTitle,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: colors.text),
                        ),
                      ),
                      if (plan.ghRefOpenPr) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.warning_amber_outlined,
                          size: 13,
                          color: colors.warning,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    plan.worktree != null
                        ? 'worktree · ${plan.worktree!.branch}'
                        : 'no worktree — forget + remove from this phone',
                    style: mono.copyWith(
                      fontSize: 11,
                      color: colors.muted,
                    ),
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

/// The app's theme exposes custom color roles via context.colors; the sheet
/// only reads them. Structural alias so the widget signatures stay honest
/// without importing the theme implementation.

