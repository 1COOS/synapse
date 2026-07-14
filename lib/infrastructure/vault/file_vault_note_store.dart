import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/vault_resource.dart';
import 'file_vault_operations.dart';
import 'file_vault_paths.dart';
import 'file_vault_proposal_store.dart';
import 'file_vault_source_store.dart';
import 'vault_post_commit_error.dart';
import 'vault_store_helpers.dart';

final class FileVaultNoteStore {
  const FileVaultNoteStore({
    required this.paths,
    required this.operations,
    required this.sources,
    required this.proposals,
    required this.readNoteCallback,
    required this.listResourcesCallback,
    required this.listSources,
  });

  final FileVaultPaths paths;
  final FileVaultOperations operations;
  final FileVaultSourceStore sources;
  final FileVaultProposalStore proposals;
  final Future<VaultNoteContent> Function(String noteId) readNoteCallback;
  final Future<List<VaultResourceNode>> Function() listResourcesCallback;
  final Future<List<SourceItem>> Function(String noteId) listSources;

  Future<VaultResourceNode> createFolder({
    required String parentPath,
    required String title,
  }) async {
    final parent = paths.directoryForFolder(parentPath);
    await operations.ensureRoot();
    await paths.ensureSafePath(parent.path);
    final folder = await paths.uniqueDirectory(parent, title);
    await paths.ensureSafePath(folder.path);
    return runVaultPostCommit(() async {
      await operations.createDirectory(parent, recursive: true);
      await operations.createDirectory(folder, recursive: true);
      return VaultResourceNode(
        id: paths.relativePath(folder.path),
        title: p.basename(folder.path),
        path: paths.relativePath(folder.path),
        type: VaultResourceType.folder,
      );
    });
  }

  Future<VaultNote> createNote({
    required String parentPath,
    required String title,
  }) async {
    final parent = paths.directoryForFolder(parentPath);
    await operations.ensureRoot();
    await paths.ensureSafePath(parent.path);
    final file = await paths.uniqueNoteFile(parent, title);
    final assets = Directory(paths.assetsDirectoryPathForFile(file));
    await paths.ensureSafePath(file.path);
    await paths.ensureSafePath(assets.path);
    await paths.ensureSafePath(
      paths.sourcesFile(paths.relativePath(file.path)).path,
    );
    await paths.ensureSafePath(
      paths.proposalsFile(paths.relativePath(file.path)).path,
    );
    return runVaultPostCommit(() async {
      await operations.createDirectory(parent, recursive: true);
      final now = DateTime.now().toUtc();
      final note = _noteFromFile(file, createdAt: now, updatedAt: now);
      await operations.writeFileString(file, initialVaultMarkdown(note));
      await operations.createDirectory(
        Directory(note.assetsPath),
        recursive: true,
      );
      await sources.writeSources(note.id, const []);
      await proposals.writeProposals(note.id, const []);
      return note;
    });
  }

  Future<List<VaultResourceNode>> listResources() async {
    await operations.ensureRoot();
    return _listChildren(paths.root);
  }

  Future<VaultNoteContent> readNote(String noteId) async {
    final file = paths.fileForNoteId(noteId);
    if (!await operations.fileExists(file)) {
      throw StateError('Note not found: $noteId');
    }
    final markdown = await operations.readFileString(file);
    final doc = MarkdownDocument.parse(markdown);
    final note = await _noteFromExistingFile(file, doc);
    return VaultNoteContent(
      id: note.id,
      title: note.title,
      path: note.path,
      markdownPath: note.markdownPath,
      assetsPath: note.assetsPath,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      markdown: markdown,
      outline: doc.outline,
      sources: await listSources(note.id),
    );
  }

  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    final file = paths.fileForNoteId(noteId);
    await paths.ensureSafePath(file.path);
    return runVaultPostCommit(() async {
      await operations.writeFileString(file, markdown);
      return readNoteCallback(noteId);
    });
  }

  Future<VaultNoteContent> appendMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    final file = paths.fileForNoteId(noteId);
    final current = await operations.readFileString(file);
    return runVaultPostCommit(() async {
      await operations.writeFileString(
        file,
        '${current.trimRight()}\n\n${markdown.trim()}\n',
      );
      return readNoteCallback(noteId);
    });
  }

  Future<void> deleteNote(String noteId) async {
    final file = paths.fileForNoteId(noteId);
    if (!await operations.fileExists(file)) {
      throw StateError('Note not found: $noteId');
    }
    final assets = Directory(paths.assetsDirectoryPathForFile(file));
    await paths.ensureSafePath(assets.path);
    await runVaultPostCommit(() async {
      await operations.deleteFile(file);
      if (await operations.directoryExists(assets)) {
        await operations.deleteDirectory(assets, recursive: true);
      }
    });
  }

  Future<VaultNote> renameNote({
    required String noteId,
    required String title,
  }) async {
    final file = paths.fileForNoteId(noteId);
    if (!await operations.fileExists(file)) {
      throw StateError('Note not found: $noteId');
    }
    return _moveNoteFile(file: file, parent: file.parent, title: title);
  }

  Future<VaultNote> copyNote({required String noteId}) async {
    final file = paths.fileForNoteId(noteId);
    if (!await operations.fileExists(file)) {
      throw StateError('Note not found: $noteId');
    }
    final markdown = await operations.readFileString(file);
    final doc = MarkdownDocument.parse(markdown);
    final note = await _noteFromExistingFile(file, doc);
    final now = DateTime.now().toUtc();
    final target = await paths.uniqueNoteFile(file.parent, note.title);
    await paths.ensureSafePath(target.path);
    final copiedId = paths.relativePath(target.path);
    final copiedTitle = p.basenameWithoutExtension(target.path);
    final assets = Directory(paths.assetsDirectoryPathForFile(file));
    final copiedAssets = Directory(paths.assetsDirectoryPathForFile(target));
    await paths.ensureSafePath(assets.path);
    await paths.ensureSafePath(copiedAssets.path);
    final hasAssets = await operations.directoryExists(assets);
    if (hasAssets) {
      await operations.ensureLinkFreeTree(assets);
    }

    return runVaultPostCommit(() async {
      final copiedMarkdown = rewriteNoteAssetReferences(
        retitleVaultMarkdown(markdown, newTitle: copiedTitle, updatedAt: now),
        oldAssetsDirectory: p.basename(assets.path),
        newAssetsDirectory: p.basename(copiedAssets.path),
      );
      await operations.writeFileString(target, copiedMarkdown);
      if (hasAssets) {
        await _copyDirectory(assets, copiedAssets);
      } else {
        await operations.createDirectory(copiedAssets, recursive: true);
      }
      final sourceIdMap = await sources.rewriteCopied(copiedId, now);
      await proposals.rewriteCopied(copiedId, sourceIdMap, now);
      return (await readNoteCallback(copiedId)).note;
    });
  }

  Future<VaultNote> moveNote({
    required String noteId,
    required String parentPath,
  }) async {
    final file = paths.fileForNoteId(noteId);
    if (!await operations.fileExists(file)) {
      throw StateError('Note not found: $noteId');
    }
    final parent = paths.directoryForFolder(parentPath);
    if (!await operations.directoryExists(parent)) {
      throw StateError('Folder not found: $parentPath');
    }
    final doc = MarkdownDocument.parse(await operations.readFileString(file));
    final note = await _noteFromExistingFile(file, doc);
    return _moveNoteFile(file: file, parent: parent, title: note.title);
  }

  Future<void> deleteFolder(String folderPath) async {
    final relative = paths.normalizeFolderPath(folderPath);
    if (relative.isEmpty) {
      throw StateError('Cannot delete the vault root.');
    }
    final directory = paths.directoryForFolder(relative);
    if (!await operations.directoryExists(directory)) {
      throw StateError('Folder not found: $folderPath');
    }
    await runVaultPostCommit(
      () => operations.deleteDirectory(directory, recursive: true),
    );
  }

  Future<VaultResourceNode> renameFolder({
    required String folderPath,
    required String title,
  }) async {
    final relative = paths.normalizeFolderPath(folderPath);
    if (relative.isEmpty) {
      throw StateError('Cannot rename the vault root.');
    }
    final directory = paths.directoryForFolder(relative);
    if (!await operations.directoryExists(directory)) {
      throw StateError('Folder not found: $folderPath');
    }
    final target = await paths.uniqueDirectory(
      directory.parent,
      title,
      excludePath: directory.path,
    );
    await paths.ensureSafePath(target.path);
    if (p.equals(p.normalize(directory.path), p.normalize(target.path))) {
      return VaultResourceNode(
        id: relative,
        title: p.basename(directory.path),
        path: relative,
        type: VaultResourceType.folder,
      );
    }

    final noteIds = await noteIdsInsideFolder(relative);
    final targetRelative = paths.relativePath(target.path);
    final movedNoteIds = [
      for (final noteId in noteIds)
        replaceVaultPathPrefix(noteId, relative, targetRelative),
    ];
    return runVaultPostCommit(() async {
      final moved = await operations.renameDirectory(directory, target.path);
      for (final noteId in movedNoteIds) {
        await sources.rewriteMoved(noteId);
        await proposals.rewriteMoved(noteId);
      }
      return VaultResourceNode(
        id: paths.relativePath(moved.path),
        title: p.basename(moved.path),
        path: paths.relativePath(moved.path),
        type: VaultResourceType.folder,
      );
    });
  }

  Future<List<String>> listNoteIds() async {
    final noteIds = <String>[];
    void collect(List<VaultResourceNode> nodes) {
      for (final node in nodes) {
        if (node.isNote) {
          noteIds.add(node.id);
        } else {
          collect(node.children);
        }
      }
    }

    collect(await listResourcesCallback());
    return noteIds;
  }

  Future<List<String>> noteIdsInsideFolder(String folderPath) async {
    final noteIds = <String>[];
    void collect(List<VaultResourceNode> nodes) {
      for (final node in nodes) {
        if (node.isNote && isVaultPathInside(node.id, folderPath)) {
          noteIds.add(node.id);
        }
        collect(node.children);
      }
    }

    collect(await listResourcesCallback());
    return noteIds;
  }

  Future<List<VaultResourceNode>> _listChildren(Directory directory) async {
    final nodes = <VaultResourceNode>[];
    for (final entity in await operations.listDirectory(directory)) {
      if (entity is Link) {
        continue;
      }
      final name = p.basename(entity.path);
      if (name.startsWith('.') || name.endsWith('.assets')) {
        continue;
      }
      if (entity is Directory) {
        if (await _isLegacyProjectPackage(entity)) {
          continue;
        }
        nodes.add(
          VaultResourceNode(
            id: paths.relativePath(entity.path),
            title: name,
            path: paths.relativePath(entity.path),
            type: VaultResourceType.folder,
            children: await _listChildren(entity),
          ),
        );
      } else if (entity is File && p.extension(entity.path) == '.md') {
        final doc = MarkdownDocument.parse(
          await operations.readFileString(entity),
        );
        final note = await _noteFromExistingFile(entity, doc);
        nodes.add(
          VaultResourceNode(
            id: note.id,
            title: note.title,
            path: note.path,
            type: VaultResourceType.note,
          ),
        );
      }
    }
    sortVaultNodes(nodes);
    return nodes;
  }

  Future<bool> _isLegacyProjectPackage(Directory directory) async {
    final hasIndex = await operations.fileExists(
      File(p.join(directory.path, 'index.md')),
    );
    return hasIndex &&
        await operations.fileExists(
          File(p.join(directory.path, '.synapse', 'project.json')),
        );
  }

  Future<VaultNote> _noteFromExistingFile(
    File file,
    MarkdownDocument doc,
  ) async {
    final stat = await operations.stat(file);
    final createdAt =
        _parseMarkdownTime(doc.frontmatter['createdAt']) ??
        stat.changed.toUtc();
    final updatedAt =
        _parseMarkdownTime(doc.frontmatter['updatedAt']) ??
        stat.modified.toUtc();
    return _noteFromFile(
      file,
      createdAt: createdAt,
      updatedAt: updatedAt,
      title: doc.visibleTitle,
    );
  }

  VaultNote _noteFromFile(
    File file, {
    required DateTime createdAt,
    required DateTime updatedAt,
    String? title,
  }) {
    final id = paths.relativePath(file.path);
    return VaultNote(
      id: id,
      title: title ?? _titleFromFile(file),
      path: id,
      markdownPath: file.path,
      assetsPath: paths.assetsDirectoryPathForFile(file),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  String _titleFromFile(File file) {
    return p.basenameWithoutExtension(file.path);
  }

  Future<VaultNote> _moveNoteFile({
    required File file,
    required Directory parent,
    required String title,
  }) async {
    final markdown = await operations.readFileString(file);
    final now = DateTime.now().toUtc();
    final target = await paths.uniqueNoteFile(
      parent,
      title,
      excludePath: file.path,
    );
    await paths.ensureSafePath(target.path);
    final movedId = paths.relativePath(target.path);
    final movedTitle = p.basenameWithoutExtension(target.path);
    final assets = Directory(paths.assetsDirectoryPathForFile(file));
    final movedAssets = Directory(paths.assetsDirectoryPathForFile(target));
    await paths.ensureSafePath(assets.path);
    await paths.ensureSafePath(movedAssets.path);
    final updatedMarkdown = rewriteNoteAssetReferences(
      retitleVaultMarkdown(markdown, newTitle: movedTitle, updatedAt: now),
      oldAssetsDirectory: p.basename(assets.path),
      newAssetsDirectory: p.basename(movedAssets.path),
    );

    return runVaultPostCommit(() async {
      if (p.equals(p.normalize(file.path), p.normalize(target.path))) {
        await operations.writeFileString(file, updatedMarkdown);
      } else {
        await operations.createDirectory(target.parent, recursive: true);
        final movedFile = await operations.renameFile(file, target.path);
        await operations.writeFileString(movedFile, updatedMarkdown);
        if (await operations.directoryExists(assets)) {
          await operations.renameDirectory(assets, movedAssets.path);
        } else {
          await operations.createDirectory(movedAssets, recursive: true);
        }
      }
      await sources.rewriteMoved(movedId);
      await proposals.rewriteMoved(movedId);
      return (await readNoteCallback(movedId)).note;
    });
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await operations.ensureNotLink(source);
    await paths.ensureSafePath(target.path);
    if (await operations.directoryExists(target)) {
      await operations.deleteDirectory(target, recursive: true);
    }
    await operations.createDirectory(target, recursive: true);
    for (final entity in await operations.listDirectory(source)) {
      await operations.ensureNotLink(entity);
      final targetPath = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(targetPath));
      } else if (entity is File) {
        await operations.copyFile(entity, targetPath);
      }
    }
  }

  DateTime? _parseMarkdownTime(Object? value) {
    final text = value?.toString();
    if (text == null || text.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(text.replaceFirst(' ', 'T'))?.toUtc();
  }
}
