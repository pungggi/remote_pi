import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Plan/107b — posh-git-style git status as coloured [InlineSpan]s, shared by
/// the Home session tile and the chat session-info dialog so they always
/// render identically (and match pi-posh-git's footer).
///
/// Colour mapping mirrors pi-posh-git's `buildPrompt`:
///   `[` `]` `|` stash diverged(↓N ↑N) → warning
///   branch `≡` `~`                    → accent
///   ahead `↑N`                        → success
///   behind `↓N` `!` unstaged counts   → error
///   upstream-gone `×`                 → muted
///
/// Format: `[branch (≡|↑N|↓N|↓N ↑N|×) (+ia ~im -id)? (|)? (+wa ~wm -wd !)? (~)? (stash)?]`
/// — `+a ~m -d` is staged when after `≡/↑/↓`, working (unstaged) after `|`
/// with a trailing `!`.
List<InlineSpan> gitStatusSpans(
  GitStatus s,
  AppColors c, {
  double fontSize = 12,
}) {
  final base = TextStyle(fontFamily: kMonoFamily, fontSize: fontSize);
  TextSpan t(String text, Color color) =>
      TextSpan(text: text, style: base.copyWith(color: color));
  String counts(int a, int m, int d) => '+$a ~$m -$d';
  final hasIndex = s.indexAdded + s.indexModified + s.indexDeleted > 0;
  final hasWorking =
      s.workingAdded + s.workingModified + s.workingDeleted > 0;
  final spans = <InlineSpan>[
    t('[', c.warning),
    t(s.branch.isEmpty ? '(no branch)' : s.branch, c.accent),
  ];
  if (s.upstream != null && s.upstreamGone) {
    spans.add(t(' ×', c.muted));
  } else if (s.upstream != null && s.behindBy == 0 && s.aheadBy == 0) {
    spans.add(t(' ≡', c.accent));
  } else if (s.upstream != null && s.behindBy > 0 && s.aheadBy > 0) {
    spans.add(t(' ↓${s.behindBy} ↑${s.aheadBy}', c.warning));
  } else if (s.upstream != null && s.behindBy > 0) {
    spans.add(t(' ↓${s.behindBy}', c.error));
  } else if (s.upstream != null && s.aheadBy > 0) {
    spans.add(t(' ↑${s.aheadBy}', c.success));
  }
  if (hasIndex) {
    spans.add(
      t(' ${counts(s.indexAdded, s.indexModified, s.indexDeleted)}', c.success),
    );
  }
  if (hasIndex && hasWorking) spans.add(t(' |', c.warning));
  if (hasWorking) {
    spans.add(
      t(
        ' ${counts(s.workingAdded, s.workingModified, s.workingDeleted)}',
        c.error,
      ),
    );
    spans.add(t(' !', c.error));
  } else if (hasIndex) {
    spans.add(t(' ~', c.accent));
  }
  if (s.stashCount > 0) spans.add(t(' (${s.stashCount})', c.warning));
  spans.add(t(']', c.warning));
  return spans;
}
