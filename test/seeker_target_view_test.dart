import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/widgets/seeker_target_view.dart';

void main() {
  group('seekerTargetPoints', () {
    test('keeps only recent, found, finite points inside the real frame', () {
      final now = DateTime(2026, 9, 22, 12);
      TelemetrySample sample(
        int ageSeconds,
        double found,
        double x,
        double y,
      ) => TelemetrySample(
        time: now.subtract(Duration(seconds: ageSeconds)),
        values: {'found': found, 'target_x': x, 'target_y': y},
      );

      final points = seekerTargetPoints(
        samples: [
          sample(21, 1, 10, 10), // outside the time window
          sample(4, 0, 20, 20), // no target
          sample(3, 1, -1, 20), // outside the view
          sample(2, 1, 360, 20), // right edge is exclusive
          sample(1, 1, 120, 500),
        ],
        frameSize: const Size(360, 640),
        now: now,
        windowSeconds: 20,
      );

      expect(points, hasLength(1));
      expect(points.single.x, 120);
      expect(points.single.y, 500);
      expect(points.single.ageSeconds, 1);
    });

    test('retains sample order for oldest-to-newest fading', () {
      final now = DateTime(2026, 9, 22, 12);
      final points = seekerTargetPoints(
        samples: [
          TelemetrySample(
            time: now.subtract(const Duration(seconds: 10)),
            values: const {'found': 1, 'target_x': 1, 'target_y': 2},
          ),
          TelemetrySample(
            time: now.subtract(const Duration(seconds: 1)),
            values: const {'found': 1, 'target_x': 3, 'target_y': 4},
          ),
        ],
        frameSize: const Size(640, 360),
        now: now,
        windowSeconds: 20,
      );

      expect(points.map((point) => point.ageSeconds), [10, 1]);
    });
  });

  test('contained frame preserves portrait and landscape aspect ratios', () {
    final portrait = containedSeekerFrameRect(
      const Size.square(300),
      const Size(360, 640),
    );
    final landscape = containedSeekerFrameRect(
      const Size.square(300),
      const Size(640, 360),
    );

    expect(portrait.width / portrait.height, closeTo(360 / 640, 1e-9));
    expect(landscape.width / landscape.height, closeTo(640 / 360, 1e-9));
    expect(portrait.center, const Offset(150, 150));
    expect(landscape.center, const Offset(150, 150));
  });

  testWidgets('display viewport stays fixed when frame dimensions change', (
    tester,
  ) async {
    Future<Size> render(Size frameSize) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SeekerTargetView(
              samples: const [],
              frameSize: frameSize,
              windowSeconds: 20,
              now: DateTime(2026, 9, 22),
            ),
          ),
        ),
      );
      return tester.getSize(find.byType(SeekerTargetView));
    }

    expect(await render(const Size(640, 360)), const Size.square(300));
    expect(await render(const Size(360, 640)), const Size.square(300));
    expect(tester.takeException(), isNull);
  });
}
