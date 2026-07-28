import 'dart:async';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Compact copy-to-clipboard button with built-in "copied" feedback (icon
/// morphs to a check for 1.5s).
///
/// Two flavors, picked by whether [label] is set:
/// - **Icon-only** ([label] is `null`): a tight [IconButton] for dense chrome
///   such as a code-block header. Pass [tooltip] for accessibility.
/// - **Labeled** ([label] provided): an icon + label [TextButton] for a
///   message-level action; the label flips to "Copied" on success.
///
/// Factored out of the code-block copy button so the assistant reply bubble
/// can reuse the exact same behavior.
class CopyButton extends StatefulWidget {
  const CopyButton({
    super.key,
    required this.text,
    this.tooltip = 'Copy',
    this.label,
    this.iconSize = 15,
  });

  /// Content written to the clipboard on tap.
  final String text;

  /// Icon-only tooltip / semantics label.
  final String tooltip;

  /// Optional inline label. When `null` the button is icon-only.
  final String? label;

  /// Icon size.
  final double iconSize;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  static const Duration _feedback = Duration(milliseconds: 1500);

  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(_feedback, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final icon = Icon(
      _copied ? LucideIcons.check : LucideIcons.copy,
      size: widget.iconSize,
      color: _copied ? colors.success : colors.muted,
    );

    // Labeled → icon + label. The label flips to "Copied" on success.
    final label = widget.label;
    if (label != null) {
      return TextButton.icon(
        onPressed: _copy,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          minimumSize: const Size(0, 0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          foregroundColor: _copied ? colors.success : colors.muted,
          textStyle: context.typo.sansBody.copyWith(fontSize: 12),
        ),
        icon: icon,
        label: Text(_copied ? 'Copied' : label),
      );
    }

    // Icon-only → compact IconButton.
    return IconButton(
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      iconSize: widget.iconSize,
      splashRadius: 16,
      tooltip: widget.tooltip,
      onPressed: _copy,
      icon: icon,
    );
  }
}
