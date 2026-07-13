import 'dart:io';

import 'package:path/path.dart' as p;

abstract interface class ConfigFileWriter {
  Future<void> write(File target, String contents);
}

final class AtomicConfigFileWriter implements ConfigFileWriter {
  const AtomicConfigFileWriter();

  @override
  Future<void> write(File target, String contents) async {
    await target.parent.create(recursive: true);
    final temporary = File(
      p.join(
        target.parent.path,
        '.${p.basename(target.path)}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    try {
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(target.path);
    } catch (_) {
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }
}
