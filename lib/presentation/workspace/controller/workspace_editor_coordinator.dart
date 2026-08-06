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
    final result = await _mutations.run<_MaterialHydration>(
      WorkspaceMutationPlan<_MaterialHydration>(
        affectedNoteIds: {targetSession.noteId},
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          _requireCurrentMutationTarget(context, targetSession);
          final noteId = targetSession.noteId;
          final material = await vault.addImageMaterial(
            noteId: noteId,
            filename: image.filename,
            mimeType: image.mimeType,
            bytes: image.bytes,
          );
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final note = await vault.readNote(noteId);
              return VaultMutationDelta(
                value: _MaterialHydration(note: note, material: material),
                refreshedNotesByNewId: {note.id: note},
                resources: await vault.listResources(),
              );
            },
          );
        },
        prepareCommit: (delta) {
          final note = delta.value.note;
          final selected = Set<String>.of(
            _materials.snapshotFor(note.id).selectedAiMaterialIds,
          )..add(delta.value.material.id);
          final focused = _splits.focusedPaneId == context.paneId;
          return _commits.prepare(
            delta,
            upsertedNotesById: {note.id: note},
            selectedAiMaterialIdsByNoteId: {note.id: selected},
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
    TextEditingValue target, {
    bool lineInsertion = false,
  }) async {
    if (_resolvePasteTarget(context, target) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final image = await _imageInput.pasteImage();
    if (_resolvePasteTarget(context, target) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (image != null) {
      return _insertPastedImage(context: context, image: image, target: target);
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    final resolved = _resolvePasteTarget(context, target);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (text == null || text.isEmpty) {
      return PaneEditorCommandOutcome.unchanged;
    }
    _replaceEditorSelection(
      resolved.session,
      text,
      target: target,
      lineInsertion: lineInsertion,
    );
    return PaneEditorCommandOutcome.committed;
  }

  Future<PaneEditorCommandOutcome> pasteImportedImage(
    PaneEditorContext context,
    ImportedImage image,
    TextEditingValue target,
  ) {
    if (_resolvePasteTarget(context, target) == null) {
      return Future<PaneEditorCommandOutcome>.value(
        PaneEditorCommandOutcome.staleTarget,
      );
    }
    return _insertPastedImage(context: context, image: image, target: target);
  }

  Future<PaneEditorCommandOutcome> copyImage(
    PaneEditorContext context,
    String attachmentId,
  ) async {
    var resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final attachment = _imageAttachmentForId(resolved.session, attachmentId);
    if (attachment == null) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final bytes = await readNoteAttachment(attachment);
    resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final currentAttachment = _imageAttachmentForId(
      resolved.session,
      attachmentId,
    );
    if (currentAttachment == null ||
        !_sameImageAttachment(attachment, currentAttachment)) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    await _imageInput.writeClipboardImage(bytes);
    return _resolve(context) == null
        ? PaneEditorCommandOutcome.staleTarget
        : PaneEditorCommandOutcome.committed;
  }

  Future<PaneEditorCommandOutcome> _insertPastedImage({
    required PaneEditorContext context,
    required ImportedImage image,
    required TextEditingValue target,
  }) async {
    final resolved = _resolvePasteTarget(context, target);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final filename = _noteEditorPastedImageFilename(image.filename);
    final targetSession = resolved.session;
    final vault = _runtimes.requireCurrent().vault;
    final result = await _mutations.run<_AttachmentHydration>(
      WorkspaceMutationPlan<_AttachmentHydration>(
        affectedNoteIds: {targetSession.noteId},
        dirtyDisposition: DirtyDisposition.discard,
        commitBackend: () async {
          _requireCurrentPasteMutationTarget(context, targetSession, target);
          final oldNoteId = targetSession.noteId;
          late NoteAttachment attachment;
          var committedNoteId = oldNoteId;
          try {
            await vault.runMutationTransaction<void>(
              label: 'paste-image-into-note',
              action: () async {
                attachment = await vault.addImageAttachment(
                  noteId: oldNoteId,
                  filename: filename,
                  mimeType: image.mimeType,
                  bytes: image.bytes,
                );
                _requireUnchangedPasteTextAfterBackend(
                  targetSession,
                  target,
                  noteIds: {oldNoteId},
                );
                final selection = _normalizedSelection(target);
                final imageTag = _imageMarkdownTag(
                  targetSession.note,
                  attachment,
                );
                final replacement = blockImageInsertion(
                  text: target.text,
                  start: selection.start,
                  end: selection.end,
                  tag: imageTag,
                );
                final updatedBody = target.text.replaceRange(
                  selection.start,
                  selection.end,
                  replacement,
                );
                final saved = await vault.updateMarkdown(
                  noteId: oldNoteId,
                  markdown: _markdownForVisibleBody(
                    targetSession.note,
                    updatedBody,
                  ),
                );
                _requireUnchangedPasteTextAfterBackend(
                  targetSession,
                  target,
                  noteIds: {oldNoteId, saved.id},
                );
                if (saved.title != targetSession.note.title) {
                  final renamed = await vault.renameNote(
                    noteId: oldNoteId,
                    title: saved.title,
                  );
                  committedNoteId = renamed.id;
                  _requireUnchangedPasteTextAfterBackend(
                    targetSession,
                    target,
                    noteIds: {oldNoteId, committedNoteId},
                  );
                }
              },
            );
          } on VaultPostCommitError catch (error) {
            Error.throwWithStackTrace(error.cause, error.causeStackTrace);
          }
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final note = await vault.readNote(committedNoteId);
              return VaultMutationDelta(
                value: _AttachmentHydration(note: note, attachment: attachment),
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
          if (sessionStillOwned &&
              targetSession.controller.text != target.text) {
            throw const _PasteTargetChangedAfterBackend();
          }
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
          final focused = _splits.focusedPaneId == context.paneId;
          return _commits.prepare(
            delta,
            savedNoteCommit: SavedNoteSessionCommit(
              session: targetSession,
              oldNoteId: delta.remappedNoteIds.keys.single,
              savedNote: note,
              preserveCurrentBody: false,
            ),
            patch: WorkspaceStatePatch(
              resources: resources,
              selectedResourceId: focused
                  ? note.id
                  : _readState().selectedResourceId,
              searchResults: const [],
              message: '图片已粘贴到笔记：$filename',
              selectedPreviewImageSrc: focused
                  ? _markdownAttachmentSrc(note, delta.value.attachment)
                  : _readState().selectedPreviewImageSrc,
            ),
          );
        },
      ),
    );
    final outcome = _editorResult(result, context);
    final current = _resolve(context);
    if (outcome == PaneEditorCommandOutcome.committed &&
        result is Committed<_AttachmentHydration> &&
        current != null &&
        identical(current.session, targetSession)) {
      final body = current.session.controller.text;
      final reference = findMarkdownImageReference(
        markdown: body,
        src: _markdownAttachmentSrc(result.value.note, result.value.attachment),
      );
      if (reference != null) {
        current.session.setSelectionProgrammatically(
          TextSelection.collapsed(
            offset: _caretOffsetAfterImageReference(body, reference),
          ),
        );
      }
    }
    return outcome;
  }

  Future<PaneEditorCommandOutcome> generateProposal(
    PaneEditorContext context,
  ) async {
    var resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final materialIds = _materials
        .snapshotFor(resolved.noteId)
        .selectedAiMaterialIds
        .toList(growable: false);
    if (materialIds.isEmpty) {
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
      materialIds: materialIds,
    );
    resolved = _resolve(context);
    if (resolved == null) {
      if (context.runtimeGeneration != _runtimes.generation) {
        return PaneEditorCommandOutcome.staleTarget;
      }
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
          _requireCurrentMutationTarget(context, targetSession);
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
  ) {
    return deleteProposals(context, [proposal]);
  }

  Future<PaneEditorCommandOutcome> deleteProposals(
    PaneEditorContext context,
    Iterable<AiProposal> proposals,
  ) async {
    final uniqueProposals = <String, AiProposal>{
      for (final proposal in proposals) proposal.id: proposal,
    }.values.toList(growable: false);
    if (uniqueProposals.isEmpty) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final targetSession = resolved.session;
    if (uniqueProposals.any(
      (proposal) => proposal.noteId != targetSession.noteId,
    )) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final vault = _runtimes.requireCurrent().vault;
    final result = await _mutations.run<_NoteHydration>(
      WorkspaceMutationPlan<_NoteHydration>(
        affectedNoteIds: {targetSession.noteId},
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          _requireCurrentMutationTarget(context, targetSession);
          final noteId = targetSession.noteId;
          await vault.runMutationTransaction(
            label: 'delete-proposals',
            action: () async {
              for (final proposal in uniqueProposals) {
                await vault.deleteProposal(proposal.id);
              }
            },
          );
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
          patch: WorkspaceStatePatch(
            message: uniqueProposals.length == 1
                ? 'AI 建议已删除'
                : '已删除 ${uniqueProposals.length} 条 AI 建议',
          ),
        ),
      ),
    );
    return _editorResult(result, context);
  }

  Future<PaneEditorCommandOutcome> applyProposal(
    PaneEditorContext context,
    AiProposal proposal,
  ) async {
    final resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (proposal.noteId != resolved.noteId ||
        proposal.status != ProposalStatus.pending) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final targetSession = resolved.session;
    final runtime = _runtimes.requireCurrent();
    final result = await _mutations.run<_NoteHydration>(
      WorkspaceMutationPlan<_NoteHydration>(
        affectedNoteIds: {targetSession.noteId},
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          _requireCurrentMutationTarget(context, targetSession);
          final noteId = targetSession.noteId;
          await runtime.proposalService.applyProposal(proposal.id);
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final note = await runtime.vault.readNote(noteId);
              return VaultMutationDelta(
                value: _NoteHydration(
                  note: note,
                  proposals: await runtime.vault.listProposals(noteId),
                ),
                refreshedNotesByNewId: {note.id: note},
              );
            },
          );
        },
        prepareCommit: (delta) {
          if (_resolve(context) == null) {
            return _commits.prepare(delta);
          }
          final note = delta.value.note;
          return _commits.prepare(
            delta,
            upsertedNotesById: {note.id: note},
            replacementProposalsByNoteId: {note.id: delta.value.proposals},
            patch: const WorkspaceStatePatch(message: 'AI 建议已追加到当前笔记'),
          );
        },
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

  Future<PaneEditorCommandOutcome> deleteAiMaterial(
    PaneEditorContext context,
    AiMaterial material,
  ) {
    return deleteAiMaterials(context, [material]);
  }

  Future<PaneEditorCommandOutcome> deleteAiMaterials(
    PaneEditorContext context,
    Iterable<AiMaterial> materials,
  ) async {
    final requestedMaterials = <String, AiMaterial>{
      for (final material in materials) material.id: material,
    }.values.toList(growable: false);
    if (requestedMaterials.isEmpty) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final resolved = _resolve(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final targetSession = resolved.session;
    final vault = _runtimes.requireCurrent().vault;
    final deletedMaterialIds = requestedMaterials
        .map((material) => material.id)
        .toSet();
    final result = await _mutations.run<VaultNoteContent>(
      WorkspaceMutationPlan<VaultNoteContent>(
        affectedNoteIds: {targetSession.noteId},
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          _requireCurrentMutationTarget(context, targetSession);
          final currentById = {
            for (final material in targetSession.note.aiMaterials)
              material.id: material,
          };
          final currentMaterials = <AiMaterial>[];
          for (final material in requestedMaterials) {
            final current = currentById[material.id];
            if (current == null) {
              throw StateError('AI material not found: ${material.id}');
            }
            currentMaterials.add(current);
          }
          await vault.runMutationTransaction(
            label: 'delete-ai-materials',
            action: () async {
              for (final material in currentMaterials) {
                await vault.deleteAiMaterial(material);
              }
            },
          );
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final current = targetSession.note;
              final note = VaultNoteContent(
                id: current.id,
                title: current.title,
                path: current.path,
                markdownPath: current.markdownPath,
                assetsPath: current.assetsPath,
                createdAt: current.createdAt,
                updatedAt: current.updatedAt,
                markdown: current.markdown,
                outline: current.outline,
                aiMaterials: current.aiMaterials
                    .where(
                      (material) => !deletedMaterialIds.contains(material.id),
                    )
                    .toList(growable: false),
                attachments: current.attachments,
              );
              return VaultMutationDelta(
                value: note,
                refreshedNotesByNewId: {note.id: note},
              );
            },
          );
        },
        prepareCommit: (delta) {
          final note = delta.value;
          final selected = Set<String>.of(
            _materials.snapshotFor(note.id).selectedAiMaterialIds,
          )..removeAll(deletedMaterialIds);
          return _commits.prepare(
            delta,
            upsertedNotesById: {note.id: note},
            selectedAiMaterialIdsByNoteId: {note.id: selected},
            patch: WorkspaceStatePatch(
              message: requestedMaterials.length == 1
                  ? 'AI 素材已删除'
                  : '已删除 ${requestedMaterials.length} 个 AI 素材',
              selectedPreviewImageSrc: null,
            ),
          );
        },
      ),
    );
    return _editorResult(result, context);
  }

  @Deprecated('Use deleteAiMaterial.')
  Future<PaneEditorCommandOutcome> deleteSource(
    PaneEditorContext context,
    AiMaterial source,
  ) => deleteAiMaterial(context, source);

  @Deprecated('Use deleteAiMaterials.')
  Future<PaneEditorCommandOutcome> deleteSources(
    PaneEditorContext context,
    Iterable<AiMaterial> sources,
  ) => deleteAiMaterials(context, sources);

  Future<AttachmentDeletionImpact?> analyzeAttachmentDeletion(
    PaneEditorContext context,
    Iterable<NoteAttachment> attachments,
  ) async {
    if (_resolve(context) == null) {
      return null;
    }
    final unique = <String, NoteAttachment>{
      for (final attachment in attachments) attachment.id: attachment,
    }.values.toList(growable: false);
    if (unique.isEmpty) {
      return const AttachmentDeletionImpact(attachments: [], references: []);
    }
    final impact = await _runtimes
        .requireCurrent()
        .vault
        .analyzeAttachmentDeletion(unique);
    return _resolve(context) == null ? null : impact;
  }

  Future<PaneEditorCommandOutcome> deleteNoteAttachments(
    PaneEditorContext context,
    AttachmentDeletionImpact impact,
  ) async {
    final resolved = _resolve(context);
    if (resolved == null || impact.attachments.isEmpty) {
      return resolved == null
          ? PaneEditorCommandOutcome.staleTarget
          : PaneEditorCommandOutcome.unchanged;
    }
    final affectedNoteIds = <String>{
      ...impact.attachments.map((attachment) => attachment.noteId),
      ...impact.references.map((reference) => reference.noteId),
      ...impact.noteFingerprints.keys,
    };
    final targetSession = resolved.session;
    final vault = _runtimes.requireCurrent().vault;
    final result = await _mutations.run<Map<String, VaultNoteContent>>(
      WorkspaceMutationPlan<Map<String, VaultNoteContent>>(
        affectedNoteIds: affectedNoteIds,
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          _requireCurrentMutationTarget(context, targetSession);
          await vault.deleteNoteAttachments(
            attachments: impact.attachments,
            expectedImpact: impact,
          );
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final notes = <String, VaultNoteContent>{};
              for (final noteId in affectedNoteIds) {
                notes[noteId] = await vault.readNote(noteId);
              }
              return VaultMutationDelta(
                value: notes,
                refreshedNotesByNewId: notes,
                resources: await vault.listResources(),
              );
            },
          );
        },
        prepareCommit: (delta) => _commits.prepare(
          delta,
          upsertedNotesById: delta.value,
          patch: WorkspaceStatePatch(
            resources: delta.resources,
            message: impact.attachments.length == 1
                ? '笔记附件已永久删除'
                : '已永久删除 ${impact.attachments.length} 个笔记附件',
            selectedPreviewImageSrc: null,
          ),
        ),
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

  Future<List<int>> readAiMaterialContent(AiMaterial material) {
    return _runtimes.requireCurrent().vault.readAiMaterialContent(material);
  }

  Future<List<int>> readNoteAttachment(NoteAttachment attachment) {
    return _runtimes.requireCurrent().vault.readNoteAttachment(attachment);
  }

  @Deprecated('Use readAiMaterialContent.')
  Future<List<int>> readSourceAttachment(AiMaterial source) {
    return readAiMaterialContent(source);
  }

  NoteAttachment? _imageAttachmentForId(
    NoteDocumentSession session,
    String attachmentId,
  ) {
    for (final attachment in session.note.attachments) {
      if (attachment.id == attachmentId &&
          attachment.mediaKind == MediaKind.image) {
        return attachment;
      }
    }
    return null;
  }

  bool _sameImageAttachment(NoteAttachment expected, NoteAttachment actual) {
    return expected.id == actual.id &&
        expected.noteId == actual.noteId &&
        expected.relativePath == actual.relativePath &&
        expected.updatedAt == actual.updatedAt;
  }

  String _imageMarkdownTag(VaultNoteContent note, NoteAttachment attachment) {
    final src = _markdownAttachmentSrc(note, attachment);
    return '<img src="${escapeHtmlAttribute(src)}" '
        'width="${_readState().preferences.pastedImageWidth}">';
  }

  int _caretOffsetAfterImageReference(
    String markdown,
    MarkdownImageReference reference,
  ) {
    final lineBreakLength = markdown.startsWith('\r\n', reference.end)
        ? 2
        : reference.end < markdown.length &&
              (markdown.codeUnitAt(reference.end) == 0x0A ||
                  markdown.codeUnitAt(reference.end) == 0x0D)
        ? 1
        : 0;
    return reference.end + lineBreakLength;
  }

  String _noteEditorPastedImageFilename(String filename) {
    final extension = p.extension(filename).isEmpty
        ? '.png'
        : p.extension(filename);
    final base = p.basenameWithoutExtension(filename);
    final match = RegExp(r'^clipboard-(\d+)(?:-.+)?$').firstMatch(base);
    return match == null ? filename : '${match.group(1)}$extension';
  }

  String _markdownAttachmentSrc(VaultNote note, NoteAttachment attachment) {
    final assetsDirectory = '${p.basenameWithoutExtension(note.path)}.assets';
    return '$assetsDirectory/${attachment.relativePath}'.replaceAll('\\', '/');
  }

  void _replaceEditorSelection(
    NoteDocumentSession session,
    String replacement, {
    required TextEditingValue target,
    bool lineInsertion = false,
  }) {
    final controller = session.controller;
    final selection = _normalizedSelection(target);
    final prefix = lineInsertion
        ? _lineInsertionPrefix(target.text, selection.start)
        : '';
    final suffix = lineInsertion
        ? _lineInsertionSuffix(target.text, selection.end)
        : '';
    final inserted = '$prefix$replacement$suffix';
    controller.value = target.copyWith(
      text: target.text.replaceRange(selection.start, selection.end, inserted),
      selection: TextSelection.collapsed(
        offset: selection.start + prefix.length + replacement.length,
      ),
      composing: TextRange.empty,
    );
  }

  String _lineInsertionPrefix(String text, int offset) {
    final before = text.substring(0, offset);
    if (before.isEmpty || before.endsWith('\n')) {
      return '';
    }
    return '\n';
  }

  String _lineInsertionSuffix(String text, int offset) {
    if (offset >= text.length || text.startsWith('\n', offset)) {
      return '';
    }
    return '\n';
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

  ResolvedPaneEditorContext? _resolvePasteTarget(
    PaneEditorContext context,
    TextEditingValue target,
  ) {
    final resolved = _resolve(context);
    if (resolved == null || resolved.session.controller.text != target.text) {
      return null;
    }
    return resolved;
  }

  void _requireCurrentMutationTarget(
    PaneEditorContext context,
    NoteDocumentSession targetSession,
  ) {
    final resolved = _resolve(context);
    if (resolved == null || !identical(resolved.session, targetSession)) {
      throw const _StalePaneEditorMutationTarget();
    }
  }

  void _requireCurrentPasteMutationTarget(
    PaneEditorContext context,
    NoteDocumentSession targetSession,
    TextEditingValue target,
  ) {
    final resolved = _resolvePasteTarget(context, target);
    if (resolved == null || !identical(resolved.session, targetSession)) {
      throw const _StalePaneEditorMutationTarget();
    }
  }

  void _requireUnchangedPasteTextAfterBackend(
    NoteDocumentSession targetSession,
    TextEditingValue target, {
    required Set<String> noteIds,
  }) {
    final sessionStillOwned = noteSessionRegistryOwnsSession(
      sessions: _sessions,
      sessionIdentity: targetSession,
      noteIds: noteIds,
    );
    if (!sessionStillOwned || targetSession.controller.text == target.text) {
      return;
    }
    throw const _PasteTargetChangedAfterBackend();
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
      case BackendFailed<T>(:final error)
          when error is _StalePaneEditorMutationTarget:
        return PaneEditorCommandOutcome.staleTarget;
      case BackendFailed<T>(:final error, :final stackTrace):
        Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

final class _StalePaneEditorMutationTarget implements Exception {
  const _StalePaneEditorMutationTarget();
}

final class _PasteTargetChangedAfterBackend implements Exception {
  const _PasteTargetChangedAfterBackend();
}

final class _MaterialHydration {
  const _MaterialHydration({required this.note, required this.material});

  final VaultNoteContent note;
  final AiMaterial material;
}

final class _AttachmentHydration {
  const _AttachmentHydration({required this.note, required this.attachment});

  final VaultNoteContent note;
  final NoteAttachment attachment;
}

final class _NoteHydration {
  const _NoteHydration({required this.note, required this.proposals});

  final VaultNoteContent note;
  final List<AiProposal> proposals;
}
