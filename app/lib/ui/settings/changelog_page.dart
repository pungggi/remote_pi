import 'package:app/domain/entities/changelog_entry.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Plan/123 — "What's new": the last entries parsed from the bundled
/// CHANGELOG.md (`assets/CHANGELOG.md`), rendered as markdown. Reached from
/// Settings → About → What's new.
///
/// The changelog is **bundled**, not fetched, so it works offline and always
/// reflects the installed build (entries up to this version). Re-copying the
/// repo root CHANGELOG into `app/assets/` at release keeps it current.
class ChangelogPage extends StatefulWidget {
  const ChangelogPage({super.key});

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  List<ChangelogEntry>? _entries;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final md = await rootBundle.loadString('assets/CHANGELOG.md');
      if (!mounted) return;
      setState(() {
        _entries = parseChangelog(md);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: colors.bg,
        surfaceTintColor: colors.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(LucideIcons.chevronLeft, color: colors.text),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          "What's new",
          style: typo.mono.copyWith(
            color: colors.text,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        // Record switch over (entries, error):
        //  - ready + empty → "no entries"
        //  - ready + non-empty → the list
        //  - any error → message
        //  - both null → still loading
        child: switch ((_entries, _error)) {
          (final entries?, null) when entries.isEmpty => const _Message(
              icon: LucideIcons.fileText,
              text: 'No changelog entries found.',
            ),
          (final entries?, null) => ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              itemCount: entries.length,
              separatorBuilder: (_, _) =>
                  Divider(color: colors.border, height: 28),
              itemBuilder: (ctx, i) {
                final e = entries[i];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.title,
                      style: typo.mono.copyWith(
                        color: colors.accent,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Reuse the chat markdown renderer — same theming, links,
                    // and code blocks the agent replies use.
                    AgentMarkdown(e.body),
                  ],
                );
              },
            ),
          (_, final error?) => _Message(
              icon: Icons.error_outline,
              text: 'Could not load changelog.\n$error',
            ),
          _ => Center(child: CircularProgressIndicator(color: colors.accent)),
        },
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Message({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: colors.muted, size: 40),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: typo.monoSmall.copyWith(color: colors.muted),
            ),
          ],
        ),
      ),
    );
  }
}
