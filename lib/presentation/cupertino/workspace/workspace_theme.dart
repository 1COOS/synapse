import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show MenuStyle, WidgetStatePropertyAll;

import '../../../infrastructure/config/synapse_settings.dart';

const workspaceBackgroundColor = Color(0xFFF5F5F7);
const workspaceSurfaceColor = Color(0xFFFFFFFF);
const workspaceSecondarySurfaceColor = Color(0xFFF9F9FB);
const workspaceLineColor = Color(0xFFD2D2D7);
const workspaceSoftLineColor = Color(0xFFE5E5EA);
const workspaceTextColor = CupertinoColors.label;
const workspaceMutedColor = CupertinoColors.secondaryLabel;
const workspaceDangerColor = CupertinoColors.systemRed;
const workspaceBorderRadius = BorderRadius.all(Radius.circular(8));
const workspaceResourceTitleStyle = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w500,
  height: 1.2,
);
const workspaceResourceCountStyle = TextStyle(
  color: workspaceMutedColor,
  fontSize: 12,
  fontWeight: FontWeight.w500,
  height: 1.2,
);
const workspaceResourceMenuBackground = Color(0xE65F5F5F);
const workspaceResourceMenuText = Color(0xFFF2F2F7);
const workspaceNoteMenuDisabledText = Color(0x73F2F2F7);
const workspaceResourceMenuLine = Color(0xFF777777);
const workspaceResourceMenuRadius = BorderRadius.all(Radius.circular(18));
const workspaceContextMenuItemHeight = 30.0;
const workspaceContextMenuItemRadius = BorderRadius.all(Radius.circular(8));
const workspaceContextMenuItemTextStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w400,
  height: 1.15,
);
const workspaceContextMenuPanelShadow = [
  BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 12)),
];
const workspaceResourceMenuAnchorStyle = MenuStyle(
  backgroundColor: WidgetStatePropertyAll(Color(0x00000000)),
  elevation: WidgetStatePropertyAll(0),
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
  shadowColor: WidgetStatePropertyAll(Color(0x00000000)),
  surfaceTintColor: WidgetStatePropertyAll(Color(0x00000000)),
);
const workspaceTitlebarHeight = 52.0;
const workspaceLeftPaneWidth = 292.0;
const workspaceRightPaneWidth = 380.0;
const workspaceCollapsedPaneWidth = 52.0;
const workspaceMacTitlebarControlReserve = 148.0;
const workspaceNoteWorkspaceGutter = 12.0;

class WorkspaceAppearance {
  const WorkspaceAppearance({
    required this.accentColor,
    required this.noteFontSize,
  });
  factory WorkspaceAppearance.fromPreferences(
    WorkspacePreferences preferences,
  ) => WorkspaceAppearance(
    accentColor: accentColorFor(preferences.accentColor),
    noteFontSize: preferences.noteFontSize.toDouble(),
  );
  static const defaults = WorkspaceAppearance(
    accentColor: CupertinoColors.activeBlue,
    noteFontSize: 14,
  );
  final Color accentColor;
  final double noteFontSize;
  double get h1FontSize => headingFontSizeForBase(noteFontSize, 1);
  double get h2FontSize => headingFontSizeForBase(noteFontSize, 2);
  double get h3FontSize => headingFontSizeForBase(noteFontSize, 3);
  static double headingFontSizeForBase(double baseFontSize, int level) =>
      switch (level) {
        1 => baseFontSize * 20 / WorkspacePreferences.defaultNoteFontSize,
        2 => baseFontSize * 17 / WorkspacePreferences.defaultNoteFontSize,
        _ => baseFontSize * 15 / WorkspacePreferences.defaultNoteFontSize,
      };
  static Color accentColorFor(WorkspaceAccentColor color) => switch (color) {
    WorkspaceAccentColor.blue => CupertinoColors.activeBlue,
    WorkspaceAccentColor.purple => CupertinoColors.systemPurple,
    WorkspaceAccentColor.pink => CupertinoColors.systemPink,
    WorkspaceAccentColor.red => CupertinoColors.systemRed,
    WorkspaceAccentColor.orange => CupertinoColors.systemOrange,
    WorkspaceAccentColor.green => CupertinoColors.systemGreen,
  };
}

class WorkspaceAppearanceScope extends InheritedWidget {
  const WorkspaceAppearanceScope({
    super.key,
    required this.appearance,
    required super.child,
  });
  final WorkspaceAppearance appearance;
  static WorkspaceAppearance of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<WorkspaceAppearanceScope>()
          ?.appearance ??
      WorkspaceAppearance.defaults;
  @override
  bool updateShouldNotify(WorkspaceAppearanceScope oldWidget) =>
      oldWidget.appearance.accentColor != appearance.accentColor ||
      oldWidget.appearance.noteFontSize != appearance.noteFontSize;
}

extension WorkspaceAccentColorLabel on WorkspaceAccentColor {
  String get label => switch (this) {
    WorkspaceAccentColor.blue => '蓝色',
    WorkspaceAccentColor.purple => '紫色',
    WorkspaceAccentColor.pink => '粉色',
    WorkspaceAccentColor.red => '红色',
    WorkspaceAccentColor.orange => '橙色',
    WorkspaceAccentColor.green => '绿色',
  };
}
