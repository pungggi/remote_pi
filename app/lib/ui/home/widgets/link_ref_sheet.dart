// Plan/149 — "Link Issue / PR" sheet for a session.
//
// Three paths to link a GitHub ref to a session (all ending in
// `set_session_ref_request`):
//   1. the chat-scan suggestion (if the room published one) — one tap;
//   2. manual input: a full GitHub URL or `owner/repo#123`;
//   3. remove the current link entirely (clear).
//
// A bare `#123` is rejected client-side (never enough on its own — it is
// ambiguous across repos) with a hint to paste the full URL. The sheet
// never blocks: every action toasts its outcome and pops.

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Opens the Link sheet. Returns whether a link change was dispatched
/// (the result arrives async via the rooms push; the tile updates on
/// its own).
Future<bool> showLinkRefSheet(
  BuildContext context, {
  required String title,
  required GhRef? current,
  required GhRef? suggestion,
  required Future<void> Function(GhRef? ref) onApply,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: context.colors.bg,
    isScrollControlled: true,
    builder: (sheetCtx) => _LinkRefSheet(
      title: title,
      current: current,
      suggestion: suggestion,
      onApply: onApply,
    ),
  ).then((v) => v ?? false);
}

class _LinkRefSheet extends StatefulWidget {
  final String title;
  final GhRef? current;
  final GhRef? suggestion;
  final Future<void> Function(GhRef? ref) onApply;

  const _LinkRefSheet({
    required this.title,
    required this.current,
    required this.suggestion,
    required this.onApply,
  });

  @override
  State<_LinkRefSheet> createState() => _LinkRefSheetState();
}

class _LinkRefSheetState extends State<_LinkRefSheet> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _apply(BuildContext sheetCtx, GhRef? ref) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(sheetCtx);
    try {
      await widget.onApply(ref);
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger?.showSnackBar(
        SnackBar(content: Text(e is Exception ? e.toString() : 'Failed')),
      );
      return;
    }
    if (!sheetCtx.mounted) return;
    Navigator.of(sheetCtx).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final current = widget.current;
    final suggestion = widget.suggestion;
    final parsed = GhRef.tryParseInput(_controller.text);
    final hasInput = _controller.text.trim().isNotEmpty;

    return Padding(
      // Keyboard inset: the manual field needs the full height above the
      // on-screen keyboard.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Link Issue / PR',
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.muted, fontSize: 12),
                ),
                const SizedBox(height: 14),

                // Current link + remove.
                if (current?.display != null) ...[
                  _RefRow(
                    icon: LucideIcons.link,
                    label: current!.label,
                    subtitle:
                        'Linked · ${_sourceLabel(current.source ?? '')}',
                    trailing: TextButton(
                      onPressed:
                          _busy ? null : () => _apply(context, null),
                      child: const Text('Remove'),
                    ),
                    onTap: null,
                  ),
                  const SizedBox(height: 8),
                ],

                // Chat-scan suggestion: one tap to accept. Only when it
                // isn't already the current ref.
                if (suggestion?.display != null &&
                    suggestion != current) ...[
                  _RefRow(
                    icon: LucideIcons.sparkles,
                    label: suggestion!.label,
                    subtitle: 'Suggested from this chat',
                    trailing: Icon(
                      LucideIcons.chevronRight,
                      size: 18,
                      color: colors.muted,
                    ),
                    onTap: _busy ? null : () => _apply(context, suggestion),
                  ),
                  const SizedBox(height: 8),
                ],

                // Manual input.
                TextField(
                  controller: _controller,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'GitHub URL or owner/repo#123',
                    hintStyle: TextStyle(
                      color: colors.muted,
                      fontFamily: kMonoFamily,
                      fontSize: 12,
                    ),
                  ),
                  style: TextStyle(
                    color: colors.text,
                    fontFamily: kMonoFamily,
                    fontSize: 13,
                  ),
                ),
                if (hasInput && parsed == null) ...[
                  const SizedBox(height: 6),
                  Text(
                    // Bare #123 is deliberately not enough (ambiguous):
                    // say what to paste instead.
                    'Paste a full GitHub URL (or owner/repo#123) — a bare '
                    '#123 is ambiguous.',
                    style: TextStyle(color: colors.muted, fontSize: 11),
                  ),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy || parsed == null
                        ? null
                        : () => _apply(context, parsed),
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Text('Link'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _sourceLabel(String source) {
    return switch (source) {
      'manual' => 'set by you',
      'gh' => 'from git',
      'chat' => 'from chat',
      _ => source,
    };
  }
}

class _RefRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _RefRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: colors.surface,
          border: Border.all(color: colors.border),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 16, color: colors.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: colors.text,
                      fontFamily: kMonoFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(color: colors.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
      ),
    );
  }
}
