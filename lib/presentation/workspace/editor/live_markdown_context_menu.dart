import 'package:flutter/cupertino.dart';

import '../../cupertino/markdown_context_commands.dart';
import 'live_markdown_editor_controller.dart';
import 'markdown_context_menu.dart';

List<Widget> buildLiveMarkdownContextMenuItems({
  required LiveMarkdownEditorController controller,
  required MarkdownCommandTarget? menuTarget,
  required bool canEdit,
  required bool canPaste,
  required bool hasText,
  required bool busy,
  required Future<void> Function(MarkdownCommandTarget? target) onPaste,
}) {
  final hasSelection =
      controller.resolveCommandTarget(
        menuTarget: menuTarget,
        requireSelection: true,
      ) !=
      null;
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
      onPressed: () =>
          controller.pastePlainText(menuTarget: menuTarget, busy: busy),
    ),
    const NoteMenuSeparator(key: Key('note-menu-separator-0')),
    NoteMenuSubmenu(
      itemKey: const Key('note-menu-insert'),
      submenuKey: const Key('note-submenu-insert'),
      label: '插入',
      children: [
        NoteMenuAction(
          itemKey: const Key('note-menu-insert-table'),
          label: '表格',
          enabled: canEdit,
          onPressed: () => controller.applyInsertion(
            MarkdownInsertion.table,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-insert-annotation'),
          label: '标注',
          enabled: canEdit,
          onPressed: () => controller.applyInsertion(
            MarkdownInsertion.annotation,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-insert-divider'),
          label: '分割线',
          enabled: canEdit,
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
      label: '文本格式',
      children: [
        const NoteMenuAction(
          itemKey: Key('note-menu-highlight'),
          label: '高亮',
          enabled: false,
          onPressed: null,
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-bold'),
          label: '加粗',
          enabled: canEdit && hasSelection,
          onPressed: () => controller.applyInlineFormat(
            MarkdownInlineFormat.bold,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-italic'),
          label: '斜体',
          enabled: canEdit && hasSelection,
          onPressed: () => controller.applyInlineFormat(
            MarkdownInlineFormat.italic,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-strikethrough'),
          label: '删除线',
          enabled: canEdit && hasSelection,
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
      label: '段落设置',
      children: [
        NoteMenuAction(
          itemKey: const Key('note-menu-heading-1'),
          label: '标题 1',
          enabled: canEdit,
          onPressed: () => controller.applyParagraphStyle(
            MarkdownParagraphStyle.heading1,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-heading-2'),
          label: '标题 2',
          enabled: canEdit,
          onPressed: () => controller.applyParagraphStyle(
            MarkdownParagraphStyle.heading2,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-heading-3'),
          label: '标题 3',
          enabled: canEdit,
          onPressed: () => controller.applyParagraphStyle(
            MarkdownParagraphStyle.heading3,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-heading-4'),
          label: '标题 4',
          enabled: canEdit,
          onPressed: () => controller.applyParagraphStyle(
            MarkdownParagraphStyle.heading4,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-body'),
          label: '正文',
          enabled: canEdit,
          onPressed: () => controller.applyParagraphStyle(
            MarkdownParagraphStyle.body,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
      ],
    ),
    NoteMenuSubmenu(
      itemKey: const Key('note-menu-list'),
      submenuKey: const Key('note-submenu-list'),
      label: '列表设置',
      children: [
        NoteMenuAction(
          itemKey: const Key('note-menu-unordered-list'),
          label: '无序列表',
          enabled: canEdit,
          onPressed: () => controller.applyListStyle(
            MarkdownListStyle.unordered,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-ordered-list'),
          label: '有序列表',
          enabled: canEdit,
          onPressed: () => controller.applyListStyle(
            MarkdownListStyle.ordered,
            menuTarget: menuTarget,
            busy: busy,
          ),
        ),
        NoteMenuAction(
          itemKey: const Key('note-menu-task-list'),
          label: '任务列表',
          enabled: canEdit,
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
