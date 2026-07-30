import 'package:app/data/actions/actions_repository.dart' show ActionFailure;
import 'package:app/protocol/protocol.dart' show OpenTerminalResult, WireProject;
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/branch_name_dialog.dart';
import 'package:app/ui/projects/projects_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Plan/121 — lists git projects discovered on the paired PC (served by the
/// always-on device daemon in room `device`), independent of live `pi`
/// sessions. Tapping a project prompts for a worktree branch and spawns a
/// worktree terminal there (reusing the plan/108 spawn path via the device
/// room). Reached from the Home app bar (`RoutePaths.projects`).
class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key});

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  @override
  void initState() {
    super.initState();
    // Defer so the route's ViewmodelProvider<ProjectsViewModel> is mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ProjectsViewModel>().load();
    });
  }

  Future<void> _openTerminal(WireProject p) async {
    final messenger = ScaffoldMessenger.of(context);
    final branch = await showDialog<String>(
      context: context,
      builder: (_) => const BranchNameDialog(),
    );
    if (!mounted || branch == null) return; // cancelled
    if (branch.isEmpty) {
      _toast(messenger, 'Enter a branch name', isError: true);
      return;
    }
    final vm = context.read<ProjectsViewModel>();
    try {
      final OpenTerminalResult r = await vm.openTerminalForProject(
        cwd: p.path,
        branch: branch,
      );
      if (!mounted) return;
      _toast(messenger, r.message, isError: !r.ok);
    } on ActionFailure catch (e) {
      _toast(messenger, e.message, isError: true);
    } catch (_) {
      _toast(messenger, 'Could not open terminal', isError: true);
    }
  }

  void _toast(ScaffoldMessengerState m, String msg, {required bool isError}) {
    if (!m.mounted) return;
    final colors = m.context.colors;
    final typo = m.context.typo;
    m.showSnackBar(
      SnackBar(
        backgroundColor: colors.surface,
        behavior: SnackBarBehavior.floating,
        content: Text(
          msg,
          style: typo.monoSmall.copyWith(
            color: isError ? colors.error : colors.accent,
          ),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final state = context.watch<ProjectsViewModel>().state;
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
          'Projects',
          style: typo.mono.copyWith(
            color: colors.text,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => context.read<ProjectsViewModel>().load(),
          color: colors.accent,
          // Always a scrollable so RefreshIndicator works in every state
          // (loading / empty / error), not only when the list is ready.
          child: _body(state),
        ),
      ),
    );
  }

  Widget _body(ProjectsState state) {
    final colors = context.colors;
    final typo = context.typo;
    return switch (state) {
      // Scrollable shell so pull-to-refresh works while the first load runs.
      ProjectsLoading() => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 160),
          Center(child: CircularProgressIndicator()),
        ],
      ),
      ProjectsError(:final message) => _CenterMessage(
        icon: LucideIcons.wifiOff,
        title: 'Device unreachable',
        subtitle:
            '$message\n\nStart the Cockpit or the pi-supervisor on that PC so its device daemon can list projects.',
      ),
      ProjectsReady(:final projects) when projects.isEmpty =>
        const _CenterMessage(
          icon: LucideIcons.folderOpen,
          title: 'No projects found',
          subtitle:
              'Clone repos under ~/source on your PC, or add roots to ~/.pi/piper/config.json (projects.roots).',
        ),
      ProjectsReady(:final projects) => ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: projects.length,
        separatorBuilder: (_, _) => Divider(color: colors.border, height: 1),
        itemBuilder: (ctx, i) {
          final p = projects[i];
          final segs = p.path
              .split(RegExp(r'[/\\]'))
              .where((s) => s.isNotEmpty)
              .toList();
          final parent = segs.length >= 2 ? segs[segs.length - 2] : '';
          return ListTile(
            leading: Icon(LucideIcons.folderGit, color: colors.accent),
            title: Text(
              p.name,
              style: typo.mono.copyWith(color: colors.text, fontSize: 14),
            ),
            subtitle: parent.isEmpty
                ? null
                : Text(
                    parent,
                    style: typo.monoSmall.copyWith(color: colors.muted),
                  ),
            trailing: Icon(LucideIcons.chevronRight, color: colors.muted2, size: 18),
            onTap: () => _openTerminal(p),
          );
        },
      ),
    };
  }
}

class _CenterMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _CenterMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    return ListView(
      // RefreshIndicator needs a scrollable; keep it scrollable even when empty.
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: colors.muted, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    style: typo.sansBody.copyWith(color: colors.muted2),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: typo.monoSmall.copyWith(
                      color: colors.muted,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
