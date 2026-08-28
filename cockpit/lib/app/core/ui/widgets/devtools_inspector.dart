import 'package:flutter/material.dart' as material;
import 'package:flutter/widgets.dart';

/// Flutter's [WidgetsApp] supports DevTools' widget-selection mode, but its
/// optional HUD builders are not exposed by shadcn_flutter's [ShadcnApp].
/// This is the small adapter that keeps the framework inspector while
/// supplying the same three controls that [MaterialApp] supplies.
class DevToolsInspector extends StatelessWidget {
  const DevToolsInspector({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Keep the inspector graph inside an assert, like WidgetsApp does. Asserts
    // are disabled in profile/release, so those builds return only [child] and
    // do not retain the DevTools listenable or WidgetInspector.
    Widget result = child;
    assert(() {
      result = ValueListenableBuilder<bool>(
        valueListenable:
            WidgetsBinding.instance.debugShowWidgetInspectorOverrideNotifier,
        builder: (context, enabled, child) {
          if (!enabled) return child!;
          return WidgetInspector(
            exitWidgetSelectionButtonBuilder: _buildExitButton,
            moveExitWidgetSelectionButtonBuilder: _buildMoveButton,
            tapBehaviorButtonBuilder: _buildTapBehaviorButton,
            child: child!,
          );
        },
        child: result,
      );
      return true;
    }());
    return result;
  }

  Widget _buildExitButton(
    BuildContext context, {
    required VoidCallback onPressed,
    required String semanticsLabel,
    required GlobalKey key,
  }) {
    return _InspectorButton(
      key: key,
      icon: material.Icons.close,
      onPressed: onPressed,
      semanticsLabel: semanticsLabel,
      variant: _InspectorButtonVariant.filled,
    );
  }

  Widget _buildMoveButton(
    BuildContext context, {
    required VoidCallback onPressed,
    required String semanticsLabel,
    bool usesDefaultAlignment = true,
  }) {
    return _InspectorButton(
      icon: usesDefaultAlignment
          ? material.Icons.arrow_right
          : material.Icons.arrow_left,
      onPressed: onPressed,
      semanticsLabel: semanticsLabel,
      variant: _InspectorButtonVariant.iconOnly,
    );
  }

  Widget _buildTapBehaviorButton(
    BuildContext context, {
    required VoidCallback onPressed,
    required String semanticsLabel,
    required bool selectionOnTapEnabled,
  }) {
    return _InspectorButton(
      icon: const IconData(0x1F74A),
      onPressed: onPressed,
      semanticsLabel: semanticsLabel,
      selectionOnTapEnabled: selectionOnTapEnabled,
      variant: _InspectorButtonVariant.toggle,
    );
  }
}

enum _InspectorButtonVariant { filled, toggle, iconOnly }

class _InspectorButton extends StatelessWidget {
  const _InspectorButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.semanticsLabel,
    required this.variant,
    this.selectionOnTapEnabled,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String semanticsLabel;
  final _InspectorButtonVariant variant;
  final bool? selectionOnTapEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = material.Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final primary = dark
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.primaryContainer;
    final secondary = dark
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.onPrimaryContainer;
    final foreground = switch (variant) {
      _InspectorButtonVariant.filled => primary,
      _InspectorButtonVariant.iconOnly => secondary,
      _InspectorButtonVariant.toggle =>
        selectionOnTapEnabled! ? primary : secondary,
    };
    final background = switch (variant) {
      _InspectorButtonVariant.filled => secondary,
      _InspectorButtonVariant.iconOnly => material.Colors.transparent,
      _InspectorButtonVariant.toggle =>
        selectionOnTapEnabled! ? secondary : material.Colors.transparent,
    };
    final border =
        variant == _InspectorButtonVariant.toggle && !selectionOnTapEnabled!
        ? material.BorderSide(color: foreground)
        : null;

    // WidgetInspector already renders its own tooltip in the HUD. Supplying
    // IconButton.tooltip here would create a second Tooltip that looks for an
    // Overlay above this subtree; the inspector intentionally lives inside the
    // ShadcnApp builder, below that app's Navigator/Overlay.
    return material.IconButton(
      onPressed: onPressed,
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      style: material.IconButton.styleFrom(
        foregroundColor: foreground,
        backgroundColor: background,
        side: border,
        tapTargetSize: material.MaterialTapTargetSize.padded,
      ),
      icon: Icon(icon, semanticLabel: semanticsLabel),
    );
  }
}
