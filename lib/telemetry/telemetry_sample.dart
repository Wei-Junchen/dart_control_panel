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

  static const pitch = TelemetryChannel(
    'pitch',
    'Pitch',
    '°',
    Color(0xFF4FC3F7),
  );
  static const roll = TelemetryChannel('roll', 'Roll', '°', Color(0xFFE57373));
  static const yaw = TelemetryChannel('yaw', 'Yaw', '°', Color(0xFF81C784));
  static const airSpeed = TelemetryChannel(
    'air_speed',
    'Air speed',
    'm/s',
    Color(0xFFFFD54F),
  );
  static const fps = TelemetryChannel('fps', 'FPS', 'fps', Color(0xFFBA68C8));
  static const detectFps = TelemetryChannel(
    'detect_fps',
    'Detect FPS',
    'fps',
    Color(0xFF9575CD),
  );
  static const processMs = TelemetryChannel(
    'process_ms',
    'Process',
    'ms',
    Color(0xFF7986CB),
  );
  static const targetX = TelemetryChannel(
    'target_x',
    'Target X',
    'px',
    Color(0xFF4DB6AC),
  );
  static const targetY = TelemetryChannel(
    'target_y',
    'Target Y',
    'px',
    Color(0xFF26A69A),
  );
  static const pixels = TelemetryChannel(
    'pixels',
    'Green pixels',
    '',
    Color(0xFF66BB6A),
  );
  static const brightness = TelemetryChannel(
    'brightness',
    'Brightness',
    '',
    Color(0xFFFFB74D),
  );
  static const pitchCmd = TelemetryChannel(
    'pitch_cmd',
    'Pitch cmd',
    '',
    Color(0xFF29B6F6),
  );
  static const yawCmd = TelemetryChannel(
    'yaw_cmd',
    'Yaw cmd',
    '',
    Color(0xFF9CCC65),
  );
  static const exposure = TelemetryChannel(
    'exposure_us',
    'Exposure',
    'us',
    Color(0xFFFF8A65),
  );
  static const luma = TelemetryChannel('luma', 'Luma', '', Color(0xFFBDBDBD));

  static const all = [
    pitch,
    roll,
    yaw,
    airSpeed,
    fps,
    detectFps,
    processMs,
    targetX,
    targetY,
    pixels,
    brightness,
    pitchCmd,
    yawCmd,
    exposure,
    luma,
  ];

  static TelemetryChannel? byId(String id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }
}
