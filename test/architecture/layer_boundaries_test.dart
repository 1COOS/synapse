import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('application and domain layers do not depend on infrastructure', () {
    final violations = <String>[];

    for (final root in ['lib/application', 'lib/domain']) {
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        final lines = entity.readAsLinesSync();
        for (var index = 0; index < lines.length; index += 1) {
          final line = lines[index].trimLeft();
          final isDirective =
              line.startsWith('import ') || line.startsWith('export ');
          if (isDirective && line.contains('infrastructure/')) {
            violations.add('${entity.path}:${index + 1}: ${line.trim()}');
          }
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
