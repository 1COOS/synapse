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

final class SecureApiKeyLoadResult {
  const SecureApiKeyLoadResult({
    required this.apiKey,
    this.recoveryMessage = '',
  });

  final String apiKey;
  final String recoveryMessage;
}

final class SecureApiKeyStore {
  SecureApiKeyStore({
    required Directory configDirectory,
    required SecureValueStore secureStore,
    LegacyPlaintextApiKeyFile? legacyPlaintextFile,
  }) : _legacyPlaintextFile =
           legacyPlaintextFile ??
           _FileLegacyPlaintextApiKeyFile(
             File(p.join(configDirectory.path, 'provider_api_key.local.json')),
           ),
       _secureStore = secureStore;

  static const storageKey = 'synapse.provider.apiKey';
  static const legacyRecoveryMessage = '旧 API Key 已删除，请重新输入';

  final LegacyPlaintextApiKeyFile _legacyPlaintextFile;
  final SecureValueStore _secureStore;

  Future<SecureApiKeyLoadResult> load() async {
    if (await _legacyPlaintextFile.exists()) {
      return _migrateLegacyPlaintext();
    }
    return SecureApiKeyLoadResult(apiKey: await _readSecureApiKey());
  }

  Future<void> save(String apiKey) async {
    await _deleteLegacyPlaintext();
    final normalized = apiKey.trim();
    if (normalized.isEmpty) {
      await _deleteSecureApiKey();
      return;
    }

    try {
      await _secureStore.write(key: storageKey, value: normalized);
      final verified = await _secureStore.read(key: storageKey);
      if (verified != normalized) {
        throw StateError('secure read verification mismatch');
      }
    } catch (error) {
      await _discardUnverifiedSecureApiKey();
      throw StateError(_secureStorageErrorMessage('保存', error));
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
    return SecureApiKeyLoadResult(apiKey: plaintextApiKey);
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
