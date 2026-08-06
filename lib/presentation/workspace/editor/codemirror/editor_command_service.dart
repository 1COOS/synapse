import 'package:flutter/services.dart';

import '../../../cupertino/markdown_context_commands.dart';
import '../../../cupertino/markdown_live_blocks.dart';
import '../markdown_document_selection.dart';
import 'editor_protocol.dart';

final class EditorCommandService {
  const EditorCommandService();

  TextEditingValue apply({
    required String markdown,
    required EditorCommandRequest request,
  }) {
    final selection = TextSelection(
      baseOffset: request.selection.anchor.clamp(0, markdown.length).toInt(),
      extentOffset: request.selection.head.clamp(0, markdown.length).toInt(),
    );
    if (markdownDocumentSelectionIntersectsProtectedStructure(
          markdown,
          selection,
        ) &&
        request.group != 'insert') {
      return TextEditingValue(text: markdown, selection: selection);
    }
    final value = TextEditingValue(text: markdown, selection: selection);
    return switch (request.group) {
      'format' => applyMarkdownInlineFormat(
        value,
        MarkdownInlineFormat.values.byName(request.command),
      ),
      'paragraph' => applyMarkdownParagraphStyle(
        value,
        MarkdownParagraphStyle.values.byName(request.command),
      ),
      'list' => applyMarkdownListStyle(
        value,
        MarkdownListStyle.values.byName(request.command),
      ),
      'insert' => _applyInsertion(
        value,
        MarkdownInsertion.values.byName(request.command),
      ),
      _ => value,
    };
  }

  TextEditingValue _applyInsertion(
    TextEditingValue value,
    MarkdownInsertion insertion,
  ) {
    final blocks = splitMarkdownLiveBlocks(value.text);
    if (blocks.isEmpty) {
      return insertMarkdownBlock(value, insertion);
    }
    final index = markdownBlockIndexForOffset(
      blocks,
      value.selection.extentOffset.clamp(0, value.text.length).toInt(),
    );
    final block = blocks[index];
    final editableText = block.text.endsWith('\r\n')
        ? block.text.substring(0, block.text.length - 2)
        : block.text.endsWith('\n')
        ? block.text.substring(0, block.text.length - 1)
        : block.text;
    final localValue = TextEditingValue(
      text: editableText,
      selection: TextSelection(
        baseOffset: (value.selection.baseOffset - block.start)
            .clamp(0, editableText.length)
            .toInt(),
        extentOffset: (value.selection.extentOffset - block.start)
            .clamp(0, editableText.length)
            .toInt(),
      ),
    );
    final localUpdated = insertMarkdownBlock(localValue, insertion);
    final separator = block.text.substring(editableText.length);
    final markdown = replaceMarkdownLiveBlock(
      markdown: value.text,
      block: block,
      replacement: '${localUpdated.text}$separator',
    );
    return TextEditingValue(
      text: markdown,
      selection: TextSelection(
        baseOffset: block.start + localUpdated.selection.baseOffset,
        extentOffset: block.start + localUpdated.selection.extentOffset,
      ),
    );
  }
}
