import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;

import 'workspace_theme.dart';

class WorkspaceCupertinoField extends StatelessWidget {
  const WorkspaceCupertinoField({
    super.key,
    required this.controller,
    required this.placeholder,
    this.obscureText = false,
    this.enabled = true,
    this.keyboardType,
    this.suffix,
    this.hasError = false,
  });

  final TextEditingController controller;
  final String placeholder;
  final bool obscureText;
  final bool enabled;
  final TextInputType? keyboardType;
  final Widget? suffix;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    return CupertinoTextField(
      controller: controller,
      placeholder: placeholder,
      obscureText: obscureText,
      enabled: enabled,
      keyboardType: keyboardType,
      suffix: suffix,
      enableSuggestions: !obscureText,
      autocorrect: false,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: workspaceSurfaceColor,
        border: Border.all(
          color: hasError ? CupertinoColors.systemRed : workspaceLineColor,
        ),
        borderRadius: workspaceBorderRadius,
      ),
    );
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Semantics(
      label: label,
      button: true,
      child: CupertinoButton(
        minimumSize: const Size(38, 38),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: enabled ? accentColor : CupertinoColors.systemGrey4,
        borderRadius: workspaceBorderRadius,
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: CupertinoColors.white),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: CupertinoColors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: CupertinoButton(
        minimumSize: const Size(38, 38),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: workspaceSurfaceColor,
        borderRadius: workspaceBorderRadius,
        onPressed: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: workspaceBorderRadius,
            border: Border.all(color: workspaceLineColor),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  const CupertinoActivityIndicator(radius: 8)
                else
                  Icon(icon, size: 17),
                const SizedBox(width: 6),
                Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.maxLabelWidth,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double? maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    final labelWidget = Text(label, overflow: TextOverflow.ellipsis);
    return Tooltip(
      message: tooltip ?? label,
      child: Semantics(
        label: label,
        button: true,
        child: CupertinoButton(
          minimumSize: const Size(36, 36),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          color: workspaceSecondarySurfaceColor,
          borderRadius: workspaceBorderRadius,
          onPressed: onPressed,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16),
              const SizedBox(width: 6),
              if (maxLabelWidth == null)
                labelWidget
              else
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxLabelWidth!),
                  child: labelWidget,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class IconAction extends StatelessWidget {
  const IconAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        child: CupertinoButton(
          minimumSize: const Size.square(34),
          padding: EdgeInsets.zero,
          onPressed: onPressed,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Center(child: Icon(icon, size: 18)),
          ),
        ),
      ),
    );
  }
}

class TileAction extends StatelessWidget {
  const TileAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: CupertinoButton(
        minimumSize: const Size.square(32),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(16),
        color: workspaceSurfaceColor.withValues(alpha: 0.92),
        onPressed: onPressed,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Center(child: Icon(icon, size: 17)),
        ),
      ),
    );
  }
}

class PaneSubheading extends StatelessWidget {
  const PaneSubheading(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}

class SectionDivider extends StatelessWidget {
  const SectionDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Hairline(),
    );
  }
}

class Hairline extends StatelessWidget {
  const Hairline({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 1,
      child: ColoredBox(color: workspaceSoftLineColor),
    );
  }
}

class VaultLocationEmptyState extends StatelessWidget {
  const VaultLocationEmptyState({super.key, required this.onChooseVault});

  final VoidCallback? onChooseVault;

  @override
  Widget build(BuildContext context) {
    final canChooseVault = onChooseVault != null;
    final pickerLabel = Semantics(
      button: true,
      enabled: canChooseVault,
      onTap: onChooseVault,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChooseVault,
        child: MouseRegion(
          cursor: canChooseVault
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.folder,
                  size: 34,
                  color: workspaceMutedColor,
                ),
                SizedBox(height: 10),
                Text(
                  '选择仓库位置',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: workspaceTextColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        pickerLabel,
        const SizedBox(height: 8),
        CupertinoButton.filled(
          key: const Key('choose-vault-empty-button'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          onPressed: onChooseVault,
          child: const Text('选择仓库位置'),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 0.0;
        final minHeight = availableHeight > 16 ? availableHeight - 16 : 0.0;
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Center(child: content),
          ),
        );
      },
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(text, style: const TextStyle(color: workspaceMutedColor)),
    );
  }
}
