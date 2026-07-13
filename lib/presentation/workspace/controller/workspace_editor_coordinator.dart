import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../domain/markdown/markdown_document.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/input/image_input_service.dart';
import '../../../infrastructure/vault/vault_post_commit_error.dart';
import '../editor/live_markdown_editor.dart';
import '../editor/markdown_image_transform.dart';
import '../editor/pane_editor_context.dart';
import '../state/note_document_session.dart';
import '../state/note_materials_registry.dart';
import '../state/note_save_coordinator.dart';
import '../state/note_session_registry.dart';
import '../state/split_workspace_controller.dart';
import '../state/workspace_mutation_barrier.dart';
import 'workspace_runtime_manager.dart';
import 'workspace_state.dart';
import 'workspace_state_commit_coordinator.dart';

final class WorkspaceEditorCoordinator {
  WorkspaceEditorCoordinator({
    required ImageInputService imageInput,
    required WorkspaceRuntimeManager runtimes,
    required WorkspaceMutationBarrier mutations,
    required WorkspaceStateCommitCoordinator commits,
    required NoteSessionRegistry sessions,
    required NoteMaterialsRegistry materials,
    required NoteSaveCoordinator saves,
    required SplitWorkspaceController splits,
    required WorkspaceState Function() readState,
  }) : _imageInput = imageInput,
       _runtimes = runtimes,
       _mutations = mutations,
       _commits = commits,
       _sessions = sessions,
       _materials = materials,
       _saves = saves,
       _splits = splits,
       _readState = readState;

  final ImageInputService _imageInput;
  final WorkspaceRuntimeManager _runtimes;
  final WorkspaceMutationBarrier _mutations;
  final WorkspaceStateCommitCoordinator _commits;
  final NoteSessionRegistry _sessions;
  final NoteMaterialsRegistry _materials;
  final NoteSaveCoordinator _saves;
  final SplitWorkspaceController _splits;
  final WorkspaceState Function() _readState;

  Future<PaneEditorCommandOutcome> importImage(PaneEditorContext context) =>
      _importImage(
        context,
        acquireImage: _imageInput.pickImage,
        successMessage: (image) => '图片已导入：${image.filename}',
      );

  Future<PaneEditorCommandOutcome> pasteImage(PaneEditorContext context) =>
      _importImage(
        context,
        acquireImage: _imageInput.pasteImage,
        successMessage: (image) => '剪贴板图片已导入：${image.filename}',
      );

  Future<PaneEditorCommandOutcome> _importImage(
    PaneEditorContext context, {
    required Future<ImportedImage?> Function() acquireImage,
    required String Function(ImportedImage image) successMessage,
  }) async {
    var resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final flush = await _saves.flush([resolved.session]);
    if (!flush.succeeded) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final image = await acquireImage();
    resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (image == null) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final targetSession = resolved.session;
    final vault = _runtimes.requireCurrent().vault;
    final result = await _mutations.run<_SourceHydration>(
      WorkspaceMutationPlan<_SourceHydration>(
        affectedNoteIds: {targetSession.noteId},
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          final noteId = targetSession.noteId;
          final source = await vault.addImageSource(
            noteId: noteId,
            filename: image.filename,
            mimeType: image.mimeType,
            bytes: image.bytes,
          );
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final note = await vault.readNote(noteId);
              return VaultMutationDelta(
                value: _SourceHydration(note: note, source: source),
                refreshedNotesByNewId: {note.id: note},
                resources: await vault.listResources(),
              );
            },
          );
        },
        prepareCommit: (delta) {
          final note = delta.value.note;
          final selected = Set<String>.of(
            _materials.snapshotFor(note.id).selectedSourceIds,
          )..add(delta.value.source.id);
          final focused = _splits.focusedPaneId == context.paneId;
          return _commits.prepare(
            delta,
            upsertedNotesById: {note.id: note},
            selectedSourceIdsByNoteId: {note.id: selected},
            patch: WorkspaceStatePatch(
              resources: delta.resources,
              selectedResourceId: focused
                  ? note.id
                  : _readState().selectedResourceId,
              narrowSection: focused ? WorkspaceSection.sources : null,
              message: successMessage(image),
            ),
          );
        },
      ),
    );
    return _editorResult(result, context);
  }

  Future<NoteEditorPasteAvailability> pasteAvailability(
    PaneEditorContext context,
  ) async {
    if (_resolve(context) == null) {
      return NoteEditorPasteAvailability.empty;
    }
    final results = await Future.wait<bool>([
      Clipboard.hasStrings(),
      _imageInput.canPasteImage(),
    ]);
    if (_resolve(context) == null) {
      return NoteEditorPasteAvailability.empty;
    }
    return NoteEditorPasteAvailability(
      hasText: results[0],
      hasImage: results[1],
    );
  }

  Future<PaneEditorCommandOutcome> pasteIntoNote(
    PaneEditorContext context,
  ) async {
    if (_resolve(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final image = await _imageInput.pasteImage();
    if (_resolve(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (image != null) {
      return _insertPastedImage(context: context, image: image);
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    final resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (text == null || text.isEmpty) {
      return PaneEditorCommandOutcome.unchanged;
    }
    _replaceEditorSelection(resolved.session, text);
    return PaneEditorCommandOutcome.committed;
  }

  Future<PaneEditorCommandOutcome> _insertPastedImage({
    required PaneEditorContext context,
    required ImportedImage image,
  }) async {
    final resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final filename = _noteEditorPastedImageFilename(image.filename);
    final targetSession = resolved.session;
    final vault = _runtimes.requireCurrent().vault;
    final result = await _mutations.run<_SourceHydration>(
      WorkspaceMutationPlan<_SourceHydration>(
        affectedNoteIds: {targetSession.noteId},
        dirtyDisposition: DirtyDisposition.discard,
        commitBackend: () async {
          final oldNoteId = targetSession.noteId;
          final source = await vault.addImageSource(
            noteId: oldNoteId,
            filename: filename,
            mimeType: image.mimeType,
            bytes: image.bytes,
          );
          final value = targetSession.controller.value;
          final selection = _normalizedSelection(value);
          final replacement = blockImageInsertion(
            text: value.text,
            start: selection.start,
            end: selection.end,
            tag: _imageMarkdownTag(targetSession.note, source),
          );
          final updatedBody = value.text.replaceRange(
            selection.start,
            selection.end,
            replacement,
          );
          final saved = await runVaultPostCommit(
            () => vault.updateMarkdown(
              noteId: oldNoteId,
              markdown: _markdownForVisibleBody(
                targetSession.note,
                updatedBody,
              ),
            ),
          );
          var committedNoteId = oldNoteId;
          if (saved.title != targetSession.note.title) {
            final renamed = await runVaultPostCommit(
              () => vault.renameNote(noteId: oldNoteId, title: saved.title),
            );
            committedNoteId = renamed.id;
          }
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final note = await vault.readNote(committedNoteId);
              return VaultMutationDelta(
                value: _SourceHydration(note: note, source: source),
                remappedNoteIds: {oldNoteId: note.id},
                refreshedNotesByNewId: {note.id: note},
                resources: await vault.listResources(),
              );
            },
          );
        },
        prepareCommit: (delta) {
          final sessionStillOwned = noteSessionRegistryOwnsSession(
            sessions: _sessions,
            sessionIdentity: targetSession,
            noteIds: {
              targetSession.noteId,
              ...delta.remappedNoteIds.keys,
              ...delta.remappedNoteIds.values,
            },
          );
          final resources = delta.resources ?? const <VaultResourceNode>[];
          if (!sessionStillOwned || _resolve(context) == null) {
            return _commits.prepare(
              delta,
              patch: WorkspaceStatePatch(
                resources: resources,
                searchResults: const [],
              ),
            );
          }
          final note = delta.value.note;
          final selected = Set<String>.of(
            _materials.snapshotFor(note.id).selectedSourceIds,
          )..add(delta.value.source.id);
          final focused = _splits.focusedPaneId == context.paneId;
          return _commits.prepare(
            delta,
            savedNoteCommit: SavedNoteSessionCommit(
              session: targetSession,
              oldNoteId: delta.remappedNoteIds.keys.single,
              savedNote: note,
              preserveCurrentBody: false,
            ),
            selectedSourceIdsByNoteId: {note.id: selected},
            patch: WorkspaceStatePatch(
              resources: resources,
              selectedResourceId: focused
                  ? note.id
                  : _readState().selectedResourceId,
              searchResults: const [],
              message: '图片已粘贴到笔记：$filename',
              selectedPreviewImageSrc: focused
                  ? _markdownAttachmentSrc(note, delta.value.source)
                  : _readState().selectedPreviewImageSrc,
            ),
          );
        },
      ),
    );
    return _editorResult(result, context);
  }

  Future<PaneEditorCommandOutcome> generateProposal(
    PaneEditorContext context,
  ) async {
    var resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final sourceIds = _materials
        .snapshotFor(resolved.noteId)
        .selectedSourceIds
        .toList(growable: false);
    if (sourceIds.isEmpty) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final flush = await _saves.flush([resolved.session]);
    if (!flush.succeeded) {
      return PaneEditorCommandOutcome.unchanged;
    }
    resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final runtime = _runtimes.requireCurrent();
    final preparedSession = resolved.session;
    final prepared = await runtime.proposalService.prepareOutlineProposal(
      noteId: resolved.noteId,
      sourceIds: sourceIds,
    );
    resolved = _resolve(context);
    if (resolved == null) {
      final sessionIsStillOwned = identical(
        _sessions.sessionFor(preparedSession.noteId),
        preparedSession,
      );
      await _mutations.run<void>(
        WorkspaceMutationPlan<void>(
          affectedNoteIds: sessionIsStillOwned
              ? {preparedSession.noteId}
              : const {},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () async {
            await runtime.proposalService.commitPreparedOutlineProposal(
              prepared,
            );
            return WorkspaceBackendCommit.completed(
              const VaultMutationDelta<void>(value: null),
            );
          },
        ),
      );
      return PaneEditorCommandOutcome.staleTarget;
    }
    final targetSession = resolved.session;
    final result = await _mutations.run<_NoteHydration>(
      WorkspaceMutationPlan<_NoteHydration>(
        affectedNoteIds: {targetSession.noteId},
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          final commitTarget = _resolve(context);
          if (commitTarget == null ||
              !identical(commitTarget.session, targetSession)) {
            throw StateError('Proposal target became stale before commit.');
          }
          final noteId = targetSession.noteId;
          await runtime.proposalService.commitPreparedOutlineProposal(prepared);
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final note = await runtime.vault.readNote(noteId);
              return VaultMutationDelta(
                value: _NoteHydration(
                  note: note,
                  proposals: await runtime.vault.listProposals(noteId),
                ),
                refreshedNotesByNewId: {note.id: note},
                resources: await runtime.vault.listResources(),
              );
            },
          );
        },
        prepareCommit: (delta) {
          if (_resolve(context) == null) {
            return _commits.prepare(delta);
          }
          final note = delta.value.note;
          final focused = _splits.focusedPaneId == context.paneId;
          return _commits.prepare(
            delta,
            upsertedNotesById: {note.id: note},
            replacementProposalsByNoteId: {note.id: delta.value.proposals},
            patch: WorkspaceStatePatch(
              resources: delta.resources,
              selectedResourceId: focused
                  ? note.id
                  : _readState().selectedResourceId,
            ),
          );
        },
      ),
    );
    return _editorResult(result, context);
  }

  Future<PaneEditorCommandOutcome> deleteProposal(
    PaneEditorContext context,
    AiProposal proposal,
  ) async {
    final resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final targetSession = resolved.session;
    final vault = _runtimes.requireCurrent().vault;
    final result = await _mutations.run<_NoteHydration>(
      WorkspaceMutationPlan<_NoteHydration>(
        affectedNoteIds: {targetSession.noteId},
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          final noteId = targetSession.noteId;
          await vault.deleteProposal(proposal.id);
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final note = await vault.readNote(noteId);
              return VaultMutationDelta(
                value: _NoteHydration(
                  note: note,
                  proposals: await vault.listProposals(noteId),
                ),
                refreshedNotesByNewId: {note.id: note},
              );
            },
          );
        },
        prepareCommit: (delta) => _commits.prepare(
          delta,
          upsertedNotesById: {delta.value.note.id: delta.value.note},
          replacementProposalsByNoteId: {
            delta.value.note.id: delta.value.proposals,
          },
          patch: const WorkspaceStatePatch(message: 'AI 建议已删除'),
        ),
      ),
    );
    return _editorResult(result, context);
  }

  Future<PaneEditorCommandOutcome> saveSession(
    PaneEditorContext context,
    NoteDocumentSession session, {
    required bool automatic,
    required bool rescheduleIfDirty,
    String? successMessage,
  }) async {
    final resolved = _resolve(context);
    if (resolved == null || !identical(resolved.session, session)) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final result = await _saves.save(
      session,
      reason: automatic ? NoteSaveReason.debounce : NoteSaveReason.explicit,
      rescheduleIfStillDirty: rescheduleIfDirty,
      successMessage: successMessage,
    );
    if (_resolve(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    return result.succeeded
        ? PaneEditorCommandOutcome.committed
        : PaneEditorCommandOutcome.unchanged;
  }

  Future<PaneEditorCommandOutcome> deleteSource(
    PaneEditorContext context,
    SourceItem source,
  ) async {
    final resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final targetSession = resolved.session;
    final vault = _runtimes.requireCurrent().vault;
    final result = await _mutations.run<_NoteHydration>(
      WorkspaceMutationPlan<_NoteHydration>(
        affectedNoteIds: {targetSession.noteId},
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          final currentSource = targetSession.note.sources
              .where((candidate) => candidate.id == source.id)
              .firstOrNull;
          if (currentSource == null) {
            throw StateError('Source not found: ${source.id}');
          }
          await vault.deleteSource(currentSource);
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final note = await vault.readNote(targetSession.noteId);
              final proposals = await vault.listProposals(note.id);
              return VaultMutationDelta(
                value: _NoteHydration(note: note, proposals: proposals),
                refreshedNotesByNewId: {note.id: note},
                resources: await vault.listResources(),
              );
            },
          );
        },
        prepareCommit: (delta) {
          final note = delta.value.note;
          final selected = Set<String>.of(
            _materials.snapshotFor(note.id).selectedSourceIds,
          )..remove(source.id);
          return _commits.prepare(
            delta,
            upsertedNotesById: {note.id: note},
            replacementProposalsByNoteId: {note.id: delta.value.proposals},
            selectedSourceIdsByNoteId: {note.id: selected},
            patch: WorkspaceStatePatch(
              resources: delta.resources,
              message: '素材已删除',
              selectedPreviewImageSrc: null,
            ),
          );
        },
      ),
    );
    return _editorResult(result, context);
  }

  Future<PaneEditorCommandOutcome> copyProposal(
    PaneEditorContext context,
    AiProposal proposal,
  ) async {
    if (_resolve(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    await Clipboard.setData(
      ClipboardData(
        text: proposal.proposedMarkdown
            .replaceAll('\r\n', '\n')
            .replaceAll('\r', '\n'),
      ),
    );
    return _resolve(context) == null
        ? PaneEditorCommandOutcome.staleTarget
        : PaneEditorCommandOutcome.committed;
  }

  Future<List<int>> readSourceAttachment(SourceItem source) {
    return _runtimes.requireCurrent().vault.readSourceAttachment(source);
  }

  String _imageMarkdownTag(VaultNoteContent note, SourceItem source) {
    final src = _markdownAttachmentSrc(note, source);
    return '<img src="${escapeHtmlAttribute(src)}" '
        'width="${_readState().preferences.pastedImageWidth}">';
  }

  String _noteEditorPastedImageFilename(String filename) {
    final extension = p.extension(filename).isEmpty
        ? '.png'
        : p.extension(filename);
    final base = p.basenameWithoutExtension(filename);
    final match = RegExp(r'^clipboard-(\d+)(?:-.+)?$').firstMatch(base);
    return match == null ? filename : '${match.group(1)}$extension';
  }

  String _markdownAttachmentSrc(VaultNote note, SourceItem source) {
    final attachmentPath = source.attachmentPath;
    if (attachmentPath == null || attachmentPath.trim().isEmpty) {
      throw StateError('Source has no attachment: ${source.id}');
    }
    final assetsDirectory = '${p.basenameWithoutExtension(note.path)}.assets';
    return '$assetsDirectory/$attachmentPath'.replaceAll('\\', '/');
  }

  void _replaceEditorSelection(
    NoteDocumentSession session,
    String replacement,
  ) {
    final controller = session.controller;
    final value = controller.value;
    final selection = _normalizedSelection(value);
    controller.value = value.copyWith(
      text: value.text.replaceRange(
        selection.start,
        selection.end,
        replacement,
      ),
      selection: TextSelection.collapsed(
        offset: selection.start + replacement.length,
      ),
      composing: TextRange.empty,
    );
  }

  TextSelection _normalizedSelection(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid) {
      return TextSelection.collapsed(offset: value.text.length);
    }
    return TextSelection(
      baseOffset: selection.start.clamp(0, value.text.length).toInt(),
      extentOffset: selection.end.clamp(0, value.text.length).toInt(),
    );
  }

  String _markdownForVisibleBody(VaultNoteContent note, String body) {
    return MarkdownDocument.parse(
      note.markdown,
    ).copyWithSyncedBody(body, updatedAt: DateTime.now().toUtc()).toMarkdown();
  }

  ResolvedPaneEditorContext? _resolve(PaneEditorContext context) {
    return resolvePaneEditorContext(
      context,
      splits: _splits,
      sessions: _sessions,
      runtimeGeneration: _runtimes.generation,
    );
  }

  PaneEditorCommandOutcome _editorResult<T>(
    WorkspaceMutationResult<T> result,
    PaneEditorContext context,
  ) {
    switch (result) {
      case Committed<T>():
        return _resolve(context) == null
            ? PaneEditorCommandOutcome.staleTarget
            : PaneEditorCommandOutcome.committed;
      case AbortedByFlush<T>():
        return PaneEditorCommandOutcome.unchanged;
      case BackendFailed<T>(:final error, :final stackTrace):
        Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

final class _SourceHydration {
  const _SourceHydration({required this.note, required this.source});

  final VaultNoteContent note;
  final SourceItem source;
}

final class _NoteHydration {
  const _NoteHydration({required this.note, required this.proposals});

  final VaultNoteContent note;
  final List<AiProposal> proposals;
}
