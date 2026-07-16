import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../../cupertino/markdown_context_commands.dart';
import 'live_markdown_editor_controller.dart';
import 'markdown_context_menu.dart';

List<Widget> buildLiveMarkdownContextMenuItems({
  required LiveMarkdownEditorController controller,
  required MarkdownCommandTarget? menuTarget,
  required Object tapRegionGroupId,
  required bool canEdit,
  required bool canPaste,
  required bool hasText,
  required bool busy,
  required Future<void> Function(MarkdownCommandTarget? target) onPaste,
}) {
  final commandState = controller.commandState(menuTarget: menuTarget);
  final hasSelection = commandState.hasSelection;
  final canUseStructure = canEdit && commandState.canUseStructuralCommands;
  final canFormat = canEdit && commandState.canFormat;
  final shortcuts = _contextMenuShortcuts();
  return [
    NoteMenuAction(
      itemKey: const Key('note-menu-copy'),
      label: '复制',
      enabled: hasSelection,
      onPressed: () => controller.copySelection(menuTarget: menuTarget),
    ),
    NoteMenuAction(
      itemKey: const Key('note-menu-cut'),
      label: '剪切',
      enabled: canEdit && hasSelection,
      onPressed: () =>
          controller.cutSelection(menuTarget: menuTarget, busy: busy),
    ),
    NoteMenuAction(
      itemKey: const Key('note-menu-paste'),
      label: '粘贴',
      enabled: canEdit && canPaste,
      onPressed: () => onPaste(menuTarget),
    ),
    NoteMenuAction(
      itemKey: const Key('note-menu-paste-plain'),
      label: '以纯文本粘贴',
      enabled: canEdit && hasText,
      shortcutLabel: shortcuts.pastePlain,
      onPressed: () =>
          controller.pastePlainText(menuTarget: menuTarget, busy: busy),
    ),
    const NoteMenuSeparator(key: Key('note-menu-separator-0')),
    NoteMenuSubmenu(
      itemKey: const Key('note-menu-insert'),
      submenuKey: const Key('note-submenu-insert'),
      label: '插入',
      enabled: canUseStructure,
      tapRegionGroupId: tapRegionGroupId,
      children: [
        NoteMenuAction(
          itemKey: const Key('note-menu-insert-table'),
          label: '表格',
          enabled: canUseStructure,
          onPressed: () => controller.applyInsertion(
            MarkdownInsertion.table,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-insert-divider'),
          label: '分隔线',
          enabled: canUseStructure,
          onPressed: () => controller.applyInsertion(
            MarkdownInsertion.divider,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
      ],
    ),
    NoteMenuSubmenu(
      itemKey: const Key('note-menu-text-format'),
      submenuKey: const Key('note-submenu-text-format'),
      label: '格式',
      enabled: canFormat,
      tapRegionGroupId: tapRegionGroupId,
      children: [
        NoteMenuAction(
          itemKey: const Key('note-menu-highlight'),
          label: '高亮',
          enabled: canFormat,
          checked: commandState.activeInlineFormats.contains(
            MarkdownInlineFormat.highlight,
          ),
          onPressed: () => controller.applyInlineFormat(
            MarkdownInlineFormat.highlight,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-bold'),
          label: '加粗',
          enabled: canFormat,
          checked: commandState.activeInlineFormats.contains(
            MarkdownInlineFormat.bold,
          ),
          shortcutLabel: shortcuts.bold,
          onPressed: () => controller.applyInlineFormat(
            MarkdownInlineFormat.bold,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-italic'),
          label: '斜体',
          enabled: canFormat,
          checked: commandState.activeInlineFormats.contains(
            MarkdownInlineFormat.italic,
          ),
          shortcutLabel: shortcuts.italic,
          onPressed: () => controller.applyInlineFormat(
            MarkdownInlineFormat.italic,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-strikethrough'),
          label: '删除线',
          enabled: canFormat,
          checked: commandState.activeInlineFormats.contains(
            MarkdownInlineFormat.strikethrough,
          ),
          onPressed: () => controller.applyInlineFormat(
            MarkdownInlineFormat.strikethrough,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
      ],
    ),
    NoteMenuSubmenu(
      itemKey: const Key('note-menu-paragraph'),
      submenuKey: const Key('note-submenu-paragraph'),
      label: '段落',
      enabled: canUseStructure,
      tapRegionGroupId: tapRegionGroupId,
      children: [
        NoteMenuAction(
          itemKey: const Key('note-menu-heading-1'),
          label: '标题 1',
          enabled: canUseStructure,
          checked:
              commandState.paragraphStyle == MarkdownParagraphStyle.heading1,
          onPressed: () => controller.applyParagraphStyle(
            MarkdownParagraphStyle.heading1,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-heading-2'),
          label: '标题 2',
          enabled: canUseStructure,
          checked:
              commandState.paragraphStyle == MarkdownParagraphStyle.heading2,
          onPressed: () => controller.applyParagraphStyle(
            MarkdownParagraphStyle.heading2,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-heading-3'),
          label: '标题 3',
          enabled: canUseStructure,
          checked:
              commandState.paragraphStyle == MarkdownParagraphStyle.heading3,
          onPressed: () => controller.applyParagraphStyle(
            MarkdownParagraphStyle.heading3,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-heading-4'),
          label: '标题 4',
          enabled: canUseStructure,
          checked:
              commandState.paragraphStyle == MarkdownParagraphStyle.heading4,
          onPressed: () => controller.applyParagraphStyle(
            MarkdownParagraphStyle.heading4,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-body'),
          label: '正文',
          enabled: canUseStructure,
          checked: commandState.paragraphStyle == MarkdownParagraphStyle.body,
          onPressed: () => controller.applyParagraphStyle(
            MarkdownParagraphStyle.body,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-blockquote'),
          label: '引用块',
          enabled: canUseStructure,
          checked:
              commandState.paragraphStyle == MarkdownParagraphStyle.blockquote,
          onPressed: () => controller.applyParagraphStyle(
            MarkdownParagraphStyle.blockquote,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
      ],
    ),
    NoteMenuSubmenu(
      itemKey: const Key('note-menu-list'),
      submenuKey: const Key('note-submenu-list'),
      label: '列表',
      enabled: canUseStructure,
      tapRegionGroupId: tapRegionGroupId,
      children: [
        NoteMenuAction(
          itemKey: const Key('note-menu-unordered-list'),
          label: '无序列表',
          enabled: canUseStructure,
          checked: commandState.listStyle == MarkdownListStyle.unordered,
          onPressed: () => controller.applyListStyle(
            MarkdownListStyle.unordered,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-ordered-list'),
          label: '有序列表',
          enabled: canUseStructure,
          checked: commandState.listStyle == MarkdownListStyle.ordered,
          onPressed: () => controller.applyListStyle(
            MarkdownListStyle.ordered,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-task-list'),
          label: '任务列表',
          enabled: canUseStructure,
          checked: commandState.listStyle == MarkdownListStyle.task,
          onPressed: () => controller.applyListStyle(
            MarkdownListStyle.task,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
      ],
    ),
  ];
}

({String bold, String italic, String pastePlain}) _contextMenuShortcuts() {
  final usesMacSymbols =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  return usesMacSymbols
      ? (bold: '⌘B', italic: '⌘I', pastePlain: '⇧⌘V')
      : (bold: 'Ctrl+B', italic: 'Ctrl+I', pastePlain: 'Ctrl+Shift+V');
}
