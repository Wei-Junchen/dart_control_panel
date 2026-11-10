import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';

/// Pluggable source of telemetry samples.
abstract class TelemetrySource {
  void start(void Function(TelemetrySample sample) onSample);
  Future<void> stop();
  String get label;
}
