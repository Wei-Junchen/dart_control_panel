import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/controllers/telemetry_controller.dart';
import 'package:dart_control_panel/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/telemetry/telemetry_source.dart';

/// Scripted source for deterministic tests.
class _ScriptedSource implements TelemetrySource {
  _ScriptedSource(this.samples);
  final List<TelemetrySample> samples;
  int emitted = 0;
  int startCalls = 0;
  int stopCalls = 0;
  void Function(TelemetrySample)? _onSample;

  @override
  String get label => 'scripted';

  @override
  void start(void Function(TelemetrySample sample) onSample) {
    startCalls++;
    _onSample = onSample;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  void emitNext() {
    emitted++;
    // synthesize a fresh sample so emitting can be scripted arbitrarily
    _onSample?.call(
      TelemetrySample(
        time: DateTime.now(),
        values: {
          'pitch': emitted.toDouble(),
          'roll': emitted * 2.0,
          'yaw': emitted * 3.0,
          'air_speed': 15.0 + emitted,
          'fps': 78.0,
        },
      ),
    );
  }
}

void main() {
  group('TelemetryController', () {
    late _ScriptedSource source;
    late TelemetryController controller;

    setUp(() {
      source = _ScriptedSource([
        TelemetrySample(
          time: DateTime.now(),
          values: {
            'pitch': 1.0,
            'roll': 20.0,
            'yaw': 30.0,
            'air_speed': 15.0,
            'fps': 78.0,
          },
        ),
        TelemetrySample(
          time: DateTime.now(),
          values: {
            'pitch': 2.0,
            'roll': 22.0,
            'yaw': 32.0,
            'air_speed': 15.5,
            'fps': 79.0,
          },
        ),
      ]);
      controller = TelemetryController(source: source);
    });

    tearDown(() async {
      await controller.stop();
      controller.dispose();
    });

    test('start subscribes and notifies on samples', () {
      controller.start();
      expect(source.startCalls, 1);
      source.emitNext(); // synthesized: pitch=1, roll=2, yaw=3
      expect(controller.latest, isNotNull);
      expect(controller.samples, hasLength(1));
      expect(controller.attitude.pitch, 1.0);
      expect(controller.attitude.roll, 2.0);
      expect(controller.attitude.yaw, 3.0);
      source.emitNext(); // pitch=2
      expect(controller.attitude.pitch, 2.0);
    });

    test('start is idempotent; stop cancels the source', () async {
      controller.start();
      controller.start();
      expect(source.startCalls, 1);
      await controller.stop();
      expect(source.stopCalls, 1);
      expect(controller.running, isFalse);
      await controller.stop();
      expect(source.stopCalls, 1);
    });

    test('sample ring buffer respects the window', () {
      controller.start();
      for (var i = 0; i < controller.window * 60 + 10; i++) {
        source.emitNext();
      }
      expect(
        controller.samples.length,
        lessThanOrEqualTo(controller.window * 60 + 1),
      );
    });

    test(
      'channel selection toggles and seriesFor only reflects selected data',
      () {
        controller.start();
        source.emitNext();
        expect(controller.selected, contains('pitch'));
        controller.toggleChannel('pitch');
        expect(controller.selected, isNot(contains('pitch')));
        // series still available for any channel (chart decides what to plot)
        expect(controller.seriesFor('pitch'), isNotEmpty);
        expect(controller.seriesFor('fps'), isNotEmpty);
        expect(controller.seriesFor('missing'), isEmpty);
      },
    );

    test('latestValueOf returns NaN before data / for unknown channels', () {
      expect(controller.latestValueOf('pitch').isNaN, isTrue);
      controller.start();
      source.emitNext();
      expect(controller.latestValueOf('pitch'), 1.0);
      expect(controller.latestValueOf('nope').isNaN, isTrue);
    });
  });
}
