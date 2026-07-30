import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../domain/vault/vault_resource.dart';
import '../../workspace/controller/workspace_controller.dart';
import '../../workspace/editor/pane_editor_context.dart';
import '../../workspace/editor/markdown_image_transform.dart';
import '../../workspace/state/note_materials_registry.dart';
import '../../workspace/state/split_workspace_controller.dart';
import 'workspace_controls.dart';
import 'workspace_layout.dart';
import 'workspace_sources.dart';
import 'workspace_theme.dart';

typedef SourceDeleteConfirmation =
    Future<PaneEditorCommandOutcome> Function(
      PaneEditorContext context,
      AiMaterial source,
    );

typedef SourcesDeleteConfirmation =
    Future<PaneEditorCommandOutcome> Function(
      PaneEditorContext context,
      List<AiMaterial> sources,
    );

typedef AttachmentDeleteConfirmation =
    Future<PaneEditorCommandOutcome> Function(
      PaneEditorContext context,
      List<NoteAttachment> attachments,
    );

typedef ProposalDeleteConfirmation =
    Future<PaneEditorCommandOutcome> Function(
      PaneEditorContext context,
      AiProposal proposal,
    );

typedef ProposalsDeleteConfirmation =
    Future<PaneEditorCommandOutcome> Function(
      PaneEditorContext context,
      List<AiProposal> proposals,
    );

final class WorkspaceSourcesPane extends StatefulWidget {
  const WorkspaceSourcesPane({
    super.key,
    required this.workspace,
    required this.controller,
    required this.onDeleteSource,
    required this.onDeleteSources,
    required this.onDeleteAttachments,
    required this.onDeleteProposal,
    required this.onDeleteProposals,
  });

  final WorkspaceState workspace;
  final WorkspaceController controller;
  final SourceDeleteConfirmation onDeleteSource;
  final SourcesDeleteConfirmation onDeleteSources;
  final AttachmentDeleteConfirmation onDeleteAttachments;
  final ProposalDeleteConfirmation onDeleteProposal;
  final ProposalsDeleteConfirmation onDeleteProposals;

  @override
  State<WorkspaceSourcesPane> createState() => _WorkspaceSourcesPaneState();
}

final class _WorkspaceSourcesPaneState extends State<WorkspaceSourcesPane> {
  static const _defaultSourcesAreaFraction = 0.55;
  static const _preferredMinimumSourcesHeight = 220.0;
  static const _minimumCompactSourcesHeight = 96.0;
  static const _reservedProposalAreaHeight = 230.0;

  final _focusNode = FocusNode();
  final _proposalScrollController = ScrollController();
  final _attachmentScrollController = ScrollController();
  final Map<String, bool> _sourcesExpandedByNote = <String, bool>{};
  final Map<String, String> _expandedProposalByNote = <String, String>{};
  final Set<String> _selectedProposalIds = <String>{};
  double _sourcesAreaFraction = _defaultSourcesAreaFraction;
  String? _proposalBatchNoteId;
  bool _resizingSources = false;
  bool _generatingProposal = false;

  @override
  void didUpdateWidget(covariant WorkspaceSourcesPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldNoteId = _focusedNoteId(oldWidget.workspace);
    final noteId = _focusedNoteId(widget.workspace);
    if (oldNoteId != noteId) {
      _proposalBatchNoteId = null;
      _selectedProposalIds.clear();
    }
    if (noteId == null) {
      return;
    }
    final proposals = widget.workspace.materialsFor(noteId).proposals;
    _selectedProposalIds.retainAll(
      proposals.map((proposal) => proposal.id).toSet(),
    );
    final latest = proposals.firstOrNull;
    final expandedId = _expandedProposalByNote[noteId];
    if (expandedId != null &&
        !proposals.any((proposal) => proposal.id == expandedId)) {
      if (latest == null) {
        _expandedProposalByNote.remove(noteId);
      } else {
        _expandedProposalByNote[noteId] = latest.id;
      }
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _proposalScrollController.dispose();
    _attachmentScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editorContext = _captureFocusedEditorContext();
    final resolved = editorContext == null
        ? null
        : widget.controller.resolvePaneEditorContext(editorContext);
    final aiMaterials =
        (widget.workspace.reloadRequired
                ? const <AiMaterial>[]
                : resolved?.session.note.aiMaterials ?? const <AiMaterial>[])
            .toList();
    final attachments = widget.workspace.reloadRequired
        ? const <NoteAttachment>[]
        : resolved?.session.note.attachments ?? const <NoteAttachment>[];
    final materials = resolved == null
        ? NoteMaterialsSnapshot.empty
        : widget.workspace.materialsFor(resolved.noteId);
    final busy = widget.workspace.isBusy;
    final noteId = resolved?.noteId;
    final sourcesExpanded = noteId == null
        ? true
        : _sourcesExpandedByNote[noteId] ?? true;
    final expandedProposalId = noteId == null
        ? null
        : _expandedProposalByNote[noteId] ??
              materials.proposals.firstOrNull?.id;
    final actionsDisabled =
        busy || widget.workspace.reloadRequired || !widget.workspace.hasVault;
    final proposalIds = {
      for (final proposal in materials.proposals) proposal.id,
    };
    final proposalBatchMode = noteId != null && _proposalBatchNoteId == noteId;
    final selectedProposalIds = proposalBatchMode
        ? _selectedProposalIds.intersection(proposalIds)
        : const <String>{};

    return WorkspacePane(
      key: const Key('source-pane'),
      child: IndexedStack(
        index: widget.workspace.rightTab == WorkspaceRightTab.ai ? 0 : 1,
        children: [
          _buildAiTab(
            sources: aiMaterials,
            sourcesExpanded: sourcesExpanded,
            materials: materials,
            editorContext: editorContext,
            noteId: noteId,
            expandedProposalId: expandedProposalId,
            proposalBatchMode: proposalBatchMode,
            selectedProposalIds: selectedProposalIds,
            actionsDisabled: actionsDisabled,
            busy: busy,
          ),
          _buildAttachmentsTab(
            attachments: attachments,
            editorContext: editorContext,
            currentMarkdown: resolved?.session.controller.text ?? '',
            busy: busy,
          ),
        ],
      ),
    );
  }

  Widget _buildAiTab({
    required List<AiMaterial> sources,
    required bool sourcesExpanded,
    required NoteMaterialsSnapshot materials,
    required PaneEditorContext? editorContext,
    required String? noteId,
    required String? expandedProposalId,
    required bool proposalBatchMode,
    required Set<String> selectedProposalIds,
    required bool actionsDisabled,
    required bool busy,
  }) {
    return Focus(
      key: const Key('right-pane-ai-content'),
      focusNode: _focusNode,
      onKeyEvent: (node, event) => _handleKeyEvent(node, event, editorContext),
      child: Listener(
        key: const Key('image-input-area'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _focusNode.requestFocus(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'AI 素材 · 已选 ${materials.selectedAiMaterialIds.length} 项',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: workspaceRightPaneTitleStyle,
                  ),
                ),
                IconAction(
                  key: const Key('add-image-button'),
                  label: '导入图片素材',
                  icon: CupertinoIcons.photo,
                  onPressed: actionsDisabled
                      ? null
                      : () => _importImage(editorContext, noteId),
                ),
                IconAction(
                  key: const Key('paste-image-button'),
                  label: '粘贴图片素材',
                  icon: CupertinoIcons.doc_on_clipboard,
                  onPressed: actionsDisabled
                      ? null
                      : () => _pasteImage(editorContext, noteId),
                ),
                IconAction(
                  key: const Key('delete-selected-images-button'),
                  label: '删除已选 AI 素材',
                  icon: CupertinoIcons.trash,
                  onPressed:
                      actionsDisabled || materials.selectedAiMaterialIds.isEmpty
                      ? null
                      : () => _deleteSelectedSources(
                          editorContext,
                          sources,
                          materials.selectedAiMaterialIds,
                        ),
                ),
                IconAction(
                  key: const Key('toggle-sources-section-button'),
                  label: sourcesExpanded ? '收起 AI 素材' : '展开 AI 素材',
                  icon: sourcesExpanded
                      ? CupertinoIcons.chevron_up
                      : CupertinoIcons.chevron_down,
                  onPressed: noteId == null
                      ? null
                      : () => _setSourcesExpanded(noteId, !sourcesExpanded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => _buildMaterialsBody(
                  availableHeight: constraints.maxHeight,
                  sources: sources,
                  sourcesExpanded: sourcesExpanded,
                  materials: materials,
                  editorContext: editorContext,
                  noteId: noteId,
                  expandedProposalId: expandedProposalId,
                  proposalBatchMode: proposalBatchMode,
                  selectedProposalIds: selectedProposalIds,
                  actionsDisabled: actionsDisabled,
                  busy: busy,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMaterialsBody({
    required double availableHeight,
    required List<AiMaterial> sources,
    required bool sourcesExpanded,
    required NoteMaterialsSnapshot materials,
    required PaneEditorContext? editorContext,
    required String? noteId,
    required String? expandedProposalId,
    required bool proposalBatchMode,
    required Set<String> selectedProposalIds,
    required bool actionsDisabled,
    required bool busy,
  }) {
    final resizableSources = sourcesExpanded && sources.isNotEmpty;
    final sourcesHeight = resizableSources
        ? _resolvedSourcesHeight(availableHeight)
        : null;
    final sourcesContent = AnimatedSize(
      duration: _resizingSources
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: sourcesExpanded
          ? _buildExpandedSources(
              height: sourcesHeight ?? _minimumCompactSourcesHeight,
              sources: sources,
              materials: materials,
              editorContext: editorContext,
              busy: busy,
            )
          : _buildSelectedSourcesSummary(
              sources: sources,
              selectedSourceIds: materials.selectedAiMaterialIds,
            ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (resizableSources)
          Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: sourcesContent,
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _SourceResizeHandle(
                  key: const Key('sources-resize-handle'),
                  onDragStart: () => setState(() => _resizingSources = true),
                  onDragUpdate: (delta) =>
                      _resizeSourcesArea(delta, availableHeight),
                  onDragEnd: () => setState(() => _resizingSources = false),
                ),
              ),
            ],
          )
        else ...[
          sourcesContent,
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Hairline(),
          ),
        ],
        Row(
          children: [
            Text(
              '已选择 ${materials.selectedAiMaterialIds.length} 项',
              style: const TextStyle(color: workspaceMutedColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PrimaryButton(
                key: const Key('generate-proposal-button'),
                label: _generatingProposal ? '生成中…' : '生成 AI 建议',
                icon: CupertinoIcons.sparkles,
                busy: _generatingProposal,
                onPressed:
                    materials.selectedAiMaterialIds.isEmpty ||
                        busy ||
                        widget.workspace.reloadRequired
                    ? null
                    : _generateProposal,
              ),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Hairline(),
        ),
        _buildProposalHeader(
          noteId: noteId,
          proposals: materials.proposals,
          proposalBatchMode: proposalBatchMode,
          selectedProposalIds: selectedProposalIds,
          editorContext: editorContext,
          actionsDisabled: actionsDisabled,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            key: const Key('proposal-history-list'),
            controller: _proposalScrollController,
            padding: EdgeInsets.zero,
            itemCount: materials.proposals.isEmpty
                ? 1
                : materials.proposals.length,
            itemBuilder: (context, index) {
              if (materials.proposals.isEmpty) {
                return const SizedBox(
                  height: 80,
                  child: EmptyState(text: '选择 AI 素材后生成建议'),
                );
              }
              final proposal = materials.proposals[index];
              return ProposalCard(
                key: Key('proposal-${proposal.noteId}-${proposal.id}'),
                proposal: proposal,
                availableMaterialIds: sources
                    .map((material) => material.id)
                    .toSet(),
                expanded: proposal.id == expandedProposalId,
                selectionMode: proposalBatchMode,
                selected: selectedProposalIds.contains(proposal.id),
                selectionKey: Key('proposal-select-${proposal.id}'),
                toggleKey: Key('proposal-toggle-${proposal.id}'),
                expandKey: Key('proposal-expand-${proposal.id}'),
                copyKey: Key(
                  index == 0
                      ? 'copy-proposal-button'
                      : 'copy-proposal-button-${proposal.id}',
                ),
                deleteKey: Key(
                  index == 0
                      ? 'delete-proposal-button'
                      : 'delete-proposal-button-${proposal.id}',
                ),
                applyKey: Key(
                  index == 0
                      ? 'apply-proposal-button'
                      : 'apply-proposal-button-${proposal.id}',
                ),
                busy: busy || widget.workspace.reloadRequired,
                onToggleSelected: () => _toggleProposalSelected(proposal.id),
                onToggleExpanded: noteId == null
                    ? () {}
                    : () => _setExpandedProposal(noteId, proposal.id),
                onCopy: editorContext == null
                    ? () {}
                    : () async {
                        await widget.controller.copyProposal(
                          editorContext,
                          proposal,
                        );
                      },
                onDelete: editorContext == null
                    ? () {}
                    : () async {
                        await widget.onDeleteProposal(editorContext, proposal);
                      },
                onApply: editorContext == null
                    ? () {}
                    : () => _confirmAndApplyProposal(editorContext, proposal),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildProposalHeader({
    required String? noteId,
    required List<AiProposal> proposals,
    required bool proposalBatchMode,
    required Set<String> selectedProposalIds,
    required PaneEditorContext? editorContext,
    required bool actionsDisabled,
  }) {
    if (!proposalBatchMode) {
      return Row(
        children: [
          const Text('AI 建议', style: workspaceRightPaneTitleStyle),
          const SizedBox(width: 4),
          Text(
            '· ${proposals.length}',
            style: const TextStyle(color: workspaceMutedColor, fontSize: 12),
          ),
          const Spacer(),
          IconAction(
            key: const Key('proposal-batch-mode-button'),
            label: '批量管理 AI 建议',
            icon: CupertinoIcons.check_mark_circled,
            onPressed: actionsDisabled || proposals.isEmpty || noteId == null
                ? null
                : () => _enterProposalBatchMode(noteId),
          ),
        ],
      );
    }
    final allSelected =
        proposals.isNotEmpty && selectedProposalIds.length == proposals.length;
    return Row(
      children: [
        Text(
          '已选 ${selectedProposalIds.length}/${proposals.length} 条',
          style: const TextStyle(
            color: workspaceMutedColor,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        CupertinoButton(
          key: const Key('proposal-select-all-button'),
          minimumSize: const Size(34, 34),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          onPressed: actionsDisabled
              ? null
              : () => _toggleAllProposals(proposals, allSelected),
          child: Text(allSelected ? '取消全选' : '全选'),
        ),
        IconAction(
          key: const Key('delete-selected-proposals-button'),
          label: '删除已选 AI 建议',
          icon: CupertinoIcons.trash,
          onPressed:
              actionsDisabled ||
                  selectedProposalIds.isEmpty ||
                  editorContext == null
              ? null
              : () => _deleteSelectedProposals(
                  editorContext,
                  proposals,
                  selectedProposalIds,
                ),
        ),
        IconAction(
          key: const Key('exit-proposal-batch-mode-button'),
          label: '退出批量管理',
          icon: CupertinoIcons.xmark,
          onPressed: _exitProposalBatchMode,
        ),
      ],
    );
  }

  double _resolvedSourcesHeight(double availableHeight) {
    final maximum = math.max(
      _minimumCompactSourcesHeight,
      availableHeight - _reservedProposalAreaHeight,
    );
    final minimum = math.min(_preferredMinimumSourcesHeight, maximum);
    return (availableHeight * _sourcesAreaFraction)
        .clamp(minimum, maximum)
        .toDouble();
  }

  void _resizeSourcesArea(double delta, double availableHeight) {
    if (availableHeight <= 0) {
      return;
    }
    final maximum = math.max(
      _minimumCompactSourcesHeight,
      availableHeight - _reservedProposalAreaHeight,
    );
    final minimum = math.min(_preferredMinimumSourcesHeight, maximum);
    final nextHeight = (_resolvedSourcesHeight(availableHeight) + delta)
        .clamp(minimum, maximum)
        .toDouble();
    setState(() => _sourcesAreaFraction = nextHeight / availableHeight);
  }

  Widget _buildExpandedSources({
    required double height,
    required List<AiMaterial> sources,
    required NoteMaterialsSnapshot materials,
    required PaneEditorContext? editorContext,
    required bool busy,
  }) {
    if (sources.isEmpty) {
      return SizedBox(
        key: Key('sources-expanded-content'),
        height: height,
        child: const EmptyState(text: '暂无 AI 素材'),
      );
    }
    return SizedBox(
      key: const Key('sources-expanded-content'),
      height: height,
      child: GridView.builder(
        padding: EdgeInsets.zero,
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
            selected: materials.selectedAiMaterialIds.contains(source.id),
            busy: busy,
            imageBytes: source.mediaKind == MediaKind.image
                ? widget.controller.readAiMaterialContent(source)
                : null,
            onToggle: () {
              final target = editorContext == null
                  ? null
                  : widget.controller.resolvePaneEditorContext(editorContext);
              if (target != null) {
                widget.controller.toggleAiMaterialSelection(
                  target.noteId,
                  source.id,
                );
              }
            },
            onDelete: editorContext == null
                ? () {}
                : () async {
                    await widget.onDeleteSource(editorContext, source);
                  },
          );
        },
      ),
    );
  }

  Widget _buildSelectedSourcesSummary({
    required List<AiMaterial> sources,
    required Set<String> selectedSourceIds,
  }) {
    final selected = sources
        .where((source) => selectedSourceIds.contains(source.id))
        .toList(growable: false);
    return Container(
      key: const Key('sources-collapsed-summary'),
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: workspaceSurfaceColor,
        border: Border.all(color: workspaceSoftLineColor),
        borderRadius: workspaceBorderRadius,
      ),
      child: Row(
        children: [
          if (selected.isEmpty)
            const Expanded(
              child: Text(
                '未选择 AI 素材',
                style: TextStyle(color: workspaceMutedColor),
              ),
            )
          else ...[
            for (final source in selected.take(4)) ...[
              _SourceSummaryThumbnail(
                source: source,
                imageBytes: source.mediaKind == MediaKind.image
                    ? widget.controller.readAiMaterialContent(source)
                    : null,
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                selected.length > 4
                    ? '另有 ${selected.length - 4} 项'
                    : '已选 ${selected.length} 项',
                textAlign: TextAlign.end,
                style: const TextStyle(color: workspaceMutedColor),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAttachmentsTab({
    required List<NoteAttachment> attachments,
    required PaneEditorContext? editorContext,
    required String currentMarkdown,
    required bool busy,
  }) {
    final resolved = editorContext == null
        ? null
        : widget.controller.resolvePaneEditorContext(editorContext);
    final note = resolved?.session.note;
    return Column(
      key: const Key('right-pane-attachments-content'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('笔记附件', style: workspaceRightPaneTitleStyle),
            const SizedBox(width: 4),
            Text(
              '· ${attachments.length}',
              style: const TextStyle(color: workspaceMutedColor, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: attachments.isEmpty
              ? const EmptyState(text: '暂无笔记附件')
              : GridView.builder(
                  key: const Key('note-attachments-grid'),
                  controller: _attachmentScrollController,
                  padding: EdgeInsets.zero,
                  itemCount: attachments.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.15,
                  ),
                  itemBuilder: (context, index) {
                    final attachment = attachments[index];
                    final referenceCount = note == null
                        ? 0
                        : _attachmentReferenceCount(
                            markdown: currentMarkdown,
                            note: note,
                            attachment: attachment,
                          );
                    return AttachmentTile(
                      attachment: attachment,
                      referenceCount: referenceCount,
                      busy: busy,
                      loadImageBytes: () =>
                          widget.controller.readNoteAttachment(attachment),
                      onDelete: editorContext == null
                          ? () {}
                          : () async {
                              await widget.onDeleteAttachments(editorContext, [
                                attachment,
                              ]);
                            },
                    );
                  },
                ),
        ),
      ],
    );
  }

  int _attachmentReferenceCount({
    required String markdown,
    required VaultNote note,
    required NoteAttachment attachment,
  }) {
    final assetsDirectory = '${p.basenameWithoutExtension(note.path)}.assets';
    final src = '$assetsDirectory/${attachment.relativePath}'.replaceAll(
      '\\',
      '/',
    );
    var count = 0;
    var start = 0;
    while (start < markdown.length) {
      final reference = findMarkdownImageReference(
        markdown: markdown,
        src: src,
        start: start,
      );
      if (reference == null) {
        break;
      }
      count += 1;
      start = reference.end;
    }
    return count;
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

  Future<void> _deleteSelectedSources(
    PaneEditorContext? editorContext,
    List<AiMaterial> sources,
    Set<String> selectedSourceIds,
  ) async {
    if (editorContext == null) {
      return;
    }
    final selected = sources
        .where((source) => selectedSourceIds.contains(source.id))
        .toList(growable: false);
    if (selected.isEmpty) {
      return;
    }
    await widget.onDeleteSources(editorContext, selected);
  }

  void _enterProposalBatchMode(String noteId) {
    setState(() {
      _proposalBatchNoteId = noteId;
      _selectedProposalIds.clear();
    });
  }

  void _exitProposalBatchMode() {
    setState(() {
      _proposalBatchNoteId = null;
      _selectedProposalIds.clear();
    });
  }

  void _toggleProposalSelected(String proposalId) {
    setState(() {
      if (!_selectedProposalIds.add(proposalId)) {
        _selectedProposalIds.remove(proposalId);
      }
    });
  }

  void _toggleAllProposals(List<AiProposal> proposals, bool allSelected) {
    setState(() {
      _selectedProposalIds.clear();
      if (!allSelected) {
        _selectedProposalIds.addAll(proposals.map((proposal) => proposal.id));
      }
    });
  }

  Future<void> _deleteSelectedProposals(
    PaneEditorContext editorContext,
    List<AiProposal> proposals,
    Set<String> selectedProposalIds,
  ) async {
    final selected = proposals
        .where((proposal) => selectedProposalIds.contains(proposal.id))
        .toList(growable: false);
    if (selected.isEmpty) {
      return;
    }
    final outcome = await widget.onDeleteProposals(editorContext, selected);
    if (mounted && outcome == PaneEditorCommandOutcome.committed) {
      _exitProposalBatchMode();
    }
  }

  Future<void> _importImage(
    PaneEditorContext? editorContext,
    String? noteId,
  ) async {
    final outcome = await widget.controller.importImage(editorContext);
    if (mounted &&
        noteId != null &&
        outcome == PaneEditorCommandOutcome.committed) {
      _setSourcesExpanded(noteId, true);
    }
  }

  Future<void> _pasteImage(
    PaneEditorContext? editorContext,
    String? noteId,
  ) async {
    final outcome = await widget.controller.pasteImage(editorContext);
    if (mounted &&
        noteId != null &&
        outcome == PaneEditorCommandOutcome.committed) {
      _setSourcesExpanded(noteId, true);
    }
  }

  void _setSourcesExpanded(String noteId, bool expanded) {
    if (_sourcesExpandedByNote[noteId] == expanded) {
      return;
    }
    setState(() => _sourcesExpandedByNote[noteId] = expanded);
  }

  void _setExpandedProposal(String noteId, String proposalId) {
    if (_expandedProposalByNote[noteId] == proposalId) {
      return;
    }
    setState(() => _expandedProposalByNote[noteId] = proposalId);
  }

  Future<void> _generateProposal() async {
    final editorContext = _captureFocusedEditorContext();
    final noteId = editorContext == null
        ? null
        : widget.controller.resolvePaneEditorContext(editorContext)?.noteId;
    final unavailableMessage = widget.controller
        .proposalGenerationUnavailableMessage(editorContext);
    if (unavailableMessage != null) {
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('无法生成 AI 建议'),
          content: Text(unavailableMessage),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    setState(() => _generatingProposal = true);
    try {
      final outcome = await widget.controller.generateProposal(editorContext);
      if (mounted &&
          noteId != null &&
          outcome == PaneEditorCommandOutcome.committed) {
        setState(() {
          _sourcesExpandedByNote[noteId] = false;
          _expandedProposalByNote.remove(noteId);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _focusedNoteId(widget.workspace) == noteId &&
              _proposalScrollController.hasClients) {
            _proposalScrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() => _generatingProposal = false);
      }
    }
  }

  Future<void> _confirmAndApplyProposal(
    PaneEditorContext editorContext,
    AiProposal proposal,
  ) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('追加到当前笔记？'),
        content: Text('将把“${proposal.title}”的内容原样追加到笔记末尾。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            key: const Key('confirm-apply-proposal-button'),
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('追加'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await widget.controller.applyProposal(editorContext, proposal);
    }
  }

  KeyEventResult _handleKeyEvent(
    FocusNode node,
    KeyEvent event,
    PaneEditorContext? editorContext,
  ) {
    if (widget.workspace.rightTab != WorkspaceRightTab.ai ||
        !node.hasPrimaryFocus ||
        !_isPasteImageShortcutKeyUp(event)) {
      return KeyEventResult.ignored;
    }
    if (!widget.workspace.isBusy &&
        !widget.workspace.reloadRequired &&
        widget.workspace.hasVault) {
      unawaited(
        _pasteImage(
          editorContext,
          editorContext == null
              ? null
              : widget.controller
                    .resolvePaneEditorContext(editorContext)
                    ?.noteId,
        ),
      );
    }
    return KeyEventResult.handled;
  }
}

final class _SourceResizeHandle extends StatefulWidget {
  const _SourceResizeHandle({
    super.key,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  State<_SourceResizeHandle> createState() => _SourceResizeHandleState();
}

final class _SourceResizeHandleState extends State<_SourceResizeHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '调整图片区域高度',
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) => widget.onDragStart(),
          onVerticalDragUpdate: (details) =>
              widget.onDragUpdate(details.delta.dy),
          onVerticalDragEnd: (_) => widget.onDragEnd(),
          onVerticalDragCancel: widget.onDragEnd,
          child: SizedBox(
            height: 12,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Positioned(left: 0, right: 0, child: Hairline()),
                AnimatedContainer(
                  key: const Key('sources-resize-grip'),
                  duration: const Duration(milliseconds: 120),
                  width: _hovered ? 40 : 28,
                  height: _hovered ? 3 : 2,
                  decoration: BoxDecoration(
                    color: _hovered ? workspaceMutedColor : workspaceLineColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String? _focusedNoteId(WorkspaceState workspace) =>
    _findSplitLeaf(workspace.splitRoot, workspace.focusedPaneId)?.noteId;

final class _SourceSummaryThumbnail extends StatefulWidget {
  const _SourceSummaryThumbnail({
    required this.source,
    required this.imageBytes,
  });

  final AiMaterial source;
  final Future<List<int>>? imageBytes;

  @override
  State<_SourceSummaryThumbnail> createState() =>
      _SourceSummaryThumbnailState();
}

final class _SourceSummaryThumbnailState
    extends State<_SourceSummaryThumbnail> {
  Future<List<int>>? _imageBytes;

  @override
  void initState() {
    super.initState();
    _imageBytes = widget.imageBytes;
  }

  @override
  void didUpdateWidget(covariant _SourceSummaryThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.id != widget.source.id) {
      _imageBytes = widget.imageBytes;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox.square(
        dimension: 40,
        child: ColoredBox(
          color: workspaceSecondarySurfaceColor,
          child:
              widget.source.mediaKind == MediaKind.image && _imageBytes != null
              ? FutureBuilder<List<int>>(
                  future: _imageBytes,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(
                        child: CupertinoActivityIndicator(radius: 7),
                      );
                    }
                    if (snapshot.hasError || !snapshot.hasData) {
                      return const Icon(
                        CupertinoIcons.exclamationmark_triangle,
                        size: 16,
                        color: workspaceDangerColor,
                      );
                    }
                    return Image.memory(
                      Uint8List.fromList(snapshot.data!),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    );
                  },
                )
              : Icon(
                  widget.source.mediaKind == MediaKind.audio
                      ? CupertinoIcons.waveform
                      : CupertinoIcons.doc_text,
                  size: 18,
                  color: workspaceMutedColor,
                ),
        ),
      ),
    );
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
