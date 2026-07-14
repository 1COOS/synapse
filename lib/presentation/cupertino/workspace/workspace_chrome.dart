import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../workspace/controller/workspace_controller.dart';
import '../../workspace/state/split_workspace_controller.dart';
import 'workspace_controls.dart';
import 'workspace_theme.dart';
import 'workspace_titlebar.dart';

final class WorkspaceChromeTitlebar extends StatelessWidget {
  const WorkspaceChromeTitlebar({
    super.key,
    required this.workspace,
    required this.controller,
    required this.narrow,
    required this.usesNativeMacTitlebar,
    required this.onOpenSettings,
  });

  final WorkspaceState workspace;
  final WorkspaceController controller;
  final bool narrow;
  final bool usesNativeMacTitlebar;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return narrow ? _buildNarrowTitlebar() : _buildWideTitlebar();
  }

  Widget _buildWideTitlebar() {
    final leftWidth = workspace.leftPaneCollapsed
        ? workspaceCollapsedPaneWidth
        : workspaceLeftPaneWidth;
    final rightWidth = workspace.rightPaneCollapsed
        ? workspaceCollapsedPaneWidth
        : workspaceRightPaneWidth;
    return Container(
      key: const Key('workspace-titlebar'),
      height: workspaceTitlebarHeight,
      decoration: const BoxDecoration(
        color: workspaceSurfaceColor,
        border: Border(bottom: BorderSide(color: workspaceLineColor)),
      ),
      child: Row(
        children: [
          SizedBox(width: leftWidth, child: _buildLeftTitlebar()),
          Expanded(child: _buildCenterTitlebar()),
          SizedBox(width: rightWidth, child: _buildRightTitlebar()),
        ],
      ),
    );
  }

  Widget _buildNarrowTitlebar() {
    return Container(
      key: const Key('workspace-titlebar'),
      height: workspaceTitlebarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: workspaceSurfaceColor,
        border: Border(bottom: BorderSide(color: workspaceLineColor)),
      ),
      child: Row(
        children: [
          IconAction(
            key: const Key('left-pane-mode-resources'),
            label: '资源列表',
            icon: CupertinoIcons.folder,
            onPressed: () {
              controller.setLeftMode(WorkspaceLeftMode.resources);
              controller.setNarrowSection(WorkspaceSection.resources);
            },
          ),
          const SizedBox(width: 6),
          IconAction(
            key: const Key('left-pane-mode-search'),
            label: '搜索',
            icon: CupertinoIcons.search,
            onPressed: () {
              controller.setLeftMode(WorkspaceLeftMode.search);
              controller.setNarrowSection(WorkspaceSection.resources);
            },
          ),
          const Spacer(),
          IconAction(
            key: const Key('settings-button'),
            label: '设置',
            icon: CupertinoIcons.gear,
            onPressed: workspace.isBusy || workspace.isAutoSaving
                ? null
                : onOpenSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildLeftTitlebar() {
    if (workspace.leftPaneCollapsed) {
      if (usesNativeMacTitlebar) {
        return const SizedBox.shrink();
      }
      return WorkspaceTitlebarStrip(
        child: IconAction(
          key: const Key('titlebar-expand-left-pane-button'),
          label: '展开左栏',
          icon: CupertinoIcons.sidebar_left,
          onPressed: () => controller.setLeftPaneCollapsed(false),
        ),
      );
    }
    final leadingInset = usesNativeMacTitlebar
        ? workspaceMacTitlebarControlReserve
        : 10.0;
    return Padding(
      padding: EdgeInsets.only(left: leadingInset, right: 10),
      child: Align(
        alignment: Alignment.center,
        child: Row(
          children: [
            ModeIconAction(
              key: const Key('left-pane-mode-resources'),
              label: '资源列表',
              icon: CupertinoIcons.folder,
              selected: workspace.leftMode == WorkspaceLeftMode.resources,
              onPressed: () =>
                  controller.setLeftMode(WorkspaceLeftMode.resources),
            ),
            const SizedBox(width: 6),
            ModeIconAction(
              key: const Key('left-pane-mode-search'),
              label: '搜索',
              icon: CupertinoIcons.search,
              selected: workspace.leftMode == WorkspaceLeftMode.search,
              onPressed: () => controller.setLeftMode(WorkspaceLeftMode.search),
            ),
            const Spacer(),
            IconAction(
              key: const Key('collapse-left-pane-button'),
              label: '折叠左栏',
              icon: CupertinoIcons.sidebar_left,
              onPressed: () => controller.setLeftPaneCollapsed(true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCenterTitlebar() {
    final controlsDisabled =
        workspace.isBusy ||
        workspace.isAutoSaving ||
        !workspace.hasVault ||
        workspace.requiresMigration;
    return WorkspaceTitlebarStrip(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SplitIconAction(
            key: const Key('split-pane-left-button'),
            label: '向左分屏',
            direction: SplitDirection.left,
            onPressed: controlsDisabled
                ? null
                : () => controller.splitFocused(SplitDirection.left),
          ),
          const SizedBox(width: 6),
          SplitIconAction(
            key: const Key('split-pane-right-button'),
            label: '向右分屏',
            direction: SplitDirection.right,
            onPressed: controlsDisabled
                ? null
                : () => controller.splitFocused(SplitDirection.right),
          ),
          const SizedBox(width: 6),
          SplitIconAction(
            key: const Key('split-pane-up-button'),
            label: '向上分屏',
            direction: SplitDirection.up,
            onPressed: controlsDisabled
                ? null
                : () => controller.splitFocused(SplitDirection.up),
          ),
          const SizedBox(width: 6),
          SplitIconAction(
            key: const Key('split-pane-down-button'),
            label: '向下分屏',
            direction: SplitDirection.down,
            onPressed: controlsDisabled
                ? null
                : () => controller.splitFocused(SplitDirection.down),
          ),
          const SizedBox(width: 10),
          ModeIconAction(
            key: const Key('close-split-pane-button'),
            label: '关闭分屏',
            icon: CupertinoIcons.xmark,
            selected: false,
            onPressed: controlsDisabled || _paneCount(workspace.splitRoot) <= 1
                ? null
                : () => unawaited(controller.closeFocusedPane()),
          ),
        ],
      ),
    );
  }

  Widget _buildRightTitlebar() {
    if (workspace.rightPaneCollapsed) {
      return WorkspaceTitlebarStrip(
        child: IconAction(
          key: const Key('titlebar-expand-right-pane-button'),
          label: '展开右栏',
          icon: CupertinoIcons.sidebar_right,
          onPressed: () => controller.setRightPaneCollapsed(false),
        ),
      );
    }
    return WorkspaceTitlebarStrip(
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.photo_on_rectangle,
            key: Key('right-pane-title-icon'),
            size: 20,
            color: workspaceMutedColor,
          ),
          const Spacer(),
          IconAction(
            key: const Key('collapse-right-pane-button'),
            label: '折叠右栏',
            icon: CupertinoIcons.sidebar_right,
            onPressed: () => controller.setRightPaneCollapsed(true),
          ),
        ],
      ),
    );
  }
}

int _paneCount(SplitNode node) {
  return switch (node) {
    SplitLeaf() => 1,
    final SplitBranch branch =>
      _paneCount(branch.first) + _paneCount(branch.second),
  };
}
