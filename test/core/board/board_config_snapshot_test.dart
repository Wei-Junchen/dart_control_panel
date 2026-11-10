import 'dart:io';

import 'package:dart_control_panel/core/board/session/board_config_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'archives separate snapshots including unknown device without trusting malformed files',
    () async {
      final temp = await Directory.systemTemp.createTemp('board-config-test-');
      try {
        BoardConfigSnapshot snapshot(int second) => BoardConfigSnapshot(
          config: {
            'detector': {'green_y_min': second},
          },
          capturedAt: DateTime.utc(2026, 1, 1, 0, 0, second),
          host: 'board',
          port: 9000,
        );
        final first = await snapshot(1).archive(root: temp);
        final second = await snapshot(2).archive(root: temp);
        expect(first.path, contains('/_unknown/'));
        expect(first.path, isNot(second.path));
        expect(
          (await BoardConfigSnapshot.read(
            first,
          ))?.config['detector']['green_y_min'],
          1,
        );
        expect(
          (await BoardConfigSnapshot.read(
            second,
          ))?.config['detector']['green_y_min'],
          2,
        );
        await first.writeAsString('{broken');
        expect(await BoardConfigSnapshot.read(first), isNull);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}
