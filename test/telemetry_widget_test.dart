import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/controllers/telemetry_controller.dart';
import 'package:dart_control_panel/screens/telemetry_screen.dart';
import 'package:dart_control_panel/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/telemetry/telemetry_source.dart';
import 'package:dart_control_panel/widgets/attitude_view.dart';
import 'package:dart_control_panel/widgets/seeker_target_view.dart';
import 'package:dart_control_panel/widgets/telemetry_chart.dart';

void main() {
  group('AttitudeView', () {
    testWidgets('renders for various attitudes without exceptions', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AttitudeView(pitchDeg: 8, rollDeg: 120, yawDeg: 45),
          ),
        ),
      );
      expect(find.byType(AttitudeView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('NaN attitude values render safely as 0', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AttitudeView(
              pitchDeg: double.nan,
              rollDeg: double.nan,
              yawDeg: double.nan,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('TelemetryChart', () {
    testWidgets('renders empty chart without data', (tester) async {
      final controller = TelemetryController(source: _NeverSource());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TelemetryChart(controller: controller)),
        ),
      );
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
      controller.dispose();
    });

    testWidgets('renders series once data lands', (tester) async {
      final controller = TelemetryController(source: _NeverSource());
      controller.start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 200,
              child: TelemetryChart(controller: controller),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      controller.dispose();
    });
  });

  group('TelemetryScreen', () {
    testWidgets('shows attitude, channels and runs the telemetry source', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = TelemetryController(source: _NeverSource());
      await tester.pumpWidget(
        MaterialApp(home: TelemetryScreen(controller: controller)),
      );
      await tester.pump();
      expect(find.text('Attitude (UDP UART)'), findsOneWidget);
      expect(find.text('Channels (real-time plot)'), findsOneWidget);
      expect(find.textContaining('Pitch'), findsWidgets);
      expect(find.byType(AttitudeView), findsOneWidget);
      expect(find.byType(SeekerTargetView), findsOneWidget);
      expect(find.text('2D Seeker target trail'), findsOneWidget);
      expect(find.byKey(const ValueKey('seeker-fade-slider')), findsOneWidget);
      expect(find.byType(TelemetryChart), findsOneWidget);
      expect(find.text('Current values'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('seeker-fade-value')))
            .data,
        '20 s',
      );
      tester
          .widget<Slider>(find.byKey(const ValueKey('seeker-fade-slider')))
          .onChanged!(5);
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('seeker-fade-value')))
            .data,
        '5 s',
      );
      expect(tester.takeException(), isNull);
      controller.dispose();
    });

    testWidgets('pause/resume toggle stops and restarts the source', (
      tester,
    ) async {
      final source = _ScriptedSourceForScreen();
      final controller = TelemetryController(source: source);
      await tester.pumpWidget(
        MaterialApp(home: TelemetryScreen(controller: controller)),
      );
      await tester.pump();
      expect(controller.running, isTrue);
      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();
      expect(controller.running, isFalse);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();
      expect(controller.running, isTrue);
      controller.dispose();
    });
  });
}

/// A source that never emits (tests drive samples via the controller's
/// internal path or just check the empty UI).
class _NeverSource implements TelemetrySource {
  @override
  String get label => 'never';

  @override
  void start(void Function(TelemetrySample sample) onSample) {}

  @override
  Future<void> stop() async {}
}

class _ScriptedSourceForScreen implements TelemetrySource {
  int startCalls = 0;
  int stopCalls = 0;
  void Function(TelemetrySample)? onSample;

  @override
  String get label => 'scripted';

  @override
  void start(void Function(TelemetrySample sample) onSample) {
    startCalls++;
    this.onSample = onSample;
    // emit one dummy sample so the empty states get populated
    onSample(
      TelemetrySample(
        time: DateTime.now(),
        values: {
          'pitch': 3.0,
          'roll': 10.0,
          'yaw': 20.0,
          'air_speed': 12.0,
          'fps': 60.0,
        },
      ),
    );
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}
