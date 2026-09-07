import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/telemetry_controller.dart';
import 'package:dart_control_panel/telemetry/telemetry_sample.dart';

/// Realtime multi-series line chart for selected telemetry channels.
/// Pure CustomPainter: x = seconds back over the controller window, y =
/// blended min/max across visible channels; per-channel colors drawn in the
/// order of [TelemetryChannel.all]; latest values in the legend.
class TelemetryChart extends StatelessWidget {
  const TelemetryChart({super.key, required this.controller});

  final TelemetryController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final series = {
          for (final channel in TelemetryChannel.all)
            if (controller.selected.contains(channel.id))
              channel: controller.seriesFor(channel.id),
        };
        return CustomPaint(
          size: Size.infinite,
          painter: _ChartPainter(
            series: series,
            windowSeconds: controller.window.toDouble(),
          ),
        );
      },
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.series,
    required this.windowSeconds,
  });

  final Map<TelemetryChannel, List<TelemetryPoint>> series;
  final double windowSeconds;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 46.0;
    const bottomPad = 20.0;
    const topPad = 8.0;
    final plot = Rect.fromLTRB(leftPad, topPad, size.width - 8, size.height - bottomPad);

    // blended value range across selected channels
    var min = double.infinity;
    var max = double.negativeInfinity;
    var any = false;
    for (final points in series.values) {
      for (final p in points) {
        any = true;
        if (p.value < min) min = p.value;
        if (p.value > max) max = p.value;
      }
    }
    if (!any) {
      _drawLegend(canvas, size, min: 0, max: 1);
      _empty(canvas, plot);
      return;
    }
    final span = max - min;
    if (span < 1e-6) {
      min -= 1;
      max += 1;
    }
    final pad = (max - min) * 0.1;
    min -= pad;
    max += pad;

    _grid(canvas, plot, min, max);

    // x: seconds ago -> right-aligned at "now"
    double xFor(double seconds) => plot.right - (seconds / windowSeconds) * plot.width;

    double yFor(double v) => plot.bottom - ((v - min) / (max - min)) * plot.height;

    for (final entry in series.entries) {
      final channel = entry.key;
      final points = entry.value;
      if (points.isEmpty) continue;
      final paint = Paint()
        ..color = channel.color
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final o = Offset(xFor(points[i].seconds), yFor(points[i].value));
        if (i == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      canvas.drawPath(path, paint);
    }
    _drawLegend(canvas, size, min: min, max: max);
  }

  void _grid(Canvas canvas, Rect plot, double min, double max) {
    final gridPaint = Paint()
      ..color = const Color(0x22888888)
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final v = min + (max - min) * i / 3;
      final y = plot.bottom - ((v - min) / (max - min)) * plot.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: v.toStringAsFixed(v.abs() >= 100 ? 0 : 1),
          style: const TextStyle(color: Color(0xAAFFFFFF), fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plot.left - tp.width - 6, y - tp.height / 2));
    }
  }

  void _empty(Canvas canvas, Rect plot) {
    final tp = TextPainter(
      text: const TextSpan(
          text: 'no data',
          style: TextStyle(color: Color(0x88FFFFFF), fontSize: 12)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(
      plot.center.dx - tp.width / 2,
      plot.center.dy - tp.height / 2,
    ));
  }

  void _drawLegend(Canvas canvas, Size size, {required double min, required double max}) {
    final visible = series.entries.where((e) => e.value.isNotEmpty).toList();
    if (visible.isEmpty) return;
    var dx = 50.0;
    final baseline = 16.0;
    for (final entry in visible) {
      final channel = entry.key;
      final last = entry.value.last.value;
      final tp = TextPainter(
        text: TextSpan(
            text: '${channel.label} ${last.toStringAsFixed(1)}${channel.unit}',
            style: TextStyle(color: channel.color, fontSize: 11)),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.drawCircle(Offset(dx + 4, baseline - 3), 3, Paint()..color = channel.color);
      tp.paint(canvas, Offset(dx + 10, baseline - tp.height / 2));
      dx += tp.width + 22;
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) => true;
}