import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/platform/default_vault_revealer_io.dart';

void main() {
  test('reveals an existing vault with open -R argument list', () async {
    final directory = await Directory.systemTemp.createTemp(
      'synapse-vault-reveal-',
    );
    addTearDown(() => directory.delete(recursive: true));
    String? executable;
    List<String>? arguments;
    final revealer = PlatformVaultRevealer(
      isMacOS: true,
      processRunner: (command, args) async {
        executable = command;
        arguments = args;
        return ProcessResult(1, 0, '', '');
      },
    );

    await revealer.reveal(directory.path);

    expect(executable, '/usr/bin/open');
    expect(arguments, ['-R', directory.path]);
  });

  test('rejects a missing vault path before starting Finder', () async {
    var processCalls = 0;
    final revealer = PlatformVaultRevealer(
      isMacOS: true,
      processRunner: (command, args) async {
        processCalls += 1;
        return ProcessResult(1, 0, '', '');
      },
    );

    await expectLater(
      revealer.reveal('/path/that/does/not/exist/synapse'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('仓库路径不存在'),
        ),
      ),
    );
    expect(processCalls, 0);
  });

  test('reports Finder as unsupported outside macOS', () async {
    final revealer = PlatformVaultRevealer(
      isMacOS: false,
      processRunner: (command, args) async => ProcessResult(1, 0, '', ''),
    );

    await expectLater(
      revealer.reveal('/vault'),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
