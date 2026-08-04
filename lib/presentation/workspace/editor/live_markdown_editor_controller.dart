import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../cupertino/markdown_context_commands.dart';
import '../../cupertino/markdown_live_blocks.dart';
import 'markdown_context_menu.dart';
import 'markdown_document_selection.dart';
import 'markdown_styled_controller.dart';

class LiveMarkdownEditorController extends ChangeNotifier {
  LiveMarkdownEditorController({required TextEditingController document})
    : _document = document,
      _historyValue = document.value {
    _document.addListener(_handleDocumentHistoryChanged);
  }

  static const _historyLimit = 100;
  static const _historyCoalescingDelay = Duration(milliseconds: 500);

  TextEditingController _document;
  TextEditingValue _historyValue;
  final List<TextEditingValue> _undoHistory = [];
  final List<TextEditingValue> _redoHistory = [];
  DateTime? _lastHistoryChangeAt;
  bool _historyGroupOpen = false;
  bool _restoringHistory = false;
  int _documentGeneration = 0;
  final blockController = MarkdownStyledTextEditingController();
  int? _activeOffset;
  MarkdownCommandTarget? _activeSelectionTarget;
  bool _syncingBlock = false;
  bool _updatingDocument = false;
  bool _activeTrailingInsertion = false;
  int? _activeInsertionOffset;
  MarkdownInsertion? _pendingInsertionFocus;
  TextSelection? _documentSelection;

  TextEditingController get document => _document;
  int? get activeOffset => _activeOffset;
  bool get syncingBlock => _syncingBlock;
  bool get updatingDocument => _updatingDocument;
  bool get activeTrailingInsertion => _activeTrailingInsertion;
  int? get activeInsertionOffset => _activeInsertionOffset;
  bool get canUndo => _undoHistory.isNotEmpty;
  bool get canRedo => _redoHistory.isNotEmpty;
  TextSelection? get documentSelection => _normalizedDocumentSelection();
  bool get hasDocumentSelection => documentSelection != null;
  bool get documentSelectionCanMutate {
    final target = _documentSelectionTarget();
    if (target == null) {
      return true;
    }
    return replaceMarkdownDocumentSelection(
      value: target.value,
      replacement: '',
    ).allowed;
  }

  bool get activeBlockIsInsideColumns {
    final offset = _activeOffset;
    if (offset == null) {
      return false;
    }
    return markdownColumnsLayoutForOffset(
          splitMarkdownLiveBlocks(_document.text),
          offset,
        ) !=
        null;
  }

  MarkdownInsertion? takePendingInsertionFocus() {
    final pending = _pendingInsertionFocus;
    _pendingInsertionFocus = null;
    return pending;
  }

  void replaceDocument(TextEditingController document) {
    _document.removeListener(_handleDocumentHistoryChanged);
    _endUndoGroup();
    _document = document;
    _historyValue = document.value;
    _undoHistory.clear();
    _redoHistory.clear();
    _document.addListener(_handleDocumentHistoryChanged);
    _documentGeneration += 1;
    _activeOffset = null;
    _activeSelectionTarget = null;
    _activeTrailingInsertion = false;
    _activeInsertionOffset = null;
    _documentSelection = null;
  }

  @override
  void dispose() {
    _document.removeListener(_handleDocumentHistoryChanged);
    blockController.dispose();
    super.dispose();
  }

  void endUndoGroup() {
    _endUndoGroup();
  }

  bool undo() {
    if (!canUndo) {
      return false;
    }
    _endUndoGroup();
    final current = _document.value;
    final target = _undoHistory.removeLast();
    _pushHistoryValue(_redoHistory, current);
    _restoreHistoryValue(target);
    notifyListeners();
    return true;
  }

  bool redo() {
    if (!canRedo) {
      return false;
    }
    _endUndoGroup();
    final current = _document.value;
    final target = _redoHistory.removeLast();
    _pushHistoryValue(_undoHistory, current);
    _restoreHistoryValue(target);
    notifyListeners();
    return true;
  }

  void _handleDocumentHistoryChanged() {
    final next = _document.value;
    if (_restoringHistory) {
      _historyValue = next;
      return;
    }
    if (_historyValue.text == next.text) {
      _historyValue = next;
      return;
    }
    final now = DateTime.now();
    final coalescesWithPrevious =
        _historyGroupOpen &&
        _lastHistoryChangeAt != null &&
        now.difference(_lastHistoryChangeAt!) <= _historyCoalescingDelay;
    if (!coalescesWithPrevious) {
      _pushHistoryValue(_undoHistory, _historyValue);
    }
    _redoHistory.clear();
    _historyValue = next;
    _historyGroupOpen = true;
    _lastHistoryChangeAt = now;
  }

  void _endUndoGroup() {
    _historyGroupOpen = false;
    _lastHistoryChangeAt = null;
  }

  void _pushHistoryValue(
    List<TextEditingValue> history,
    TextEditingValue value,
  ) {
    if (history.isNotEmpty && history.last.text == value.text) {
      history[history.length - 1] = value;
      return;
    }
    history.add(value.copyWith(composing: TextRange.empty));
    if (history.length > _historyLimit) {
      history.removeAt(0);
    }
  }

  void _restoreHistoryValue(TextEditingValue value) {
    final selection = value.selection.isValid
        ? TextSelection(
            baseOffset: _clampOffset(
              value.selection.baseOffset,
              value.text.length,
            ),
            extentOffset: _clampOffset(
              value.selection.extentOffset,
              value.text.length,
            ),
            affinity: value.selection.affinity,
            isDirectional: value.selection.isDirectional,
          )
        : TextSelection.collapsed(offset: value.text.length);
    _restoringHistory = true;
    try {
      _document.value = value.copyWith(
        selection: selection,
        composing: TextRange.empty,
      );
      _historyValue = _document.value;
    } finally {
      _restoringHistory = false;
    }
    _activeSelectionTarget = null;
    _documentSelection = null;
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
    _documentSelection = null;
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

  void setDocumentSelection(TextSelection? selection) {
    if (selection == null || !selection.isValid || selection.isCollapsed) {
      _documentSelection = null;
      return;
    }
    final start = _clampOffset(selection.start, _document.text.length);
    final end = _clampOffset(selection.end, _document.text.length);
    if (start == end) {
      _documentSelection = null;
      return;
    }
    _documentSelection = TextSelection(
      baseOffset: selection.baseOffset <= selection.extentOffset ? start : end,
      extentOffset: selection.baseOffset <= selection.extentOffset
          ? end
          : start,
    );
    _activeSelectionTarget = null;
  }

  void clearDocumentSelection() {
    _documentSelection = null;
  }

  bool handleFullDocumentChanged() {
    if (_updatingDocument || _activeOffset == null) {
      return false;
    }
    final selection = _document.selection;
    final nextOffset = selection.isValid
        ? _clampOffset(selection.extentOffset, _document.text.length)
        : _clampOffset(_activeOffset!, _document.text.length);
    final blocks = splitMarkdownLiveBlocks(_document.text);
    if (selection.isValid &&
        blocks.any(
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
    final activeIndex = nonBlankBlockIndexForOffset(blocks, nextOffset);
    final selectionOffset = activeIndex == null
        ? null
        : nextOffset - blocks[activeIndex].start;
    syncBlockController(selectionOffset: selectionOffset);
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
    _documentSelection = null;
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
    if (text.trim().isEmpty && markdownBlockIsBetweenTables(blocks, index)) {
      return _replaceTableBridgeWithSeparator(
        markdown: markdown,
        blocks: blocks,
        blockIndex: index,
      );
    }
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

  bool _replaceTableBridgeWithSeparator({
    required String markdown,
    required List<MarkdownLiveBlock> blocks,
    required int blockIndex,
  }) {
    int? previousTableIndex;
    for (var index = blockIndex - 1; index >= 0; index -= 1) {
      if (blocks[index].isBlank) {
        continue;
      }
      previousTableIndex = index;
      break;
    }
    int? nextTableIndex;
    for (var index = blockIndex + 1; index < blocks.length; index += 1) {
      if (blocks[index].isBlank) {
        continue;
      }
      nextTableIndex = index;
      break;
    }
    if (previousTableIndex == null || nextTableIndex == null) {
      return false;
    }
    final lineBreak = markdown.contains('\r\n') ? '\r\n' : '\n';
    final insertionOffset = blocks[previousTableIndex].end;
    final updated = markdown.replaceRange(
      insertionOffset,
      blocks[nextTableIndex].start,
      lineBreak,
    );
    _updatingDocument = true;
    _document.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: insertionOffset),
    );
    _updatingDocument = false;
    _activeOffset = null;
    _activeSelectionTarget = null;
    _activeTrailingInsertion = false;
    _activeInsertionOffset = null;
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
    _applyCommandValue(target, applyMarkdownInlineFormat(target.value, format));
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
    final target = commandTarget(menuTarget: menuTarget);
    _applyCommandValue(
      target,
      applyMarkdownParagraphStyle(target.value, style),
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
    final target = commandTarget(menuTarget: menuTarget);
    _applyCommandValue(target, applyMarkdownListStyle(target.value, style));
  }

  void applyInsertion(
    MarkdownInsertion insertion, {
    MarkdownCommandTarget? menuTarget,
    required bool busy,
  }) {
    final target = resolveCommandTarget(menuTarget: menuTarget);
    if (busy ||
        target?.documentScoped == true ||
        !commandState(menuTarget: menuTarget).canUseStructuralCommands) {
      return;
    }
    dismissAllMacContextMenus();
    _pendingInsertionFocus = insertion;
    var value = insertMarkdownBlock(target!.value, insertion);
    final activeBlock = currentActiveTextBlock();
    if ((insertion == MarkdownInsertion.divider ||
            insertion == MarkdownInsertion.pageBreak) &&
        activeBlock != null &&
        activeBlock.text.endsWith('\n') &&
        value.text.endsWith('\n\n')) {
      value = value.copyWith(
        text: value.text.substring(0, value.text.length - 1),
        selection: TextSelection.collapsed(offset: value.text.length - 1),
      );
    }
    applyBlockValue(value);
    if (insertion == MarkdownInsertion.columns) {
      final offset = _document.selection.isValid
          ? _document.selection.extentOffset
          : _document.text.length;
      activateOffset(offset, trailingInsertion: true);
      notifyListeners();
      return;
    }
    if (insertion == MarkdownInsertion.divider ||
        insertion == MarkdownInsertion.pageBreak) {
      activateOffset(_document.text.length, trailingInsertion: true);
      notifyListeners();
    }
  }

  void replaceBlockSelection(
    String replacement, {
    MarkdownCommandTarget? target,
  }) {
    final resolvedTarget = target ?? commandTarget();
    if (resolvedTarget.documentScoped) {
      replaceDocumentSelection(replacement, target: resolvedTarget);
      return;
    }
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
    _endUndoGroup();
    _activeSelectionTarget = null;
    blockController.value = value;
    replaceActiveBlock(value.text);
  }

  bool replaceDocumentSelection(
    String replacement, {
    MarkdownCommandTarget? target,
  }) {
    final resolvedTarget = target ?? _documentSelectionTarget();
    if (resolvedTarget == null || !resolvedTarget.documentScoped) {
      return false;
    }
    final result = replaceMarkdownDocumentSelection(
      value: resolvedTarget.value,
      replacement: replacement,
    );
    final value = result.value;
    if (value == null) {
      return false;
    }
    _applyDocumentValue(value, preserveSelection: false);
    return true;
  }

  void _applyCommandValue(
    MarkdownCommandTarget target,
    TextEditingValue value,
  ) {
    if (target.documentScoped) {
      _applyDocumentValue(value, preserveSelection: true);
      return;
    }
    applyBlockValue(value);
  }

  void _applyDocumentValue(
    TextEditingValue value, {
    required bool preserveSelection,
  }) {
    _endUndoGroup();
    _activeSelectionTarget = null;
    _updatingDocument = true;
    _document.value = value.copyWith(composing: TextRange.empty);
    _updatingDocument = false;
    _activeOffset = null;
    _activeTrailingInsertion = false;
    _activeInsertionOffset = null;
    _documentSelection = preserveSelection && !value.selection.isCollapsed
        ? value.selection
        : null;
    notifyListeners();
  }

  void syncDocumentSelectionFromBlock({MarkdownCommandTarget? menuTarget}) {
    final documentTarget = _documentSelectionTarget();
    if (documentTarget != null) {
      _updatingDocument = true;
      _document.selection = documentTarget.selection;
      _updatingDocument = false;
      return;
    }
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
    final documentTarget = _documentSelectionTarget();
    if (documentTarget != null) {
      return documentTarget;
    }
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
    final documentTarget = _documentSelectionTarget();
    if (documentTarget != null) {
      return documentTarget;
    }
    if (_validDocumentMenuTarget(menuTarget)) {
      return menuTarget;
    }
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
    if (target.documentScoped) {
      final selection = target.selection;
      fencedCode = splitMarkdownLiveBlocks(target.value.text).any(
        (block) =>
            block.kind == MarkdownLiveBlockKind.fencedCode &&
            selection.start < block.end &&
            selection.end > block.start,
      );
      final state = markdownCommandState(target.value, fencedCode: fencedCode);
      if (markdownDocumentSelectionIntersectsProtectedStructure(
        target.value.text,
        target.selection,
      )) {
        return MarkdownCommandState(
          hasSelection: state.hasSelection,
          inCode: true,
          activeInlineFormats: const {},
          paragraphStyle: null,
          listStyle: null,
        );
      }
      return state;
    }
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

  TextSelection? _normalizedDocumentSelection() {
    final selection = _documentSelection;
    if (selection == null || !selection.isValid || selection.isCollapsed) {
      return null;
    }
    final start = _clampOffset(selection.start, _document.text.length);
    final end = _clampOffset(selection.end, _document.text.length);
    if (start == end) {
      return null;
    }
    return TextSelection(
      baseOffset: selection.baseOffset <= selection.extentOffset ? start : end,
      extentOffset: selection.baseOffset <= selection.extentOffset
          ? end
          : start,
    );
  }

  MarkdownCommandTarget? _documentSelectionTarget() {
    final selection = _normalizedDocumentSelection();
    if (selection == null) {
      return null;
    }
    return MarkdownCommandTarget(
      value: _document.value.copyWith(
        selection: selection,
        composing: TextRange.empty,
      ),
      blockStart: null,
      documentScoped: true,
    );
  }

  bool _validDocumentMenuTarget(MarkdownCommandTarget? target) {
    return target != null &&
        target.documentScoped &&
        target.hasSelection &&
        target.value.text == _document.text;
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
    if (!blocks[index].isBlank && !blocks[index].isColumnsMarker) {
      return index;
    }
    for (var previous = index - 1; previous >= 0; previous -= 1) {
      if (!blocks[previous].isBlank && !blocks[previous].isColumnsMarker) {
        return previous;
      }
    }
    for (var next = index + 1; next < blocks.length; next += 1) {
      if (!blocks[next].isBlank && !blocks[next].isColumnsMarker) {
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
    if (target.documentScoped) {
      final selection = _normalizedDocumentSelection();
      return selection != null &&
          target.value.text == _document.text &&
          target.selection == selection;
    }
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
