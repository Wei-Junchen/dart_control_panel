import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Keeps feature-local code out of global buckets and prevents dependencies
/// from pointing back up into the application composition layer.
void main() {
  test('lib modules follow the documented dependency direction', () {
    final violations = <String>[];
    final importPattern = RegExp(
      r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
    );

    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.path.replaceAll('\\', '/');
      final sourceFeature = _featureOf(source);
      for (final line in file.readAsLinesSync()) {
        final uri = importPattern.firstMatch(line)?.group(1);
        if (uri == null) continue;
        if (uri.startsWith('.')) {
          violations.add('$source: use a package import for $uri');
          continue;
        }
        const prefix = 'package:dart_control_panel/';
        if (!uri.startsWith(prefix)) continue;
        final target = 'lib/${uri.substring(prefix.length)}';
        final targetFeature = _featureOf(target);
        if (sourceFeature != null &&
            targetFeature != null &&
            sourceFeature != targetFeature) {
          violations.add('$source: feature-to-feature import of $uri');
        }
        if (source.startsWith('lib/core/') &&
            (target.startsWith('lib/features/') ||
                target.startsWith('lib/shared/') ||
                target.startsWith('lib/app/'))) {
          violations.add('$source: core depends on $uri');
        }
        if (source.startsWith('lib/shared/') &&
            (target.startsWith('lib/features/') ||
                target.startsWith('lib/app/'))) {
          violations.add('$source: shared depends on $uri');
        }
        if (sourceFeature != null && target.startsWith('lib/app/')) {
          violations.add('$source: feature depends on $uri');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}

String? _featureOf(String path) {
  final parts = path.split('/');
  return parts.length >= 4 && parts[0] == 'lib' && parts[1] == 'features'
      ? parts[2]
      : null;
}
