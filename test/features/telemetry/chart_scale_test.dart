import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_chart.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';

class Push implements TelemetrySource {
  void Function(TelemetrySample)? receive;
  @override
  String get label => 'test';
  @override
  void start(void Function(TelemetrySample) f) {
    receive = f;
  }

  @override
  Future<void> stop() async {}
  void emit(double p) =>
      receive!(TelemetrySample(time: DateTime.now(), values: {'pitch': p}));
}

void main() {
  testWidgets('zero reference is dashed, not a solid grid line', (
    tester,
  ) async {
    final c = TelemetryController(source: Push());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TelemetryChart(controller: c)),
      ),
    );
    final dynamic painter = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('telemetry-chart-plot')))
        .painter;
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), const Size(800, 400));
    final picture = recorder.endRecording();
    await tester.runAsync(() async {
      final image = await picture.toImage(800, 400);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      int alpha(int x) => data!.getUint8((199 * 800 + x) * 4 + 3);
      expect(alpha(50), greaterThan(0));
      expect(alpha(55), 0);
      expect(alpha(60), greaterThan(0));
      image.dispose();
    });
    picture.dispose();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'Y bounds expand but do not contract; wheel manually zooms both ways',
    (tester) async {
      final source = Push();
      final c = TelemetryController(source: source)..start();
      source.emit(100);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TelemetryChart(controller: c)),
        ),
      );
      dynamic painter() => tester
          .widget<CustomPaint>(
            find
                .descendant(
                  of: find.byType(TelemetryChart),
                  matching: find.byKey(const ValueKey('telemetry-chart-plot')),
                )
                .first,
          )
          .painter;
      final largeMax = painter().yMax as double;
      c.clear();
      source.emit(1);
      await tester.pump();
      expect(painter().yMax, largeMax);
      source.emit(200);
      await tester.pump();
      expect(painter().yMax, greaterThan(largeMax));
      final before = (painter().yMax - painter().yMin) as double;
      final center = tester.getCenter(find.byType(TelemetryChart));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: center,
          scrollDelta: const Offset(0, -200),
        ),
      );
      await tester.pump();
      final zoomed = (painter().yMax - painter().yMin) as double;
      expect(zoomed, lessThan(before));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 200)),
      );
      await tester.pump();
      expect((painter().yMax - painter().yMin) as double, greaterThan(zoomed));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
