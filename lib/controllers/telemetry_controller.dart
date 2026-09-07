import 'package:flutter/foundation.dart';

import 'package:dart_control_panel/telemetry/dummy_telemetry_source.dart';
import 'package:dart_control_panel/telemetry/telemetry_source.dart';
import 'package:dart_control_panel/telemetry/telemetry_sample.dart';

/// A point for the chart: [seconds] = how far back in time (0 = now).
class TelemetryPoint {
  const TelemetryPoint(this.seconds, this.value);

  final double seconds;
  final double value;
}

/// Live telemetry hub: owns a [TelemetrySource] (dummy until the board has a
/// real interface), a time-capped sample ring buffer, and the set of charted
/// channels. Pure Dart + ChangeNotifier.
class TelemetryController extends ChangeNotifier {
  TelemetryController({TelemetrySource? source, this.window = 20})
      : _source = source ?? DummyTelemetrySource();

  /// Checked channels are plotted.
  static const defaultSelected = {'pitch', 'roll', 'yaw'};

  final TelemetrySource _source;
  final int window; // seconds of history kept/plotted
  final List<TelemetrySample> _samples = [];
  final Set<String> _selected = {...defaultSelected};
  bool _running = false;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  TelemetrySource get source => _source;
  bool get running => _running;
  Set<String> get selected => Set.unmodifiable(_selected);

  List<TelemetrySample> get samples => List.unmodifiable(_samples);

  /// Latest sample (drives the 3D attitude view); null before the first tick.
  TelemetrySample? get latest =>
      _samples.isEmpty ? null : _samples.last;

  /// pitch/roll/yaw in degrees from the latest sample (NaN when missing).
  ({double pitch, double roll, double yaw}) get attitude {
    final s = latest;
    return (
      pitch: s?.valueOf('pitch') ?? double.nan,
      roll: s?.valueOf('roll') ?? double.nan,
      yaw: s?.valueOf('yaw') ?? double.nan,
    );
  }

  void start() {
    if (_running || _disposed) return;
    _running = true;
    _source.start(_onSample);
    _notify();
  }

  Future<void> stop() async {
    if (!_running || _disposed) return;
    _running = false;
    await _source.stop();
    _notify();
  }

  void toggleChannel(String channel) {
    if (_disposed) return;
    if (!_selected.remove(channel)) {
      _selected.add(channel);
    }
    _notify();
  }

  /// Ground/flight envelope for the dummy source; wired to the board mode
  /// (see update.md) once the board implements set_mode.
  void setModeProfile(String mode) {
    final source = _source;
    if (source is DummyTelemetrySource) {
      source.setProfile(mode);
    }
  }

  void _onSample(TelemetrySample sample) {
    _samples.add(sample);
    final cutoff = DateTime.now().subtract(Duration(seconds: window));
    // trim: keep at most one second beyond the window
    while (_samples.isNotEmpty &&
        (_samples.first.time.isBefore(cutoff) ||
            _samples.length > window * 60)) {
      _samples.removeAt(0);
    }
    _notify();
  }

  /// Series for [channel] over the visible window, oldest first.
  List<TelemetryPoint> seriesFor(String channel) {
    final now = DateTime.now();
    final result = <TelemetryPoint>[];
    for (final s in _samples) {
      final seconds = now.difference(s.time).inMilliseconds / 1000.0;
      if (seconds > window) continue;
      final value = s.valueOf(channel);
      if (value.isNaN || value.isInfinite) continue;
      result.add(TelemetryPoint(seconds, value));
    }
    return result;
  }

  /// Latest value of [channel] for the checkbox legend (NaN when absent).
  double latestValueOf(String channel) =>
      latest?.valueOf(channel) ?? double.nan;

  @override
  void dispose() {
    _disposed = true;
    _source.stop();
    super.dispose();
  }
}