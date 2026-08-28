import 'package:cockpit/app/cockpit/domain/contracts/git_command_runner.dart';
import 'package:cockpit/app/cockpit/domain/entities/project.dart';
import 'package:cockpit/app/cockpit/ui/actions/workspace_actions.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/cockpit_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/widgets/git_process_dialog.dart';
import 'package:cockpit/app/cockpit/ui/widgets/widgets.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Fluxos de worktree (fork) do rail: criar, forkar, atualizar do pai, mergear
/// no pai e remover. Local e remoto compartilham o mesmo dialog — só muda quem
/// roda o git (ver `isRemoteTerminal`).

CockpitViewModel _vm(BuildContext context) => context.read<CockpitViewModel>();

Future<void> createWorktree(
  BuildContext context,
  Project root,
  String rootPath,
) async {
  final vm = _vm(context);
  // Multi-root: a worktree é de UMA root — a escolha já veio do submenu do
  // kebab (o fork nasce como filho single-root apontando pro checkout dela).
  final namespace = await vm.worktreeNamespace(root.id, rootPath: rootPath);
  final hasHook = await vm.hasPostCheckoutHook(rootPath);
  if (!context.mounted) return;
  await showWorktreeCreateDialog(
    context,
    rootName: gitOpLabel(root, rootPath),
    namespace: namespace,
    hasPostCheckout: hasHook,
    onCreate:
        (
          name, {
          baseRef,
          copyIgnored = false,
          copyUntracked = false,
          fetchRemote = true,
        }) => vm.createWorktree(
          root.id,
          name,
          rootPath: rootPath,
          baseRef: baseRef,
          copyIgnored: copyIgnored,
          copyUntracked: copyUntracked,
          fetchRemote: fetchRemote,
        ),
  );
}

/// "Fork Worktree": nova worktree ramificada da branch do fork [base] — mesmo
/// dialog do criar, validando contra o namespace do repo de origem.
Future<void> forkWorktree(BuildContext context, Project base) async {
  final vm = _vm(context);
  // Remoto: fork-of-fork nasce no repo do PAI (top-level), ramificado da branch
  // deste fork; o worktree add roda no host.
  if (base.isRemoteTerminal) {
    final parentId = base.parentId;
    if (parentId == null) return;
    final namespace = await vm.remoteWorktreeNamespace(parentId);
    if (!context.mounted) return;
    await showWorktreeCreateDialog(
      context,
      rootName: base.name,
      namespace: namespace,
      fork: true,
      hasPostCheckout: false,
      onCreate:
          (
            name, {
            baseRef,
            copyIgnored = false,
            copyUntracked = false,
            fetchRemote = true,
          }) => vm.createRemoteWorktree(parentId, name, baseRef: base.name),
    );
    return;
  }
  final namespace = await vm.forkWorktreeNamespace(base.id);
  final hasHook = await vm.hasPostCheckoutHookForFork(base.id);
  if (!context.mounted) return;
  await showWorktreeCreateDialog(
    context,
    rootName: base.name,
    namespace: namespace,
    fork: true,
    hasPostCheckout: hasHook,
    onCreate:
        (
          name, {
          baseRef,
          copyIgnored = false,
          copyUntracked = false,
          fetchRemote = true,
        }) => vm.forkWorktree(
          base.id,
          name,
          copyIgnored: copyIgnored,
          copyUntracked: copyUntracked,
          fetchRemote: fetchRemote,
        ),
  );
}

/// "Update from Parent": mergeia a branch do pai (root de origem) no worktree —
/// o inverso do merge. Conflito fica no worktree pro usuário resolver (o dialog
/// mostra a saída do git).
Future<void> updateWorktree(BuildContext context, Project fork) async {
  final vm = _vm(context);
  final GitRun run = fork.isRemoteTerminal
      ? vm.updateRemoteWorktreeFromParent(fork)
      : vm.updateWorktreeFromParent(fork);
  await showGitProcessDialog(
    context,
    title: context.t.cockpit.cockpitPage.updateFromParentTitle(name: fork.name),
    output: run.output,
    success: run.exitCode.then((c) => c == 0),
  );
}

/// "Merge to Parent": mergeia a branch do worktree no pai. Bloqueia se o
/// worktree tem mudanças não commitadas; conflito → aborta e mostra o erro;
/// sucesso → o VM remove o worktree e volta pro pai.
Future<void> mergeWorktree(BuildContext context, Project fork) async {
  final vm = _vm(context);
  final outcome = fork.isRemoteTerminal
      ? vm.mergeRemoteWorktreeToParent(fork)
      : vm.mergeWorktreeToParent(fork);
  await showGitProcessDialog(
    context,
    title: context.t.cockpit.cockpitPage.mergeToParentTitle(name: fork.name),
    output: outcome.output,
    success: outcome.status.then((s) => s == GitMergeStatus.merged),
    finalMessage: (ok) => ok
        ? context.t.cockpit.cockpitPage.worktreeMergedAndRemoved
        : context.t.cockpit.cockpitPage.nothingWasChanged,
  );
}

/// "Remover" a worktree (fork): confirma (aviso reforçado se a branch ainda não
/// foi mergeada) → `git worktree remove` + `git branch -D`, encerra os agentes
/// do fork e volta a seleção pro pai (decisões 6, 9).
Future<void> removeWorktree(BuildContext context, Project fork) async {
  final vm = _vm(context);
  final merged = fork.isRemoteTerminal
      ? await vm.isRemoteWorktreeBranchMerged(fork.id)
      : await vm.isWorktreeBranchMerged(fork.id);
  if (!context.mounted) return;
  final warn = merged
      ? ''
      : context.t.cockpit.cockpitPage.removeWorktreeWarning(name: fork.name);
  final ok = await showConfirmDialog(
    context,
    title: context.t.cockpit.cockpitPage.removeWorktreeTitle,
    message: context.t.cockpit.cockpitPage.removeWorktreeMessage(
      name: fork.name,
      warn: warn,
    ),
    confirmLabel: context.t.common.remove,
    danger: true,
  );
  if (!ok) return;
  final res = fork.isRemoteTerminal
      ? await vm.removeRemoteWorktree(fork.id)
      : await vm.removeWorktree(fork.id);
  if (!context.mounted) return;
  final err = res.fold<String?>((_) => null, (e) => e.message);
  if (err == null) return;
  await showInfoDialog(
    context,
    title: context.t.cockpit.cockpitPage.failedToRemoveWorktreeTitle,
    message: err,
  );
}
