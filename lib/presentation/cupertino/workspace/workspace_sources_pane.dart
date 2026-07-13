import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../domain/vault/vault_resource.dart';
import '../../workspace/controller/workspace_controller.dart';
import '../../workspace/editor/pane_editor_context.dart';
import '../../workspace/state/note_materials_registry.dart';
import '../../workspace/state/split_workspace_controller.dart';
import 'workspace_controls.dart';
import 'workspace_layout.dart';
import 'workspace_sources.dart';

typedef SourceDeleteConfirmation =
    Future<PaneEditorCommandOutcome> Function(
      PaneEditorContext context,
      SourceItem source,
    );

typedef ProposalDeleteConfirmation =
    Future<PaneEditorCommandOutcome> Function(
      PaneEditorContext context,
      AiProposal proposal,
    );

final class WorkspaceSourcesPane extends StatefulWidget {
  const WorkspaceSourcesPane({
    super.key,
    required this.workspace,
    required this.controller,
    required this.onDeleteSource,
    required this.onDeleteProposal,
  });

  final WorkspaceState workspace;
  final WorkspaceController controller;
  final SourceDeleteConfirmation onDeleteSource;
  final ProposalDeleteConfirmation onDeleteProposal;

  @override
  State<WorkspaceSourcesPane> createState() => _WorkspaceSourcesPaneState();
}

final class _WorkspaceSourcesPaneState extends State<WorkspaceSourcesPane> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editorContext = _captureFocusedEditorContext();
    final resolved = editorContext == null
        ? null
        : widget.controller.resolvePaneEditorContext(editorContext);
    final sources =
        (widget.workspace.reloadRequired
                ? const <SourceItem>[]
                : resolved?.session.note.sources ?? const <SourceItem>[])
            .where((source) => source.type == SourceType.image)
            .toList();
    final materials = resolved == null
        ? NoteMaterialsSnapshot.empty
        : widget.workspace.materialsFor(resolved.noteId);
    final busy = widget.workspace.isBusy;

    return WorkspacePane(
      key: const Key('source-pane'),
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: (node, event) =>
            _handleKeyEvent(node, event, editorContext),
        child: GestureDetector(
          key: const Key('image-input-area'),
          behavior: HitTestBehavior.opaque,
          onTap: _focusNode.requestFocus,
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              Row(
                children: [
                  Expanded(
                    child: PrimaryButton(
                      key: const Key('add-image-button'),
                      label: '导入图片',
                      icon: CupertinoIcons.photo,
                      onPressed:
                          busy ||
                              widget.workspace.reloadRequired ||
                              !widget.workspace.hasVault
                          ? null
                          : () async {
                              await widget.controller.importImage(
                                editorContext,
                              );
                            },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SecondaryButton(
                      key: const Key('paste-image-button'),
                      label: '粘贴图片',
                      icon: CupertinoIcons.doc_on_clipboard,
                      onPressed:
                          busy ||
                              widget.workspace.reloadRequired ||
                              !widget.workspace.hasVault
                          ? null
                          : () async {
                              await widget.controller.pasteImage(editorContext);
                            },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (sources.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: EmptyState(text: '暂无图片素材'),
                ),
              if (sources.isNotEmpty)
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: sources.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.15,
                  ),
                  itemBuilder: (context, index) {
                    final source = sources[index];
                    return ImageSourceTile(
                      source: source,
                      selected: materials.selectedSourceIds.contains(source.id),
                      busy: busy,
                      imageBytes: widget.controller.readSourceAttachment(
                        source,
                      ),
                      onToggle: () {
                        final target = editorContext == null
                            ? null
                            : widget.controller.resolvePaneEditorContext(
                                editorContext,
                              );
                        if (target != null) {
                          widget.controller.toggleSourceSelection(
                            target.noteId,
                            source.id,
                          );
                        }
                      },
                      onDelete: editorContext == null
                          ? () {}
                          : () async {
                              await widget.onDeleteSource(
                                editorContext,
                                source,
                              );
                            },
                    );
                  },
                ),
              const SectionDivider(),
              PrimaryButton(
                key: const Key('generate-proposal-button'),
                label: '生成建议',
                icon: CupertinoIcons.sparkles,
                onPressed:
                    materials.selectedSourceIds.isEmpty ||
                        busy ||
                        widget.workspace.reloadRequired
                    ? null
                    : () async {
                        await widget.controller.generateProposal(editorContext);
                      },
              ),
              const SizedBox(height: 12),
              const PaneSubheading('AI 建议'),
              const SizedBox(height: 8),
              for (var index = 0; index < materials.proposals.length; index++)
                ProposalCard(
                  key: Key(
                    'proposal-${materials.proposals[index].noteId}-'
                    '${materials.proposals[index].id}',
                  ),
                  proposal: materials.proposals[index],
                  copyKey: Key(
                    index == 0
                        ? 'copy-proposal-button'
                        : 'copy-proposal-button-'
                              '${materials.proposals[index].id}',
                  ),
                  deleteKey: Key(
                    index == 0
                        ? 'delete-proposal-button'
                        : 'delete-proposal-button-'
                              '${materials.proposals[index].id}',
                  ),
                  busy: busy || widget.workspace.reloadRequired,
                  onCopy: editorContext == null
                      ? () {}
                      : () async {
                          await widget.controller.copyProposal(
                            editorContext,
                            materials.proposals[index],
                          );
                        },
                  onDelete: editorContext == null
                      ? () {}
                      : () async {
                          await widget.onDeleteProposal(
                            editorContext,
                            materials.proposals[index],
                          );
                        },
                ),
            ],
          ),
        ),
      ),
    );
  }

  PaneEditorContext? _captureFocusedEditorContext() {
    final pane = _findSplitLeaf(
      widget.workspace.splitRoot,
      widget.workspace.focusedPaneId,
    );
    return pane == null
        ? null
        : widget.controller.capturePaneEditorContext(pane.paneId);
  }

  KeyEventResult _handleKeyEvent(
    FocusNode node,
    KeyEvent event,
    PaneEditorContext? editorContext,
  ) {
    if (!_isPasteImageShortcutKeyUp(event)) {
      return KeyEventResult.ignored;
    }
    if (!widget.workspace.isBusy &&
        !widget.workspace.reloadRequired &&
        widget.workspace.hasVault) {
      unawaited(widget.controller.pasteImage(editorContext));
    }
    return KeyEventResult.handled;
  }
}

bool _isPasteImageShortcutKeyUp(KeyEvent event) {
  return event is KeyUpEvent &&
      event.logicalKey == LogicalKeyboardKey.keyV &&
      (HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed);
}

SplitLeaf? _findSplitLeaf(SplitNode node, String paneId) {
  return switch (node) {
    final SplitLeaf leaf => leaf.paneId == paneId ? leaf : null,
    final SplitBranch branch =>
      _findSplitLeaf(branch.first, paneId) ??
          _findSplitLeaf(branch.second, paneId),
  };
}
