import '../../domain/vault/vault_resource_name.dart';
import 'memory_vault_state.dart';

final class MemoryVaultPaths {
  const MemoryVaultPaths(this.state);

  final MemoryVaultState state;

  String normalizeFolderPath(String path) {
    final parts = path
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty && part != '.')
        .toList();
    if (parts.any((part) => part == '..')) {
      throw ArgumentError('Path cannot escape the vault: $path');
    }
    return parts.join('/');
  }

  String joinPath(String parent, String child) {
    final cleanParent = normalizeFolderPath(parent);
    return cleanParent.isEmpty ? child : '$cleanParent/$child';
  }

  String dirname(String path) {
    final index = path.lastIndexOf('/');
    return index < 0 ? '' : path.substring(0, index);
  }

  String basename(String path) {
    final index = path.lastIndexOf('/');
    return index < 0 ? path : path.substring(index + 1);
  }

  String basenameWithoutExtension(String path) {
    final base = basename(path);
    return base.endsWith('.md') ? base.substring(0, base.length - 3) : base;
  }

  String withoutExtension(String path) {
    return path.endsWith('.md') ? path.substring(0, path.length - 3) : path;
  }

  String assetsPathFor(String notePath) =>
      '${withoutExtension(notePath)}.assets';

  void ensureFolderExists(String folderPath) {
    if (folderPath.isNotEmpty && !state.folders.contains(folderPath)) {
      throw StateError('Folder not found: $folderPath');
    }
  }

  String resourceFolderPath(
    String parentPath,
    String title, {
    String? excludePath,
  }) {
    final name = requireValidVaultResourceName(title);
    final names = _canonicalResourceNames(parentPath, excludePath: excludePath);
    if (names.contains(canonicalVaultResourceName(name))) {
      throw VaultResourceNameConflictException(name);
    }
    return joinPath(parentPath, name);
  }

  String uniqueNotePath(
    String parentPath,
    String title, {
    String? excludePath,
  }) {
    final base = requireValidVaultResourceName(title);
    final names = _canonicalResourceNames(parentPath, excludePath: excludePath);
    var candidateTitle = base;
    var suffix = 2;
    while (names.contains(canonicalVaultResourceName(candidateTitle))) {
      candidateTitle = '$base $suffix';
      suffix += 1;
    }
    return joinPath(parentPath, '$candidateTitle.md');
  }

  String resourceNotePath(
    String parentPath,
    String title, {
    String? excludePath,
  }) {
    final name = requireValidVaultResourceName(title);
    final names = _canonicalResourceNames(parentPath, excludePath: excludePath);
    if (names.contains(canonicalVaultResourceName(name))) {
      throw VaultResourceNameConflictException(name);
    }
    return joinPath(parentPath, '$name.md');
  }

  String uniqueAttachmentPath(String noteId, String filename) {
    final existing = {
      for (final source in state.sources[noteId] ?? const [])
        if (source.attachmentPath != null) source.attachmentPath!,
    };
    final dot = filename.lastIndexOf('.');
    final base = dot <= 0 ? filename : filename.substring(0, dot);
    final extension = dot <= 0 ? '' : filename.substring(dot);
    var index = 1;
    while (true) {
      final name = index == 1 ? filename : '$base-$index$extension';
      final path = 'attachments/$name';
      if (!existing.contains(path)) {
        return path;
      }
      index += 1;
    }
  }

  Set<String> _canonicalResourceNames(
    String parentPath, {
    String? excludePath,
  }) {
    final parent = normalizeFolderPath(parentPath);
    return <String>{
      for (final folder in state.folders)
        if (dirname(folder) == parent && folder != excludePath)
          canonicalVaultResourceName(basename(folder)),
      for (final note in state.notes.values)
        if (dirname(note.path) == parent && note.path != excludePath)
          canonicalVaultResourceName(basenameWithoutExtension(note.path)),
    };
  }
}
