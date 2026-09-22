import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/telemetry_controller.dart';
import 'package:dart_control_panel/telemetry/telemetry_sample.dart';

/// Realtime multi-series chart with theme-aware numeric axes and highlighted
/// latest samples.
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
        final colors = Theme.of(context).colorScheme;
        return CustomPaint(
          size: Size.infinite,
          painter: _ChartPainter(
            series: series,
            windowSeconds: controller.window.toDouble(),
            axisColor: colors.onSurfaceVariant,
            gridColor: colors.outlineVariant,
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
    required this.axisColor,
    required this.gridColor,
  });

  final Map<TelemetryChannel, List<TelemetryPoint>> series;
  final double windowSeconds;
  final Color axisColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 48.0;
    const bottomPad = 24.0;
    const topPad = 22.0;
    final plot = Rect.fromLTRB(
      leftPad,
      topPad,
      size.width - 8,
      size.height - bottomPad,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    var min = double.infinity;
    var max = double.negativeInfinity;
    var any = false;
    for (final points in series.values) {
      for (final point in points) {
        any = true;
        if (point.value < min) min = point.value;
        if (point.value > max) max = point.value;
      }
    }
    if (!any) {
      _empty(canvas, plot);
      return;
    }
    if (max - min < 1e-6) {
      min -= 1;
      max += 1;
    }
    final padding = (max - min) * 0.1;
    min -= padding;
    max += padding;

    _grid(canvas, plot, min, max);
    _timeAxis(canvas, plot);
    double xFor(double seconds) =>
        plot.right - (seconds / windowSeconds) * plot.width;
    double yFor(double value) =>
        plot.bottom - ((value - min) / (max - min)) * plot.height;

    for (final entry in series.entries) {
      final channel = entry.key;
      final points = entry.value;
      if (points.isEmpty) continue;
      final linePaint = Paint()
        ..color = channel.color
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final offset = Offset(xFor(points[i].seconds), yFor(points[i].value));
        i == 0
            ? path.moveTo(offset.dx, offset.dy)
            : path.lineTo(offset.dx, offset.dy);
      }
      canvas.drawPath(path, linePaint);
      final last = points.last;
      canvas.drawCircle(
        Offset(xFor(last.seconds), yFor(last.value)),
        3.5,
        Paint()..color = channel.color,
      );
    }
    _drawLegend(canvas, size);
  }

  void _grid(Canvas canvas, Rect plot, double min, double max) {
    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.65)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final value = min + (max - min) * i / 4;
      final y = plot.bottom - ((value - min) / (max - min)) * plot.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      final label = TextPainter(
        text: TextSpan(
          text: value.toStringAsFixed(value.abs() >= 100 ? 0 : 1),
          style: TextStyle(color: axisColor, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(plot.left - label.width - 6, y - label.height / 2),
      );
    }
  }

  void _timeAxis(Canvas canvas, Rect plot) {
    for (var i = 0; i <= 4; i++) {
      final seconds = windowSeconds * (4 - i) / 4;
      final x = plot.left + plot.width * i / 4;
      final label = TextPainter(
        text: TextSpan(
          text: i == 4 ? 'now' : '-${seconds.toStringAsFixed(0)}s',
          style: TextStyle(color: axisColor, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(x - label.width / 2, plot.bottom + 4));
    }
  }

  void _empty(Canvas canvas, Rect plot) {
    final label = TextPainter(
      text: TextSpan(
        text: 'no data',
        style: TextStyle(color: axisColor, fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(
      canvas,
      Offset(
        plot.center.dx - label.width / 2,
        plot.center.dy - label.height / 2,
      ),
    );
  }

  void _drawLegend(Canvas canvas, Size size) {
    final visible = series.entries.where((entry) => entry.value.isNotEmpty);
    var dx = 50.0;
    const baseline = 12.0;
    for (final entry in visible) {
      final channel = entry.key;
      final value = entry.value.last.value;
      final label = TextPainter(
        text: TextSpan(
          text: '${channel.label} ${value.toStringAsFixed(1)}${channel.unit}',
          style: TextStyle(color: channel.color, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      if (dx + label.width + 12 > size.width) break;
      canvas.drawCircle(
        Offset(dx + 4, baseline),
        3,
        Paint()..color = channel.color,
      );
      label.paint(canvas, Offset(dx + 10, baseline - label.height / 2));
      dx += label.width + 22;
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) => true;
}
