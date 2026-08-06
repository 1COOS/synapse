import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../../cupertino/markdown_context_commands.dart';
import 'live_markdown_editor_controller.dart';
import 'markdown_context_menu.dart';

typedef LiveMarkdownInsertionCallback =
    void Function(
      MarkdownInsertion insertion,
      MarkdownCommandTarget? menuTarget,
    );

List<Widget> buildLiveMarkdownContextMenuItems({
  required LiveMarkdownEditorController controller,
  required MarkdownCommandTarget? menuTarget,
  required Object tapRegionGroupId,
  required bool canEdit,
  required bool canPaste,
  required bool hasText,
  required bool busy,
  required VoidCallback onUndo,
  required VoidCallback onRedo,
  required ValueChanged<MarkdownCommandTarget?> onFind,
  required ValueChanged<MarkdownCommandTarget?> onReplace,
  required LiveMarkdownInsertionCallback onInsertion,
  required Future<void> Function(MarkdownCommandTarget? target) onPaste,
  bool? canCopyOverride,
  Future<void> Function()? onCopyOverride,
  bool? canCutOverride,
  Future<void> Function()? onCutOverride,
  bool? canPasteOverride,
}) {
  final commandState = controller.commandState(menuTarget: menuTarget);
  final hasSelection = commandState.hasSelection;
  final canMutateSelection = controller.documentSelectionCanMutate;
  final canUseStructure = canEdit && commandState.canUseStructuralCommands;
  final canFormat = canEdit && commandState.canFormat;
  final shortcuts = _contextMenuShortcuts();
  return [
    NoteMenuAction(
      itemKey: const Key('note-menu-undo'),
      label: '撤销',
      enabled: canEdit && controller.canUndo,
      shortcutLabel: shortcuts.undo,
      onPressed: onUndo,
    ),
    NoteMenuAction(
      itemKey: const Key('note-menu-redo'),
      label: '重做',
      enabled: canEdit && controller.canRedo,
      shortcutLabel: shortcuts.redo,
      onPressed: onRedo,
    ),
    const NoteMenuSeparator(key: Key('note-menu-separator-history')),
    NoteMenuAction(
      itemKey: const Key('note-menu-copy'),
      label: '复制',
      enabled: canCopyOverride ?? hasSelection,
      onPressed:
          onCopyOverride ??
          () => controller.copySelection(menuTarget: menuTarget),
    ),
    NoteMenuAction(
      itemKey: const Key('note-menu-cut'),
      label: '剪切',
      enabled:
          canCutOverride ?? (canEdit && hasSelection && canMutateSelection),
      onPressed:
          onCutOverride ??
          () => controller.cutSelection(menuTarget: menuTarget, busy: busy),
    ),
    NoteMenuAction(
      itemKey: const Key('note-menu-paste'),
      label: '粘贴',
      enabled: canPasteOverride ?? (canEdit && canPaste && canMutateSelection),
      onPressed: () => onPaste(menuTarget),
    ),
    NoteMenuAction(
      itemKey: const Key('note-menu-paste-plain'),
      label: '以纯文本粘贴',
      enabled: canEdit && hasText && canMutateSelection,
      shortcutLabel: shortcuts.pastePlain,
      onPressed: () =>
          controller.pastePlainText(menuTarget: menuTarget, busy: busy),
    ),
    const NoteMenuSeparator(key: Key('note-menu-separator-find')),
    NoteMenuAction(
      itemKey: const Key('note-menu-find'),
      label: hasSelection ? '查找所选内容' : '查找…',
      enabled: true,
      shortcutLabel: shortcuts.find,
      onPressed: () => onFind(menuTarget),
    ),
    NoteMenuAction(
      itemKey: const Key('note-menu-replace'),
      label: '替换…',
      enabled: canEdit,
      shortcutLabel: shortcuts.replace,
      onPressed: () => onReplace(menuTarget),
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
          onPressed: () => onInsertion(MarkdownInsertion.table, menuTarget),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-insert-columns'),
          label: '双栏',
          enabled: canUseStructure && !controller.activeBlockIsInsideColumns,
          onPressed: () => onInsertion(MarkdownInsertion.columns, menuTarget),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-insert-divider'),
          label: '分隔线',
          enabled: canUseStructure,
          onPressed: () => onInsertion(MarkdownInsertion.divider, menuTarget),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-insert-page-break'),
          label: '分页符',
          enabled: canUseStructure && !controller.activeBlockIsInsideColumns,
          onPressed: () => onInsertion(MarkdownInsertion.pageBreak, menuTarget),
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

({
  String undo,
  String redo,
  String bold,
  String italic,
  String pastePlain,
  String find,
  String replace,
})
_contextMenuShortcuts() {
  final usesMacSymbols =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  return usesMacSymbols
      ? (
          undo: '⌘Z',
          redo: '⇧⌘Z',
          bold: '⌘B',
          italic: '⌘I',
          pastePlain: '⇧⌘V',
          find: '⌘F',
          replace: '⌥⌘F',
        )
      : (
          undo: 'Ctrl+Z',
          redo: 'Ctrl+Shift+Z',
          bold: 'Ctrl+B',
          italic: 'Ctrl+I',
          pastePlain: 'Ctrl+Shift+V',
          find: 'Ctrl+F',
          replace: 'Ctrl+H',
        );
}
