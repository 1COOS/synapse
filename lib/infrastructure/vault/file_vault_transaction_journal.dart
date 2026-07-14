import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'atomic_vault_file_writer.dart';
import 'file_vault_paths.dart';

final class FileVaultTransactionRecoveryError implements Exception {
  const FileVaultTransactionRecoveryError({
    required this.cause,
    required this.rollbackError,
  });

  final Object cause;
  final Object rollbackError;

  @override
  String toString() {
    return 'Vault transaction failed: $cause; rollback failed: $rollbackError';
  }
}

final class FileVaultPathPreparation {
  const FileVaultPathPreparation._({this.backupPath});

  const FileVaultPathPreparation.none() : this._();

  const FileVaultPathPreparation.restoreFrom(String backupPath)
    : this._(backupPath: backupPath);

  final String? backupPath;
}

final class FileVaultTransactionJournal {
  FileVaultTransactionJournal({
    required this.paths,
    AtomicVaultFileWriter? atomicWriter,
  }) : _atomicWriter = atomicWriter ?? AtomicVaultFileWriter(),
       _mutex = _mutexes.putIfAbsent(
         p.normalize(p.absolute(paths.root.path)),
         _VaultJournalMutex.new,
       );

  static final Object _zoneKey = Object();
  static final Map<String, _VaultJournalMutex> _mutexes =
      <String, _VaultJournalMutex>{};

  final FileVaultPaths paths;
  final AtomicVaultFileWriter _atomicWriter;
  final _VaultJournalMutex _mutex;
  bool _didRecover = false;

  Directory get _synapseDirectory =>
      Directory(p.join(paths.root.path, '.synapse'));

  Directory get _transactionsDirectory =>
      Directory(p.join(_synapseDirectory.path, 'transactions'));

  File get _lockFile =>
      File(p.join(_synapseDirectory.path, 'vault-mutations.lock'));

  FileVaultTransaction? get currentTransaction {
    final value = Zone.current[_zoneKey];
    return value is FileVaultTransaction ? value : null;
  }

  Future<void> ensureRecovered() async {
    if (_didRecover || currentTransaction != null) {
      return;
    }
    final lease = await _acquireLease();
    try {
      if (_didRecover) {
        return;
      }
      await _recoverPendingLocked();
      _didRecover = true;
    } finally {
      await lease.release();
    }
  }

  Future<void> recoverPendingTransactions() async {
    if (currentTransaction != null) {
      return;
    }
    final lease = await _acquireLease();
    try {
      await _recoverPendingLocked();
      _didRecover = true;
    } finally {
      await lease.release();
    }
  }

  Future<T> run<T>(String label, Future<T> Function() action) async {
    if (currentTransaction != null) {
      return action();
    }
    final lease = await _acquireLease();
    try {
      await _recoverPendingLocked();
      _didRecover = true;
      final transaction = await _begin(label);
      try {
        final result = await runZoned(
          action,
          zoneValues: <Object, Object>{_zoneKey: transaction},
        );
        await transaction.commit();
        return result;
      } catch (error, stackTrace) {
        if (!transaction.isCommitted) {
          try {
            await transaction.rollback();
          } catch (rollbackError) {
            Error.throwWithStackTrace(
              FileVaultTransactionRecoveryError(
                cause: error,
                rollbackError: rollbackError,
              ),
              stackTrace,
            );
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    } finally {
      await lease.release();
    }
  }

  Future<FileVaultTransaction> _begin(String label) async {
    await paths.ensureSafePath(_transactionsDirectory.path);
    await _transactionsDirectory.create(recursive: true);
    await paths.ensureSafePath(_transactionsDirectory.path);
    final transaction = FileVaultTransaction._(
      paths: paths,
      atomicWriter: _atomicWriter,
      directory: Directory(
        p.join(_transactionsDirectory.path, const Uuid().v4()),
      ),
      label: label,
    );
    await transaction.initialize();
    return transaction;
  }

  Future<void> _recoverPendingLocked() async {
    if (!await _transactionsDirectory.exists()) {
      return;
    }
    await paths.ensureSafePath(_transactionsDirectory.path);
    final entries = await _transactionsDirectory
        .list(followLinks: false)
        .toList();
    entries.sort((left, right) => left.path.compareTo(right.path));
    for (final entry in entries) {
      if (entry is! Directory) {
        throw StateError(
          'Unexpected entry in Vault transaction directory: ${entry.path}',
        );
      }
      await FileVaultTransaction.recover(
        paths: paths,
        atomicWriter: _atomicWriter,
        directory: entry,
      );
    }
  }

  Future<_VaultJournalLease> _acquireLease() async {
    final inProcessLease = await _mutex.acquire();
    RandomAccessFile? file;
    var acquired = false;
    try {
      await paths.ensureSafePath(_synapseDirectory.path);
      await _synapseDirectory.create(recursive: true);
      await paths.ensureSafePath(_lockFile.path);
      file = await _lockFile.open(mode: FileMode.append);
      await file.lock(FileLock.blockingExclusive);
      acquired = true;
      return _VaultJournalLease(file, inProcessLease);
    } finally {
      if (!acquired) {
        await file?.close();
        inProcessLease.release();
      }
    }
  }
}

final class FileVaultTransaction {
  FileVaultTransaction._({
    required this.paths,
    required AtomicVaultFileWriter atomicWriter,
    required this.directory,
    required this.label,
    List<_JournalAction> actions = const [],
    _JournalPhase phase = _JournalPhase.active,
  }) : _atomicWriter = atomicWriter,
       _actions = List<_JournalAction>.of(actions),
       _phase = phase;

  final FileVaultPaths paths;
  final AtomicVaultFileWriter _atomicWriter;
  final Directory directory;
  final String label;
  final List<_JournalAction> _actions;
  final Set<String> _protectedPaths = <String>{};
  _JournalPhase _phase;

  File get _manifest => File(p.join(directory.path, 'manifest.json'));

  Directory get _backups => Directory(p.join(directory.path, 'backups'));

  bool get isCommitted => _phase == _JournalPhase.committed;

  Future<void> initialize() async {
    await paths.ensureSafePath(directory.path);
    await directory.create(recursive: true);
    await _persist();
  }

  Future<void> prepareCreate(String absolutePath) async {
    final relative = _relativePath(absolutePath);
    if (_isProtected(relative) ||
        await _entityType(absolutePath) != FileSystemEntityType.notFound) {
      return;
    }
    await _append(_JournalAction.delete(relative));
    _protectedPaths.add(relative);
  }

  Future<FileVaultPathPreparation> prepareWrite(String absolutePath) async {
    final relative = _relativePath(absolutePath);
    if (_isProtected(relative)) {
      return const FileVaultPathPreparation.none();
    }
    final type = await _entityType(absolutePath);
    if (type == FileSystemEntityType.notFound) {
      await _append(_JournalAction.delete(relative));
      _protectedPaths.add(relative);
      return const FileVaultPathPreparation.none();
    }
    _rejectLink(type, absolutePath);
    final backup = _nextBackupPath();
    await _append(
      _JournalAction.restore(relative, _backupRelativePath(backup)),
    );
    _protectedPaths.add(relative);
    return FileVaultPathPreparation.restoreFrom(backup);
  }

  Future<FileVaultPathPreparation> prepareDelete(String absolutePath) async {
    final relative = _relativePath(absolutePath);
    if (_isProtected(relative)) {
      return const FileVaultPathPreparation.none();
    }
    final type = await _entityType(absolutePath);
    if (type == FileSystemEntityType.notFound) {
      return const FileVaultPathPreparation.none();
    }
    _rejectLink(type, absolutePath);
    final backup = _nextBackupPath();
    await _append(
      _JournalAction.restore(relative, _backupRelativePath(backup)),
    );
    _protectedPaths.add(relative);
    return FileVaultPathPreparation.restoreFrom(backup);
  }

  Future<void> prepareMove(String sourcePath, String targetPath) async {
    final source = _relativePath(sourcePath);
    final target = _relativePath(targetPath);
    final sourceType = await _entityType(sourcePath);
    if (sourceType == FileSystemEntityType.notFound) {
      throw StateError('Vault transaction move source is missing: $source');
    }
    _rejectLink(sourceType, sourcePath);
    if (await _entityType(targetPath) != FileSystemEntityType.notFound) {
      throw StateError('Vault transaction move target already exists: $target');
    }
    await _append(_JournalAction.move(source, target));
  }

  Future<void> commit() async {
    if (_phase == _JournalPhase.committed) {
      return;
    }
    _phase = _JournalPhase.committed;
    await _persist();
    await directory.delete(recursive: true);
  }

  Future<void> rollback() async {
    if (_phase == _JournalPhase.committed) {
      return;
    }
    await _rollbackActions();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  static Future<void> recover({
    required FileVaultPaths paths,
    required AtomicVaultFileWriter atomicWriter,
    required Directory directory,
  }) async {
    await paths.ensureSafePath(directory.path);
    final manifest = File(p.join(directory.path, 'manifest.json'));
    if (!await manifest.exists()) {
      throw StateError(
        'Vault transaction manifest is missing: ${directory.path}',
      );
    }
    final decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map) {
      throw StateError('Vault transaction manifest is invalid.');
    }
    final json = decoded.cast<String, Object?>();
    if (json['version'] != 1 || json['label'] is! String) {
      throw StateError('Vault transaction manifest version is invalid.');
    }
    final phase = _JournalPhase.values.byName(json['phase']! as String);
    final actionValues = json['actions'];
    if (actionValues is! List) {
      throw StateError('Vault transaction actions are invalid.');
    }
    final transaction = FileVaultTransaction._(
      paths: paths,
      atomicWriter: atomicWriter,
      directory: directory,
      label: json['label']! as String,
      phase: phase,
      actions: [
        for (final value in actionValues)
          _JournalAction.fromJson((value as Map).cast<String, Object?>()),
      ],
    );
    if (phase == _JournalPhase.active) {
      await transaction._rollbackActions();
    }
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _append(_JournalAction action) async {
    if (_phase != _JournalPhase.active) {
      throw StateError('Cannot mutate a committed Vault transaction.');
    }
    _actions.add(action);
    await _persist();
  }

  Future<void> _persist() async {
    await _atomicWriter.writeString(
      _manifest,
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'version': 1,
        'label': label,
        'phase': _phase.name,
        'actions': [for (final action in _actions) action.toJson()],
      }),
    );
  }

  Future<void> _rollbackActions() async {
    for (final action in _actions.reversed) {
      switch (action.type) {
        case _JournalActionType.delete:
          await _deleteIfExists(_resolveRootPath(action.path));
        case _JournalActionType.restore:
          final original = _resolveRootPath(action.path);
          final backup = _resolveBackupPath(action.backup!);
          final originalType = await _entityType(original);
          final backupType = await _entityType(backup);
          if (backupType == FileSystemEntityType.notFound) {
            if (originalType == FileSystemEntityType.notFound) {
              throw StateError(
                'Vault transaction lost both original and backup: ${action.path}',
              );
            }
            continue;
          }
          _rejectLink(backupType, backup);
          await _deleteIfExists(original);
          await _renameEntity(backup, original, backupType);
        case _JournalActionType.move:
          final source = _resolveRootPath(action.source!);
          final target = _resolveRootPath(action.target!);
          final sourceType = await _entityType(source);
          final targetType = await _entityType(target);
          if (sourceType != FileSystemEntityType.notFound &&
              targetType == FileSystemEntityType.notFound) {
            continue;
          }
          if (sourceType != FileSystemEntityType.notFound ||
              targetType == FileSystemEntityType.notFound) {
            throw StateError(
              'Vault transaction move rollback is ambiguous: '
              '${action.source} <- ${action.target}',
            );
          }
          _rejectLink(targetType, target);
          await _renameEntity(target, source, targetType);
      }
    }
  }

  Future<void> _deleteIfExists(String absolutePath) async {
    final type = await _entityType(absolutePath);
    if (type == FileSystemEntityType.notFound) {
      return;
    }
    _rejectLink(type, absolutePath);
    if (type == FileSystemEntityType.directory) {
      await Directory(absolutePath).delete(recursive: true);
    } else {
      await File(absolutePath).delete();
    }
  }

  Future<void> _renameEntity(
    String source,
    String target,
    FileSystemEntityType type,
  ) async {
    await paths.ensureSafePath(source);
    await paths.ensureSafePath(target);
    await Directory(p.dirname(target)).create(recursive: true);
    await paths.ensureSafePath(target);
    await paths.ensureSafePath(source);
    if (type == FileSystemEntityType.directory) {
      await Directory(source).rename(target);
    } else {
      await File(source).rename(target);
    }
  }

  Future<FileSystemEntityType> _entityType(String absolutePath) async {
    await paths.ensureSafePath(absolutePath);
    return FileSystemEntity.type(absolutePath, followLinks: false);
  }

  void _rejectLink(FileSystemEntityType type, String path) {
    if (type == FileSystemEntityType.link) {
      throw StateError('Vault transaction path is a symbolic link: $path');
    }
  }

  String _relativePath(String absolutePath) {
    final root = p.normalize(p.absolute(paths.root.path));
    final target = p.normalize(p.absolute(absolutePath));
    if (p.equals(root, target) || !p.isWithin(root, target)) {
      throw StateError('Vault transaction path is outside the mutable root.');
    }
    return p.relative(target, from: root).replaceAll('\\', '/');
  }

  String _resolveRootPath(String relative) {
    final normalized = p.normalize(relative.replaceAll('/', p.separator));
    if (p.isAbsolute(normalized) ||
        normalized == '..' ||
        normalized.startsWith('..${p.separator}')) {
      throw StateError('Vault transaction path escapes the root: $relative');
    }
    final result = p.normalize(p.join(paths.root.path, normalized));
    _relativePath(result);
    return result;
  }

  String _resolveBackupPath(String relative) {
    final normalized = p.normalize(relative.replaceAll('/', p.separator));
    if (p.isAbsolute(normalized) ||
        normalized == '..' ||
        normalized.startsWith('..${p.separator}')) {
      throw StateError('Vault transaction backup escapes its directory.');
    }
    final result = p.normalize(p.join(directory.path, normalized));
    if (!p.isWithin(p.normalize(directory.path), result)) {
      throw StateError('Vault transaction backup escapes its directory.');
    }
    return result;
  }

  String _nextBackupPath() {
    return p.join(_backups.path, _actions.length.toString().padLeft(6, '0'));
  }

  String _backupRelativePath(String absolutePath) {
    return p.relative(absolutePath, from: directory.path).replaceAll('\\', '/');
  }

  bool _isProtected(String relative) {
    if (_protectedPaths.contains(relative)) {
      return true;
    }
    for (final protected in _protectedPaths) {
      final action = _actions.lastWhere(
        (candidate) => candidate.path == protected,
      );
      if (action.type == _JournalActionType.delete &&
          p.isWithin(protected, relative)) {
        return true;
      }
    }
    return false;
  }
}

enum _JournalPhase { active, committed }

enum _JournalActionType { delete, restore, move }

final class _JournalAction {
  const _JournalAction._({
    required this.type,
    required this.path,
    this.backup,
    this.source,
    this.target,
  });

  const _JournalAction.delete(String path)
    : this._(type: _JournalActionType.delete, path: path);

  const _JournalAction.restore(String path, String backup)
    : this._(type: _JournalActionType.restore, path: path, backup: backup);

  const _JournalAction.move(String source, String target)
    : this._(
        type: _JournalActionType.move,
        path: target,
        source: source,
        target: target,
      );

  final _JournalActionType type;
  final String path;
  final String? backup;
  final String? source;
  final String? target;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type.name,
    'path': path,
    if (backup != null) 'backup': backup,
    if (source != null) 'source': source,
    if (target != null) 'target': target,
  };

  factory _JournalAction.fromJson(Map<String, Object?> json) {
    final type = _JournalActionType.values.byName(json['type']! as String);
    final path = json['path'];
    if (path is! String) {
      throw StateError('Vault transaction action path is invalid.');
    }
    return _JournalAction._(
      type: type,
      path: path,
      backup: json['backup'] as String?,
      source: json['source'] as String?,
      target: json['target'] as String?,
    );
  }
}

final class _VaultJournalMutex {
  Future<void> _tail = Future<void>.value();

  Future<_VaultJournalMutexLease> acquire() async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    return _VaultJournalMutexLease(release);
  }
}

final class _VaultJournalMutexLease {
  const _VaultJournalMutexLease(this._release);

  final Completer<void> _release;

  void release() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }
}

final class _VaultJournalLease {
  _VaultJournalLease(this._file, this._inProcessLease);

  final RandomAccessFile _file;
  final _VaultJournalMutexLease _inProcessLease;
  bool _released = false;

  Future<void> release() async {
    if (_released) {
      return;
    }
    _released = true;
    try {
      await _file.unlock();
    } finally {
      try {
        await _file.close();
      } finally {
        _inProcessLease.release();
      }
    }
  }
}
