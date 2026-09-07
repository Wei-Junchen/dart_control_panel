import 'dart:async';
import 'dart:math' as math;

import 'package:dart_control_panel/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/telemetry/telemetry_source.dart';

/// Generates plausible dummy telemetry at [interval] (default 100 ms / 10 Hz):
/// slowly varying pitch/roll/yaw plus air speed and fps-like noise.
/// `ground` profile simulates a test bench (moderate maneuvers, fps matters);
/// `flight` profile simulates a mission envelope (bigger angles, higher
/// speed, video fps meaningless).
class DummyTelemetrySource implements TelemetrySource {
  DummyTelemetrySource({this.interval = const Duration(milliseconds: 100)});

  final Duration interval;
  final DateTime _epoch = DateTime.now();
  Timer? _timer;
  void Function(TelemetrySample)? _onSample;
  String _profile = 'ground';

  @override
  String get label => 'dummy (10 Hz)';

  /// Switches the simulated envelope ('ground' | 'flight'); driven by the
  /// board-reported mode once set_mode exists, locally usable today.
  void setProfile(String profile) {
    _profile = profile == 'flight' ? 'flight' : 'ground';
  }

  double _t() => DateTime.now().difference(_epoch).inMilliseconds / 1000.0;

  @override
  void start(void Function(TelemetrySample sample) onSample) {
    _onSample = onSample;
    _timer ??= Timer.periodic(interval, (_) => _emit());
  }

  void _emit() {
    final t = _t();
    final flight = _profile == 'flight';
    _onSample?.call(TelemetrySample(
      time: DateTime.now(),
      values: flight
          ? {
              'pitch': 22.0 * _sin(t, 0.9) + 6.0 * _sin(t, 2.4),
              'roll': 160.0 * _sin(t, 0.6),
              'yaw': 90.0 + 70.0 * _sin(t, 0.4),
              'air_speed': 45.0 + 8.0 * _sin(t, 0.5),
              'fps': double.nan, // no video in flight
            }
          : {
              'pitch': 8.0 * _sin(t, 0.7) + 2.0 * _sin(t, 2.1),
              'roll': 120.0 + 25.0 * _sin(t, 0.5),
              'yaw': 45.0 + 20.0 * _sin(t, 0.35),
              'air_speed': 18.0 + 2.5 * _sin(t, 0.3),
              'fps': 79.0 + 4.0 * _sin(t, 1.7),
            },
    ));
  }

  double _sin(double t, double freq) => math.sin(t * 2 * math.pi * freq);

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _onSample = null;
  }
}