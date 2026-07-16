import 'package:unorm_dart/unorm_dart.dart' as unorm;

enum VaultResourceNameIssue {
  empty,
  trailingWhitespace,
  trailingDot,
  relativePath,
  invalidCharacter,
  reservedName,
}

final class VaultResourceNameValidation {
  const VaultResourceNameValidation.valid() : issue = null, message = null;

  const VaultResourceNameValidation.invalid(this.issue, this.message);

  final VaultResourceNameIssue? issue;
  final String? message;

  bool get isValid => issue == null;
}

VaultResourceNameValidation validateVaultResourceName(String value) {
  if (value.isEmpty || value.trim().isEmpty) {
    return const VaultResourceNameValidation.invalid(
      VaultResourceNameIssue.empty,
      '名称不能为空。',
    );
  }
  if (RegExp(r'\s$').hasMatch(value)) {
    return const VaultResourceNameValidation.invalid(
      VaultResourceNameIssue.trailingWhitespace,
      '名称不能以空格结尾。',
    );
  }
  if (value == '.' || value == '..') {
    return const VaultResourceNameValidation.invalid(
      VaultResourceNameIssue.relativePath,
      '名称不能是 . 或 ..。',
    );
  }
  if (value.endsWith('.')) {
    return const VaultResourceNameValidation.invalid(
      VaultResourceNameIssue.trailingDot,
      '名称不能以句点结尾。',
    );
  }
  if (RegExp(r'[<>:"/\\|?*\x00-\x1F\x7F-\x9F]').hasMatch(value)) {
    return const VaultResourceNameValidation.invalid(
      VaultResourceNameIssue.invalidCharacter,
      '名称包含文件系统不支持的字符。',
    );
  }
  final base = value.split('.').first.toUpperCase();
  if (_windowsReservedNames.contains(base)) {
    return const VaultResourceNameValidation.invalid(
      VaultResourceNameIssue.reservedName,
      '该名称是系统保留名称，请使用其他名称。',
    );
  }
  return const VaultResourceNameValidation.valid();
}

String requireValidVaultResourceName(String value) {
  final validation = validateVaultResourceName(value);
  if (!validation.isValid) {
    throw VaultResourceNameValidationException(
      value: value,
      validation: validation,
    );
  }
  return value;
}

String canonicalVaultResourceName(String value) {
  return unorm.nfc(value).toLowerCase();
}

final class VaultResourceNameValidationException implements Exception {
  const VaultResourceNameValidationException({
    required this.value,
    required this.validation,
  });

  final String value;
  final VaultResourceNameValidation validation;

  @override
  String toString() => validation.message ?? 'Invalid resource name: $value';
}

final class VaultResourceNameConflictException implements Exception {
  const VaultResourceNameConflictException(this.name);

  final String name;

  @override
  String toString() => '同一文件夹中已存在名为“$name”的资源。';
}

const _windowsReservedNames = <String>{
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};
