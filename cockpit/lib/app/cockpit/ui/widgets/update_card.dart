import 'package:cockpit/app/cockpit/ui/viewmodels/update_viewmodel.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:cockpit/app/core/ui/widgets/hover_tap.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:cockpit/app/core/ui/widgets/app_tooltip.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Mini update card at the bottom of the rail — above the machine name. Only
/// renders when the [UpdateViewModel] has a pending update.
///
/// - **Windows (self-update):** WinSparkle doesn't pre-download, so it goes
///   straight to "click to install"; tapping drives download+install natively.
/// - **Linux (notify):** "click to download"; tapping opens the artifact URL.
/// - **macOS:** never renders — the fork publishes no macOS build, so
///   `hasUpdate` is always false there.
///
/// The X dismisses it (persisted per version on Linux; session-only on
/// self-update, where the next downloaded version re-surfaces the card).
class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<UpdateViewModel>();
    if (!vm.hasUpdate) return const SizedBox.shrink();

    final colors = context.colors;
    final ready = vm.isReadyToInstall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: HoverTap(
        color: colors.panel2,
        hoverColor: colors.panel3,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.accent.withValues(alpha: 0.5)),
        onTap: () => context.read<UpdateViewModel>().primaryAction(),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        child: Row(
          children: [
            Icon(
              ready ? Icons.restart_alt : Icons.system_update_alt,
              size: 15,
              color: colors.accentText,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    vm.cardTitle,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.label.copyWith(
                      color: colors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    vm.cardSubtitle,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.label.copyWith(color: colors.text3),
                  ),
                ],
              ),
            ),
            AppTooltip(
              message: context.t.common.dismiss,
              child: HoverTap(
                onTap: () => context.read<UpdateViewModel>().dismiss(),
                borderRadius: BorderRadius.circular(5),
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close, size: 14, color: colors.text3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
