import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'provider_config_store.dart';

abstract interface class LegacyPlaintextApiKeyFile {
  Future<bool> exists();

  Future<String> readAsString();

  Future<void> delete();
}

abstract interface class ApiKeyQuarantineMarker {
  Future<bool> exists();

  Future<void> mark();

  Future<void> clear();
}

final class _FileLegacyPlaintextApiKeyFile
    implements LegacyPlaintextApiKeyFile {
  _FileLegacyPlaintextApiKeyFile(this._file);

  final File _file;

  @override
  Future<void> delete() => _file.delete();

  @override
  Future<bool> exists() => _file.exists();

  @override
  Future<String> readAsString() => _file.readAsString();
}

final class _FileApiKeyQuarantineMarker implements ApiKeyQuarantineMarker {
  _FileApiKeyQuarantineMarker(this._file);

  final File _file;

  @override
  Future<void> clear() async {
    if (await _file.exists()) {
      await _file.delete();
    }
  }

  @override
  Future<bool> exists() => _file.exists();

  @override
  Future<void> mark() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString('reentry-required\n', flush: true);
  }
}

abstract interface class ApiKeyStoreLock {
  Future<ApiKeyStoreLockLease> acquire();
}

abstract interface class ApiKeyStoreLockLease {
  Future<void> release();
}

abstract interface class ApiKeyLockFileOpener {
  Future<ApiKeyLockFileHandle> open(File file);
}

abstract interface class ApiKeyLockFileHandle {
  Future<void> lock(FileLock mode);

  Future<void> unlock();

  Future<void> close();
}

final class _RandomAccessApiKeyLockFileOpener implements ApiKeyLockFileOpener {
  const _RandomAccessApiKeyLockFileOpener();

  @override
  Future<ApiKeyLockFileHandle> open(File file) async {
    return _RandomAccessApiKeyLockFileHandle(
      await file.open(mode: FileMode.append),
    );
  }
}

final class _RandomAccessApiKeyLockFileHandle implements ApiKeyLockFileHandle {
  _RandomAccessApiKeyLockFileHandle(this._file);

  final RandomAccessFile _file;

  @override
  Future<void> close() => _file.close();

  @override
  Future<void> lock(FileLock mode) => _file.lock(mode);

  @override
  Future<void> unlock() => _file.unlock();
}

final class _ApiKeyDirectoryLock implements ApiKeyStoreLock {
  _ApiKeyDirectoryLock(
    Directory configDirectory, {
    ApiKeyLockFileOpener fileOpener = const _RandomAccessApiKeyLockFileOpener(),
  }) : _fileOpener = fileOpener,
       _lockFile = File(p.join(configDirectory.path, 'provider_api_key.lock')),
       _mutex = _mutexes.putIfAbsent(
         p.normalize(p.absolute(configDirectory.path)),
         _InProcessMutex.new,
       );

  static final Map<String, _InProcessMutex> _mutexes =
      <String, _InProcessMutex>{};

  final File _lockFile;
  final ApiKeyLockFileOpener _fileOpener;
  final _InProcessMutex _mutex;

  @override
  Future<_ApiKeyLockLease> acquire() async {
    final inProcessLease = await _mutex.acquire();
    ApiKeyLockFileHandle? file;
    var acquired = false;
    try {
      await _lockFile.parent.create(recursive: true);
      file = await _fileOpener.open(_lockFile);
      await file.lock(FileLock.blockingExclusive);
      acquired = true;
      return _ApiKeyLockLease(file, inProcessLease);
    } catch (error, stackTrace) {
      Object failure = error;
      if (file != null) {
        try {
          await file.close();
        } catch (closeError) {
          failure = StateError(
            'API Key lock acquisition failed: $error; '
            'lock file close failed: $closeError',
          );
        }
      }
      Error.throwWithStackTrace(failure, stackTrace);
    } finally {
      if (!acquired) {
        inProcessLease.release();
      }
    }
  }
}

final class _InProcessMutex {
  Future<void> _tail = Future<void>.value();

  Future<_InProcessLockLease> acquire() async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    return _InProcessLockLease(release);
  }
}

final class _InProcessLockLease {
  _InProcessLockLease(this._release);

  final Completer<void> _release;

  void release() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }
}

final class _ApiKeyLockLease implements ApiKeyStoreLockLease {
  _ApiKeyLockLease(this._file, this._inProcessLease);

  final ApiKeyLockFileHandle _file;
  final _InProcessLockLease _inProcessLease;
  bool _released = false;

  @override
  Future<void> release() async {
    if (_released) {
      return;
    }
    _released = true;
    try {
      await _file.unlock();
    } catch (_) {
      // Closing the file also releases the operating-system lock.
    }
    try {
      await _file.close();
    } finally {
      _inProcessLease.release();
    }
  }
}

final class SecureApiKeyLoadResult {
  const SecureApiKeyLoadResult({
    required this.apiKey,
    this.recoveryMessage = '',
  });

  final String apiKey;
  final String recoveryMessage;
}

enum _SecureApiKeySaveState { active, committed, aborted }

final class SecureApiKeySaveTransaction {
  SecureApiKeySaveTransaction._(this._store, this._lockLease);

  final SecureApiKeyStore _store;
  final ApiKeyStoreLockLease _lockLease;
  _SecureApiKeySaveState _state = _SecureApiKeySaveState.active;

  Future<void> commit() async {
    if (_state != _SecureApiKeySaveState.active) {
      return;
    }
    try {
      await _store._clearQuarantine();
      _state = _SecureApiKeySaveState.committed;
    } catch (error) {
      _state = _SecureApiKeySaveState.aborted;
      await _store._abortStagedSave();
      throw StateError(_store._secureStorageErrorMessage('提交', error));
    } finally {
      await _lockLease.release();
    }
  }

  Future<void> abort() async {
    if (_state != _SecureApiKeySaveState.active) {
      return;
    }
    _state = _SecureApiKeySaveState.aborted;
    try {
      await _store._abortStagedSave();
    } finally {
      await _lockLease.release();
    }
  }
}

final class SecureApiKeyStore {
  SecureApiKeyStore({
    required Directory configDirectory,
    required SecureValueStore secureStore,
    LegacyPlaintextApiKeyFile? legacyPlaintextFile,
    ApiKeyQuarantineMarker? quarantineMarker,
    ApiKeyStoreLock? directoryLock,
    ApiKeyLockFileOpener? lockFileOpener,
  }) : _legacyPlaintextFile =
           legacyPlaintextFile ??
           _FileLegacyPlaintextApiKeyFile(
             File(p.join(configDirectory.path, 'provider_api_key.local.json')),
           ),
       _quarantineMarker =
           quarantineMarker ??
           _FileApiKeyQuarantineMarker(
             File(
               p.join(
                 configDirectory.path,
                 'provider_api_key.reentry_required',
               ),
             ),
           ),
       _directoryLock =
           directoryLock ??
           _ApiKeyDirectoryLock(
             configDirectory,
             fileOpener:
                 lockFileOpener ?? const _RandomAccessApiKeyLockFileOpener(),
           ),
       _secureStore = secureStore;

  static const storageKey = 'synapse.provider.apiKey';
  static const legacyRecoveryMessage = '旧 API Key 已删除，请重新输入';

  final LegacyPlaintextApiKeyFile _legacyPlaintextFile;
  final ApiKeyQuarantineMarker _quarantineMarker;
  final ApiKeyStoreLock _directoryLock;
  final SecureValueStore _secureStore;

  Future<SecureApiKeyLoadResult> load() async {
    final lockLease = await _acquireOrFailClosed();
    try {
      return await _loadLocked();
    } finally {
      await lockLease.release();
    }
  }

  Future<SecureApiKeyLoadResult> _loadLocked() async {
    late final bool quarantined;
    try {
      quarantined = await _quarantineMarker.exists();
    } catch (error) {
      await _failAfterQuarantineError('读取', error);
    }
    if (quarantined) {
      final deletionError = await _tryDeleteLegacyPlaintext();
      await _discardUnverifiedSecureApiKey();
      if (deletionError != null) {
        throw StateError(_legacyDeletionErrorMessage(deletionError));
      }
      return const SecureApiKeyLoadResult(
        apiKey: '',
        recoveryMessage: legacyRecoveryMessage,
      );
    }
    if (await _legacyPlaintextFile.exists()) {
      try {
        await _markQuarantine();
      } catch (error) {
        await _failAfterQuarantineError('写入', error);
      }
      return _migrateLegacyPlaintext();
    }
    return SecureApiKeyLoadResult(apiKey: await _readSecureApiKey());
  }

  Future<void> save(String apiKey) async {
    final transaction = await stageSave(apiKey);
    try {
      await transaction.commit();
    } catch (_) {
      await transaction.abort();
      rethrow;
    }
  }

  Future<SecureApiKeySaveTransaction> stageSave(String apiKey) async {
    final lockLease = await _acquireOrFailClosed();
    try {
      await _markQuarantine();
      await _deleteLegacyPlaintext();
      final normalized = apiKey.trim();
      if (normalized.isEmpty) {
        await _deleteSecureApiKey();
      } else {
        await _secureStore.write(key: storageKey, value: normalized);
        final verified = await _secureStore.read(key: storageKey);
        if (verified != normalized) {
          throw StateError('secure read verification mismatch');
        }
      }
      return SecureApiKeySaveTransaction._(this, lockLease);
    } catch (error) {
      await _bestEffortDeleteLegacyPlaintext();
      await _discardUnverifiedSecureApiKey();
      await lockLease.release();
      throw StateError(_secureStorageErrorMessage('保存', error));
    }
  }

  Future<void> _abortStagedSave() async {
    await _bestEffortDeleteLegacyPlaintext();
    await _discardUnverifiedSecureApiKey();
  }

  Future<ApiKeyStoreLockLease> _acquireOrFailClosed() async {
    try {
      return await _directoryLock.acquire();
    } catch (error) {
      await _bestEffortMarkQuarantine();
      final deletionError = await _tryDeleteLegacyPlaintext();
      await _discardUnverifiedSecureApiKey();
      final lockingError = StateError('API Key 存储加锁失败：$error');
      if (deletionError != null) {
        throw StateError(
          _legacyDeletionErrorMessage(deletionError, lockingError),
        );
      }
      throw StateError('API Key 存储加锁失败，未加载或修改任何 API Key：$error');
    }
  }

  Future<SecureApiKeyLoadResult> _migrateLegacyPlaintext() async {
    String? plaintextApiKey;
    try {
      final decoded = jsonDecode(await _legacyPlaintextFile.readAsString());
      if (decoded is! Map) {
        throw const FormatException('Legacy API Key JSON must be an object.');
      }
      final value = decoded['apiKey'];
      if (value is! String || value.isEmpty) {
        throw const FormatException(
          'Legacy API Key JSON must contain a non-empty string apiKey.',
        );
      }
      plaintextApiKey = value;
      await _secureStore.write(key: storageKey, value: plaintextApiKey);
      final verified = await _secureStore.read(key: storageKey);
      if (verified != plaintextApiKey) {
        throw StateError('secure read verification mismatch');
      }
    } catch (error) {
      final deletionError = await _tryDeleteLegacyPlaintext();
      if (plaintextApiKey != null) {
        await _discardUnverifiedSecureApiKey();
      }
      if (deletionError != null) {
        throw StateError(_legacyDeletionErrorMessage(deletionError, error));
      }
      return const SecureApiKeyLoadResult(
        apiKey: '',
        recoveryMessage: legacyRecoveryMessage,
      );
    }

    final deletionError = await _tryDeleteLegacyPlaintext();
    if (deletionError != null) {
      await _discardUnverifiedSecureApiKey();
      throw StateError(_legacyDeletionErrorMessage(deletionError));
    }
    try {
      await _clearQuarantine();
    } catch (error) {
      await _discardUnverifiedSecureApiKey();
      throw StateError(_secureStorageErrorMessage('迁移', error));
    }
    return SecureApiKeyLoadResult(apiKey: plaintextApiKey);
  }

  Future<Never> _failAfterQuarantineError(String action, Object error) async {
    await _bestEffortMarkQuarantine();
    final deletionError = await _tryDeleteLegacyPlaintext();
    await _discardUnverifiedSecureApiKey();
    if (deletionError != null) {
      throw StateError(_legacyDeletionErrorMessage(deletionError, error));
    }
    throw StateError('API Key 隔离状态$action失败，未加载任何 API Key：$error');
  }

  Future<void> _markQuarantine() async {
    try {
      await _quarantineMarker.mark();
    } catch (error) {
      throw StateError('API Key 隔离状态写入失败，未修改任何 API Key：$error');
    }
  }

  Future<void> _bestEffortMarkQuarantine() async {
    try {
      await _quarantineMarker.mark();
    } catch (_) {
      // No secure value is read or returned after quarantine setup fails.
    }
  }

  Future<void> _clearQuarantine() async {
    try {
      await _quarantineMarker.clear();
    } catch (error) {
      throw StateError('API Key 隔离状态清除失败：$error');
    }
  }

  Future<String> _readSecureApiKey() async {
    try {
      return await _secureStore.read(key: storageKey) ?? '';
    } catch (error) {
      throw StateError(_secureStorageErrorMessage('读取', error));
    }
  }

  Future<void> _deleteSecureApiKey() async {
    try {
      await _secureStore.delete(key: storageKey);
    } catch (error) {
      throw StateError(_secureStorageErrorMessage('清除', error));
    }
  }

  Future<void> _discardUnverifiedSecureApiKey() async {
    try {
      await _secureStore.delete(key: storageKey);
    } catch (_) {
      // The unverified value is never returned to the runtime.
    }
  }

  Future<void> _deleteLegacyPlaintext() async {
    if (await _legacyPlaintextFile.exists()) {
      await _legacyPlaintextFile.delete();
    }
  }

  Future<void> _bestEffortDeleteLegacyPlaintext() async {
    try {
      await _deleteLegacyPlaintext();
    } catch (_) {
      // The persistent quarantine still prevents either key from being used.
    }
  }

  Future<Object?> _tryDeleteLegacyPlaintext() async {
    try {
      await _deleteLegacyPlaintext();
      return null;
    } catch (error) {
      return error;
    }
  }

  String _legacyDeletionErrorMessage(
    Object deletionError, [
    Object? migrationError,
  ]) {
    final suffix = migrationError == null ? '' : '；迁移错误：$migrationError';
    return '旧 API Key 删除失败，未加载任何 API Key：$deletionError$suffix';
  }

  String _secureStorageErrorMessage(String action, Object error) {
    if (error is PlatformException) {
      final raw = [
        error.code,
        if (error.message != null) error.message,
      ].join('，');
      if (_isEntitlementError(error)) {
        return 'API Key $action系统安全存储失败：macOS 需要启用 Keychain Sharing 权限。'
            '请重新构建并启动应用后再试。原始错误：$raw';
      }
      return 'API Key $action系统安全存储失败：$raw';
    }
    return 'API Key $action系统安全存储失败：$error';
  }

  bool _isEntitlementError(PlatformException error) {
    return error.code == '-34018' ||
        (error.message?.toLowerCase().contains('entitlement') ?? false);
  }
}
