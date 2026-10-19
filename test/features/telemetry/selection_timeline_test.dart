import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_selection_timeline.dart';

void main() {
  testWidgets(
    'shared axis enforces ordering across multiple frames and coincident handles stay draggable',
    (tester) async {
      double start = 20, current = 50, end = 80;
      Widget timeline(StateSetter update) => TelemetrySelectionTimeline(
        duration: 100,
        start: start,
        current: current,
        end: end,
        onStart: (v) => update(() => start = v),
        onCurrent: (v) => update(() => current = v),
        onEnd: (v) => update(() => end = v),
        onCurrentStart: () {},
        onCurrentEnd: (_) {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                child: StatefulBuilder(
                  builder: (context, update) => timeline(update),
                ),
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(TelemetrySelectionTimeline));
      Offset at(double time, double y) =>
          Offset(rect.left + 18 + time / 100 * (rect.width - 36), rect.top + y);
      final play = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey('telemetry-history-slider')),
        ),
      );
      await play.moveTo(at(0, 34));
      await tester.pump();
      expect(current, start);
      await play.moveTo(at(100, 34));
      await tester.pump();
      expect(current, end);
      await play.moveTo(at(50, 34));
      await tester.pump();
      expect(current, closeTo(50, .01));
      await play.up();
      final from = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('telemetry-start-slider'))),
      );
      await from.moveTo(at(90, 14));
      await tester.pump();
      expect(start, current);
      await from.up();
      final to = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('telemetry-end-slider'))),
      );
      await to.moveTo(at(0, 54));
      await tester.pump();
      expect(end, current);
      await to.up();
      final reopen = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('telemetry-start-slider'))),
      );
      await reopen.moveTo(at(10, 14));
      await tester.pump();
      expect(start, closeTo(10, .01));
      await reopen.up();
      expect(start, lessThanOrEqualTo(current));
      expect(current, lessThanOrEqualTo(end));
      expect(tester.takeException(), isNull);
    },
  );
}
