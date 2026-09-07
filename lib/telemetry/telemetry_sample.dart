import 'dart:ui';

/// One telemetry measurement at [time]; `values` maps channel id → value.
class TelemetrySample {
  const TelemetrySample({required this.time, required this.values});

  final DateTime time;
  final Map<String, double> values;

  double valueOf(String channel) => values[channel] ?? double.nan;
}

/// Describes a telemetry channel for the UI (checkbox, color, unit).
class TelemetryChannel {
  const TelemetryChannel(this.id, this.label, this.unit, this.color);

  final String id;
  final String label;
  final String unit;
  final Color color;

  static const pitch = TelemetryChannel('pitch', 'Pitch', '°', Color(0xFF4FC3F7));
  static const roll = TelemetryChannel('roll', 'Roll', '°', Color(0xFFE57373));
  static const yaw = TelemetryChannel('yaw', 'Yaw', '°', Color(0xFF81C784));
  static const airSpeed =
      TelemetryChannel('air_speed', 'Air speed', 'm/s', Color(0xFFFFD54F));
  static const fps = TelemetryChannel('fps', 'FPS', 'fps', Color(0xFFBA68C8));

  static const all = [pitch, roll, yaw, airSpeed, fps];

  static TelemetryChannel? byId(String id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }
}