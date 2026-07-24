import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../cupertino/markdown_context_commands.dart';
import '../../cupertino/markdown_live_blocks.dart';
import 'markdown_context_menu.dart';
import 'markdown_styled_controller.dart';

class LiveMarkdownEditorController extends ChangeNotifier {
  LiveMarkdownEditorController({required TextEditingController document})
    : _document = document;

  TextEditingController _document;
  int _documentGeneration = 0;
  final blockController = MarkdownStyledTextEditingController();
  int? _activeOffset;
  MarkdownCommandTarget? _activeSelectionTarget;
  bool _syncingBlock = false;
  bool _updatingDocument = false;
  bool _activeTrailingInsertion = false;
  int? _activeInsertionOffset;
  MarkdownInsertion? _pendingInsertionFocus;

  TextEditingController get document => _document;
  int? get activeOffset => _activeOffset;
  bool get syncingBlock => _syncingBlock;
  bool get updatingDocument => _updatingDocument;
  bool get activeTrailingInsertion => _activeTrailingInsertion;
  int? get activeInsertionOffset => _activeInsertionOffset;

  MarkdownInsertion? takePendingInsertionFocus() {
    final pending = _pendingInsertionFocus;
    _pendingInsertionFocus = null;
    return pending;
  }

  void replaceDocument(TextEditingController document) {
    _document = document;
    _documentGeneration += 1;
    _activeOffset = null;
    _activeSelectionTarget = null;
    _activeTrailingInsertion = false;
    _activeInsertionOffset = null;
  }

  @override
  void dispose() {
    blockController.dispose();
    super.dispose();
  }

  void activateOffset(
    int offset, {
    bool trailingInsertion = false,
    bool preserveSelectionTarget = false,
  }) {
    final enteringTrailingInsertion =
        trailingInsertion &&
        (!_activeTrailingInsertion || _activeOffset != offset);
    _activeOffset = offset;
    _activeTrailingInsertion = trailingInsertion;
    _activeInsertionOffset = trailingInsertion ? offset : null;
    if (enteringTrailingInsertion) {
      _syncingBlock = true;
      blockController.value = const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
      _syncingBlock = false;
    }
    if (!preserveSelectionTarget) {
      _activeSelectionTarget = null;
    }
  }

  void updateActiveOffset(int offset) {
    _activeOffset = offset;
  }

  void clearActiveBlock() {
    _activeOffset = null;
    _activeSelectionTarget = null;
    _activeTrailingInsertion = false;
    _activeInsertionOffset = null;
  }

  void beginDocumentUpdate() {
    _updatingDocument = true;
  }

  void endDocumentUpdate() {
    _updatingDocument = false;
  }

  void setSelectionTarget(MarkdownCommandTarget? target) {
    _activeSelectionTarget = target;
  }

  bool handleFullDocumentChanged() {
    if (_updatingDocument || _activeOffset == null) {
      return false;
    }
    final selection = _document.selection;
    final nextOffset = selection.isValid
        ? _clampOffset(selection.extentOffset, _document.text.length)
        : _clampOffset(_activeOffset!, _document.text.length);
    if (selection.isValid &&
        splitMarkdownLiveBlocks(_document.text).any(
          (block) =>
              block.kind == MarkdownLiveBlockKind.image &&
              block.end == nextOffset,
        )) {
      activateOffset(nextOffset, trailingInsertion: true);
      return true;
    }
    _activeOffset = nextOffset;
    if (_activeTrailingInsertion) {
      _activeTrailingInsertion = false;
      _activeInsertionOffset = null;
    }
    clearStaleSelectionTarget();
    syncBlockController();
    return true;
  }

  void syncBlockController({int? selectionOffset}) {
    final activeOffset = _activeOffset;
    if (activeOffset == null) {
      return;
    }
    if (_activeTrailingInsertion) {
      return;
    }
    final blocks = splitMarkdownLiveBlocks(_document.text);
    final index = nonBlankBlockIndexForOffset(blocks, activeOffset);
    if (index == null) {
      return;
    }
    final block = blocks[index];
    final editableText = editableTextForBlock(block);
    final requestedSelectionOffset = selectionOffset == null
        ? null
        : _clampOffset(selectionOffset, editableText.length);
    if (blockController.text == editableText) {
      if (requestedSelectionOffset != null &&
          blockController.selection.extentOffset != requestedSelectionOffset) {
        _syncingBlock = true;
        blockController.selection = TextSelection.collapsed(
          offset: requestedSelectionOffset,
        );
        _syncingBlock = false;
      }
      clearStaleSelectionTarget();
      return;
    }
    _activeSelectionTarget = null;
    _syncingBlock = true;
    final oldSelection = blockController.selection;
    final nextSelectionOffset =
        requestedSelectionOffset ??
        (oldSelection.isValid
            ? _clampOffset(oldSelection.extentOffset, editableText.length)
            : editableText.length);
    blockController.value = TextEditingValue(
      text: editableText,
      selection: TextSelection.collapsed(offset: nextSelectionOffset),
    );
    _syncingBlock = false;
  }

  bool replaceActiveBlock(String text) {
    final activeOffset = _activeOffset;
    if (_syncingBlock || activeOffset == null) {
      return false;
    }
    if (_activeTrailingInsertion) {
      return _replaceVirtualTrailingBlock(text);
    }
    final markdown = _document.text;
    final blocks = splitMarkdownLiveBlocks(markdown);
    final index = nonBlankBlockIndexForOffset(blocks, activeOffset);
    if (index == null) {
      return false;
    }
    final block = blocks[index];
    final editableText = editableTextForBlock(block);
    final blockSelection = blockController.selection;
    if (_shouldBeginBlockInsertion(
      block: block,
      editableText: editableText,
      replacement: text,
      selection: blockSelection,
    )) {
      activateOffset(block.end, trailingInsertion: true);
      _updatingDocument = true;
      _document.selection = TextSelection.collapsed(offset: block.end);
      _updatingDocument = false;
      notifyListeners();
      return true;
    }
    final separator = block.text.substring(editableText.length);
    final textSelectionOffset = blockSelection.isValid
        ? _clampOffset(blockSelection.extentOffset, text.length)
        : text.length;
    final nextOffset = block.start + textSelectionOffset;
    final updated = replaceMarkdownLiveBlock(
      markdown: markdown,
      block: block,
      replacement: '$text$separator',
    );

    _updatingDocument = true;
    _document.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(
        offset: _clampOffset(nextOffset, updated.length),
      ),
    );
    _updatingDocument = false;
    _activeOffset = _clampOffset(nextOffset, updated.length);
    _activeSelectionTarget = null;
    _activeTrailingInsertion = false;
    notifyListeners();
    return true;
  }

  Future<void> copySelection({MarkdownCommandTarget? menuTarget}) async {
    final target = resolveCommandTarget(
      menuTarget: menuTarget,
      requireSelection: true,
    );
    if (target == null) {
      return;
    }
    dismissAllMacContextMenus();
    await Clipboard.setData(
      ClipboardData(
        text: target.value.text.substring(
          target.selection.start,
          target.selection.end,
        ),
      ),
    );
  }

  Future<void> cutSelection({
    MarkdownCommandTarget? menuTarget,
    required bool busy,
  }) async {
    final target = resolveCommandTarget(
      menuTarget: menuTarget,
      requireSelection: true,
    );
    if (target == null || busy) {
      return;
    }
    final captured = _captureAsyncCommand(target);
    dismissAllMacContextMenus();
    await Clipboard.setData(
      ClipboardData(
        text: target.value.text.substring(
          target.selection.start,
          target.selection.end,
        ),
      ),
    );
    if (!_isCurrentAsyncCommand(captured)) {
      return;
    }
    replaceBlockSelection('', target: target);
  }

  Future<void> pastePlainText({
    MarkdownCommandTarget? menuTarget,
    required bool busy,
  }) async {
    if (busy) {
      return;
    }
    final target = resolveCommandTarget(menuTarget: menuTarget);
    if (target == null) {
      return;
    }
    final captured = _captureAsyncCommand(target);
    dismissAllMacContextMenus();
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) {
      return;
    }
    if (!_isCurrentAsyncCommand(captured)) {
      return;
    }
    replaceBlockSelection(text, target: target);
  }

  void applyInlineFormat(
    MarkdownInlineFormat format, {
    MarkdownCommandTarget? menuTarget,
    required bool busy,
  }) {
    final target = resolveCommandTarget(
      menuTarget: menuTarget,
      requireSelection: true,
    );
    if (busy ||
        target == null ||
        !commandState(menuTarget: menuTarget).canFormat) {
      return;
    }
    dismissAllMacContextMenus();
    applyBlockValue(applyMarkdownInlineFormat(target.value, format));
  }

  void applyParagraphStyle(
    MarkdownParagraphStyle style, {
    MarkdownCommandTarget? menuTarget,
    required bool busy,
  }) {
    if (busy ||
        !commandState(menuTarget: menuTarget).canUseStructuralCommands) {
      return;
    }
    dismissAllMacContextMenus();
    applyBlockValue(
      applyMarkdownParagraphStyle(
        commandTarget(menuTarget: menuTarget).value,
        style,
      ),
    );
  }

  void applyListStyle(
    MarkdownListStyle style, {
    MarkdownCommandTarget? menuTarget,
    required bool busy,
  }) {
    if (busy ||
        !commandState(menuTarget: menuTarget).canUseStructuralCommands) {
      return;
    }
    dismissAllMacContextMenus();
    applyBlockValue(
      applyMarkdownListStyle(
        commandTarget(menuTarget: menuTarget).value,
        style,
      ),
    );
  }

  void applyInsertion(
    MarkdownInsertion insertion, {
    MarkdownCommandTarget? menuTarget,
    required bool busy,
  }) {
    if (busy ||
        !commandState(menuTarget: menuTarget).canUseStructuralCommands) {
      return;
    }
    dismissAllMacContextMenus();
    _pendingInsertionFocus = insertion;
    var value = insertMarkdownBlock(
      commandTarget(menuTarget: menuTarget).value,
      insertion,
    );
    final activeBlock = currentActiveTextBlock();
    if (insertion == MarkdownInsertion.divider &&
        activeBlock != null &&
        activeBlock.text.endsWith('\n') &&
        value.text.endsWith('\n\n')) {
      value = value.copyWith(
        text: value.text.substring(0, value.text.length - 1),
        selection: TextSelection.collapsed(offset: value.text.length - 1),
      );
    }
    applyBlockValue(value);
    if (insertion == MarkdownInsertion.divider) {
      activateOffset(_document.text.length, trailingInsertion: true);
      notifyListeners();
    }
  }

  void replaceBlockSelection(
    String replacement, {
    MarkdownCommandTarget? target,
  }) {
    final resolvedTarget = target ?? commandTarget();
    final value = resolvedTarget.value;
    final selection = resolvedTarget.selection;
    final updated = value.text.replaceRange(
      selection.start,
      selection.end,
      replacement,
    );
    applyBlockValue(
      value.copyWith(
        text: updated,
        selection: TextSelection.collapsed(
          offset: selection.start + replacement.length,
        ),
        composing: TextRange.empty,
      ),
    );
  }

  void applyBlockValue(TextEditingValue value) {
    _activeSelectionTarget = null;
    blockController.value = value;
    replaceActiveBlock(value.text);
  }

  void syncDocumentSelectionFromBlock({MarkdownCommandTarget? menuTarget}) {
    final activeOffset = _activeOffset;
    if (activeOffset == null) {
      return;
    }
    if (_activeTrailingInsertion) {
      _document.selection = TextSelection.collapsed(
        offset: _clampOffset(
          _activeInsertionOffset ?? _document.text.length,
          _document.text.length,
        ),
      );
      return;
    }
    final blocks = splitMarkdownLiveBlocks(_document.text);
    final index = nonBlankBlockIndexForOffset(blocks, activeOffset);
    if (index == null) {
      return;
    }
    final block = blocks[index];
    final selection = commandTarget(menuTarget: menuTarget).selection;
    _updatingDocument = true;
    _document.selection = TextSelection(
      baseOffset: _clampOffset(
        block.start + selection.start,
        _document.text.length,
      ),
      extentOffset: _clampOffset(
        block.start + selection.end,
        _document.text.length,
      ),
    );
    _updatingDocument = false;
  }

  MarkdownLiveBlock? currentActiveTextBlock() {
    final activeOffset = _activeOffset;
    if (activeOffset == null || _activeTrailingInsertion) {
      return null;
    }
    final blocks = splitMarkdownLiveBlocks(_document.text);
    final index = nonBlankBlockIndexForOffset(blocks, activeOffset);
    return index == null ? null : blocks[index];
  }

  String editableTextForBlock(MarkdownLiveBlock block) {
    final text = block.text;
    if (text.endsWith('\r\n')) {
      return text.substring(0, text.length - 2);
    }
    if (text.endsWith('\n')) {
      return text.substring(0, text.length - 1);
    }
    return text;
  }

  TextSelection normalizedBlockSelection() {
    return normalizedSelectionForValue(blockController.value);
  }

  TextSelection normalizedSelectionForValue(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid) {
      return TextSelection.collapsed(offset: value.text.length);
    }
    final start = _clampOffset(selection.start, value.text.length);
    final end = _clampOffset(selection.end, value.text.length);
    return TextSelection(baseOffset: start, extentOffset: end);
  }

  MarkdownCommandTarget? captureCommandTargetForMenu([
    TextEditingValue? editingValue,
  ]) {
    if (editingValue != null) {
      final block = currentActiveTextBlock();
      if (block == null || editingValue.text != blockController.text) {
        return null;
      }
      final selection = normalizedSelectionForValue(editingValue);
      if (selection.isCollapsed) {
        return null;
      }
      return MarkdownCommandTarget(
        value: editingValue.copyWith(selection: selection),
        blockStart: block.start,
      );
    }
    return resolveCommandTarget(requireSelection: true);
  }

  MarkdownCommandTarget commandTarget({MarkdownCommandTarget? menuTarget}) {
    return resolveCommandTarget(menuTarget: menuTarget)!;
  }

  MarkdownCommandTarget? resolveCommandTarget({
    MarkdownCommandTarget? menuTarget,
    bool requireSelection = false,
  }) {
    final selection = normalizedBlockSelection();
    if (!selection.isCollapsed) {
      return MarkdownCommandTarget(
        value: blockController.value.copyWith(selection: selection),
        blockStart: currentActiveTextBlock()?.start,
      );
    }
    if (_validMenuCommandTarget(menuTarget)) {
      return menuTarget;
    }
    final activeTarget = _validActiveSelectionTarget();
    if (activeTarget != null) {
      return activeTarget;
    }
    if (requireSelection) {
      return null;
    }
    return MarkdownCommandTarget(
      value: blockController.value.copyWith(selection: selection),
      blockStart: currentActiveTextBlock()?.start,
    );
  }

  MarkdownCommandState commandState({MarkdownCommandTarget? menuTarget}) {
    final target = resolveCommandTarget(menuTarget: menuTarget);
    if (target == null) {
      return markdownCommandState(blockController.value);
    }
    var fencedCode = false;
    final blockStart = target.blockStart;
    if (blockStart != null) {
      final blocks = splitMarkdownLiveBlocks(_document.text);
      final index = markdownBlockIndexForOffset(blocks, blockStart);
      if (index >= 0 && index < blocks.length) {
        fencedCode = blocks[index].kind == MarkdownLiveBlockKind.fencedCode;
      }
    }
    return markdownCommandState(target.value, fencedCode: fencedCode);
  }

  void clearStaleSelectionTarget() {
    if (_activeSelectionTarget == null ||
        _validActiveSelectionTarget() != null) {
      return;
    }
    _activeSelectionTarget = null;
  }

  int? nonBlankBlockIndexForOffset(List<MarkdownLiveBlock> blocks, int offset) {
    if (blocks.isEmpty) {
      return null;
    }
    final index = markdownBlockIndexForOffset(blocks, offset);
    if (!blocks[index].isBlank) {
      return index;
    }
    for (var previous = index - 1; previous >= 0; previous -= 1) {
      if (!blocks[previous].isBlank) {
        return previous;
      }
    }
    for (var next = index + 1; next < blocks.length; next += 1) {
      if (!blocks[next].isBlank) {
        return next;
      }
    }
    return null;
  }

  bool _replaceVirtualTrailingBlock(String text) {
    if (text.isEmpty) {
      return false;
    }
    if (text.trim().isEmpty) {
      _activeSelectionTarget = null;
      notifyListeners();
      return true;
    }
    final markdown = _document.text;
    final insertionOffset = _clampOffset(
      _activeInsertionOffset ?? markdown.length,
      markdown.length,
    );
    final prefix = _insertionPrefix(markdown, insertionOffset);
    final suffix = _insertionSuffix(markdown, insertionOffset);
    final insertionStart = insertionOffset + prefix.length;
    final blockSelection = blockController.selection;
    final textSelectionOffset = blockSelection.isValid
        ? _clampOffset(blockSelection.extentOffset, text.length)
        : text.length;
    final updated = markdown.replaceRange(
      insertionOffset,
      insertionOffset,
      '$prefix$text$suffix',
    );
    final nextOffset = insertionStart + textSelectionOffset;

    _updatingDocument = true;
    _document.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(
        offset: _clampOffset(nextOffset, updated.length),
      ),
    );
    _updatingDocument = false;
    _activeOffset = _clampOffset(nextOffset, updated.length);
    _activeSelectionTarget = null;
    _activeTrailingInsertion = false;
    _activeInsertionOffset = null;
    notifyListeners();
    return true;
  }

  bool _shouldBeginBlockInsertion({
    required MarkdownLiveBlock block,
    required String editableText,
    required String replacement,
    required TextSelection selection,
  }) {
    if ((block.kind != MarkdownLiveBlockKind.paragraph &&
            block.kind != MarkdownLiveBlockKind.heading) ||
        replacement != '$editableText\n' ||
        !selection.isValid ||
        !selection.isCollapsed ||
        selection.extentOffset != replacement.length) {
      return false;
    }
    return true;
  }

  bool _validMenuCommandTarget(MarkdownCommandTarget? target) {
    final block = currentActiveTextBlock();
    return target != null &&
        target.hasSelection &&
        block != null &&
        target.blockStart == block.start &&
        target.value.text == blockController.text;
  }

  MarkdownCommandTarget? _validActiveSelectionTarget() {
    final target = _activeSelectionTarget;
    final block = currentActiveTextBlock();
    if (target == null ||
        block == null ||
        target.blockStart != block.start ||
        target.value.text != editableTextForBlock(block) ||
        target.value.text != blockController.text) {
      return null;
    }
    final selection = target.selection;
    if (!selection.isValid || selection.isCollapsed) {
      return null;
    }
    final start = _clampOffset(selection.start, target.value.text.length);
    final end = _clampOffset(selection.end, target.value.text.length);
    if (start == end) {
      return null;
    }
    return MarkdownCommandTarget(
      value: target.value.copyWith(
        selection: TextSelection(baseOffset: start, extentOffset: end),
        composing: TextRange.empty,
      ),
      blockStart: target.blockStart,
    );
  }

  _AsyncMarkdownCommand _captureAsyncCommand(MarkdownCommandTarget target) {
    return _AsyncMarkdownCommand(
      document: _document,
      documentGeneration: _documentGeneration,
      target: target,
      activeOffset: _activeOffset,
      trailingInsertion: _activeTrailingInsertion,
    );
  }

  bool _isCurrentAsyncCommand(_AsyncMarkdownCommand command) {
    if (!identical(_document, command.document) ||
        _documentGeneration != command.documentGeneration) {
      return false;
    }
    final target = command.target;
    if (target.blockStart == null) {
      return command.trailingInsertion &&
          _activeTrailingInsertion &&
          _activeOffset == command.activeOffset &&
          blockController.text == target.value.text;
    }
    final block = currentActiveTextBlock();
    return block != null &&
        block.start == target.blockStart &&
        editableTextForBlock(block) == target.value.text &&
        blockController.text == target.value.text;
  }
}

class _AsyncMarkdownCommand {
  const _AsyncMarkdownCommand({
    required this.document,
    required this.documentGeneration,
    required this.target,
    required this.activeOffset,
    required this.trailingInsertion,
  });

  final TextEditingController document;
  final int documentGeneration;
  final MarkdownCommandTarget target;
  final int? activeOffset;
  final bool trailingInsertion;
}

String _insertionPrefix(String markdown, int offset) {
  final before = markdown.substring(0, offset);
  if (before.isEmpty || before.endsWith('\n\n')) {
    return '';
  }
  if (before.endsWith('\n')) {
    return '\n';
  }
  return '\n\n';
}

String _insertionSuffix(String markdown, int offset) {
  if (offset >= markdown.length) {
    return '';
  }
  return markdown.startsWith('\n', offset) ? '\n' : '\n\n';
}

int _clampOffset(int offset, int length) {
  if (offset < 0) {
    return 0;
  }
  if (offset > length) {
    return length;
  }
  return offset;
}
