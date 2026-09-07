import 'package:dart_control_panel/telemetry/telemetry_sample.dart';

/// A source of telemetry samples. The board does not expose a telemetry
/// interface yet — today only [DummyTelemetrySource] exists. When the daemon
/// adds one (e.g. over the 9000 control plane), implement this interface and
/// swap it in [TelemetryController] without touching the UI.
abstract class TelemetrySource {
  /// Start generating samples; [onSample] may be called from any thread.
  void start(void Function(TelemetrySample sample) onSample);

  Future<void> stop();

  String get label;
}

