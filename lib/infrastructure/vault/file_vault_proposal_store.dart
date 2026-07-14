import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../domain/vault/vault_resource.dart';
import 'file_vault_operations.dart';
import 'file_vault_paths.dart';
import 'vault_post_commit_error.dart';

final class FileVaultProposalStore {
  const FileVaultProposalStore({
    required this.paths,
    required this.operations,
    required this.listNoteIds,
    required this.listProposalsCallback,
  });

  final FileVaultPaths paths;
  final FileVaultOperations operations;
  final Future<List<String>> Function() listNoteIds;
  final Future<List<AiProposal>> Function(String noteId) listProposalsCallback;

  Future<AiProposal> saveProposal(AiProposal proposal) async {
    await paths.ensureSafePath(paths.proposalsFile(proposal.noteId).path);
    final proposals = await listProposalsCallback(proposal.noteId);
    return runVaultPostCommit(() async {
      await writeProposals(proposal.noteId, [
        ...proposals.where((item) => item.id != proposal.id),
        proposal,
      ]);
      return proposal;
    });
  }

  Future<List<AiProposal>> listProposals(String noteId) async {
    if (paths.catalog.isDeleted(noteId)) {
      return const [];
    }
    final proposals =
        (await readProposalsFile(
            noteId,
          )).where((proposal) => proposal.noteId == noteId).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return proposals;
  }

  Future<AiProposal> getProposal(String proposalId) async {
    final match = await _findProposal(proposalId);
    if (match == null) {
      throw StateError('Proposal not found: $proposalId');
    }
    return match.$2;
  }

  Future<AiProposal> updateProposal(AiProposal proposal) async {
    await paths.ensureSafePath(paths.proposalsFile(proposal.noteId).path);
    final proposals = await listProposalsCallback(proposal.noteId);
    return runVaultPostCommit(() async {
      await writeProposals(proposal.noteId, [
        ...proposals.where((item) => item.id != proposal.id),
        proposal,
      ]);
      return proposal;
    });
  }

  Future<void> deleteProposal(String proposalId) async {
    final match = await _findProposal(proposalId);
    if (match == null) {
      throw StateError('Proposal not found: $proposalId');
    }
    final (noteId, proposal) = match;
    await paths.ensureSafePath(paths.proposalsFile(noteId).path);
    final proposals = await listProposalsCallback(noteId);
    final updated = proposals.where((item) => item.id != proposal.id).toList();
    await runVaultPostCommit(() => writeProposals(noteId, updated));
  }

  Future<List<AiProposal>> readProposalsFile(String noteId) async {
    var file = paths.proposalsFile(noteId);
    if (!await operations.fileExists(file)) {
      final legacy = paths.legacyProposalsFile(noteId);
      if (await operations.fileExists(legacy)) {
        file = legacy;
      }
    }
    if (!await operations.fileExists(file)) {
      return const [];
    }
    return (jsonDecode(await operations.readFileString(file)) as List<Object?>)
        .map(
          (item) => AiProposal.fromJson((item as Map).cast<String, Object?>()),
        )
        .toList();
  }

  Future<void> writeProposals(String noteId, List<AiProposal> proposals) async {
    final file = paths.proposalsFile(noteId);
    await paths.ensureSafePath(file.path);
    await operations.createDirectory(file.parent, recursive: true);
    await operations.writeFileString(
      file,
      const JsonEncoder.withIndent(
        '  ',
      ).convert(proposals.map((proposal) => proposal.toJson()).toList()),
    );
  }

  Future<void> rewriteMoved(String noteId) async {
    final proposals = await readProposalsFile(noteId);
    if (proposals.isNotEmpty ||
        await operations.fileExists(paths.proposalsFile(noteId))) {
      await writeProposals(noteId, [
        for (final proposal in proposals) proposal.copyWith(noteId: noteId),
      ]);
    }
  }

  Future<void> rewriteCopied(
    String sourceNoteId,
    String copiedNoteId,
    Map<String, String> sourceIdMap,
    DateTime now,
  ) async {
    final proposals = await readProposalsFile(sourceNoteId);
    if (proposals.isNotEmpty) {
      await writeProposals(copiedNoteId, [
        for (final proposal in proposals)
          AiProposal(
            id: const Uuid().v4(),
            noteId: copiedNoteId,
            sourceIds: [
              for (final sourceId in proposal.sourceIds)
                sourceIdMap[sourceId] ?? sourceId,
            ],
            title: proposal.title,
            proposedMarkdown: proposal.proposedMarkdown,
            status: proposal.status,
            createdAt: now,
            updatedAt: now,
          ),
      ]);
    }
  }

  Future<void> deleteForNote(String noteId) async {
    for (final file in [
      paths.proposalsFile(noteId),
      paths.legacyProposalsFile(noteId),
    ]) {
      if (await operations.fileExists(file)) {
        await operations.deleteFile(file);
      }
    }
  }

  Future<(String, AiProposal)?> _findProposal(String proposalId) async {
    for (final noteId in await listNoteIds()) {
      for (final proposal in await listProposalsCallback(noteId)) {
        if (proposal.id == proposalId) {
          return (noteId, proposal);
        }
      }
    }
    return null;
  }
}
