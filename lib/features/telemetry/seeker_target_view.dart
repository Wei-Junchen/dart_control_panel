import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';

/// One valid target observation in the board's post-crop, post-rotation view
/// coordinate system.
class SeekerTargetPoint {
  const SeekerTargetPoint({
    required this.x,
    required this.y,
    required this.ageSeconds,
  });

  final double x;
  final double y;
  final double ageSeconds;
}

/// Extracts the target trail from UDP samples.
///
/// Samples outside [windowSeconds], frames without a target, malformed values,
/// and coordinates outside [frameSize] are intentionally ignored. The result
/// remains oldest-first so that newer, stronger points can be painted last.
List<SeekerTargetPoint> seekerTargetPoints({
  required Iterable<TelemetrySample> samples,
  required Size frameSize,
  required DateTime now,
  required double windowSeconds,
}) {
  if (frameSize.width <= 0 || frameSize.height <= 0 || windowSeconds <= 0) {
    return const [];
  }

  final result = <SeekerTargetPoint>[];
  for (final sample in samples) {
    if (sample.valueOf('found') != 1) continue;
    final x = sample.valueOf('target_x');
    final y = sample.valueOf('target_y');
    if (!x.isFinite || !y.isFinite) continue;

    final age = now.difference(sample.time).inMicroseconds / 1000000.0;
    if (age < 0 || age > windowSeconds) continue;
    if (x < 0 || y < 0 || x >= frameSize.width || y >= frameSize.height) {
      continue;
    }
    result.add(SeekerTargetPoint(x: x, y: y, ageSeconds: age));
  }
  return result;
}

/// Fits the real view-coordinate aspect ratio into a stable display viewport.
/// Letterboxing is preferred over stretching so target geometry is not warped.
Rect containedSeekerFrameRect(Size viewport, Size frameSize) {
  if (viewport.isEmpty || frameSize.isEmpty) return Rect.zero;
  const inset = 10.0;
  final available = Size(
    math.max(0, viewport.width - inset * 2),
    math.max(0, viewport.height - inset * 2),
  );
  if (available.isEmpty) return Rect.zero;

  final scale = math.min(
    available.width / frameSize.width,
    available.height / frameSize.height,
  );
  final fitted = Size(frameSize.width * scale, frameSize.height * scale);
  return Rect.fromLTWH(
    (viewport.width - fitted.width) / 2,
    (viewport.height - fitted.height) / 2,
    fitted.width,
    fitted.height,
  );
}

/// Fixed-size 2D seeker display.
///
/// [frameSize] is the board's actual `worker.view.output`; it only changes the
/// letterboxed coordinate plane, never this widget's external dimensions.
class SeekerTargetView extends StatelessWidget {
  const SeekerTargetView({
    super.key,
    required this.samples,
    required this.frameSize,
    required this.windowSeconds,
    this.now,
  });

  /// Stable UI size across readout/profile/rotation changes.
  static const viewportExtent = 300.0;

  final List<TelemetrySample> samples;
  final Size frameSize;
  final double windowSeconds;

  /// Injectable clock for deterministic tests.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final points = seekerTargetPoints(
      samples: samples,
      frameSize: frameSize,
      now: now ?? DateTime.now(),
      windowSeconds: windowSeconds,
    );
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: viewportExtent,
        child: CustomPaint(
          key: const ValueKey('seeker-target-canvas'),
          painter: _SeekerTargetPainter(
            points: points,
            frameSize: frameSize,
            windowSeconds: windowSeconds,
            background: colors.surfaceContainerLowest,
            grid: colors.outlineVariant,
            target: colors.primary,
          ),
        ),
      ),
    );
  }
}

class _SeekerTargetPainter extends CustomPainter {
  const _SeekerTargetPainter({
    required this.points,
    required this.frameSize,
    required this.windowSeconds,
    required this.background,
    required this.grid,
    required this.target,
  });

  final List<SeekerTargetPoint> points;
  final Size frameSize;
  final double windowSeconds;
  final Color background;
  final Color grid;
  final Color target;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = containedSeekerFrameRect(size, frameSize);
    if (frame.isEmpty) return;

    canvas.drawRRect(
      RRect.fromRectAndRadius(frame, const Radius.circular(4)),
      Paint()..color = background,
    );
    final gridPaint = Paint()
      ..color = grid.withValues(alpha: 0.48)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final x = frame.left + frame.width * i / 4;
      final y = frame.top + frame.height * i / 4;
      canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), gridPaint);
      canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), gridPaint);
    }
    canvas.drawRect(
      frame,
      Paint()
        ..color = grid.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    final center = frame.center;
    final crossPaint = Paint()
      ..color = grid.withValues(alpha: 0.9)
      ..strokeWidth = 1.2;
    canvas.drawLine(
      Offset(center.dx - 8, center.dy),
      Offset(center.dx + 8, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - 8),
      Offset(center.dx, center.dy + 8),
      crossPaint,
    );

    Offset project(SeekerTargetPoint point) => Offset(
      frame.left + point.x / frameSize.width * frame.width,
      frame.top + point.y / frameSize.height * frame.height,
    );

    // Paint oldest first. Strength grows non-linearly towards the newest point,
    // making old observations fade out naturally at the time-window boundary.
    Offset? previous;
    SeekerTargetPoint? previousPoint;
    for (final point in points) {
      final freshness = (1 - point.ageSeconds / windowSeconds).clamp(0.0, 1.0);
      final strength = math.pow(freshness, 1.6).toDouble();
      final position = project(point);
      // Do not bridge a period where target detection was lost.
      if (previous != null &&
          previousPoint!.ageSeconds - point.ageSeconds <= 0.25) {
        canvas.drawLine(
          previous,
          position,
          Paint()
            ..color = target.withValues(alpha: strength * 0.32)
            ..strokeWidth = 1 + strength,
        );
      }
      canvas.drawCircle(
        position,
        1.3 + strength * 2.7,
        Paint()..color = target.withValues(alpha: strength * 0.94),
      );
      previous = position;
      previousPoint = point;
    }

    if (points.isNotEmpty) {
      final newestPoint = points.last;
      final newest = project(newestPoint);
      final freshness = (1 - newestPoint.ageSeconds / windowSeconds).clamp(
        0.0,
        1.0,
      );
      final marker = target.withValues(
        alpha: math.pow(freshness, 1.6).toDouble(),
      );
      canvas.drawCircle(
        newest,
        7,
        Paint()
          ..color = marker
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      canvas.drawLine(
        Offset(newest.dx - 10, newest.dy),
        Offset(newest.dx + 10, newest.dy),
        Paint()
          ..color = marker
          ..strokeWidth = 1,
      );
      canvas.drawLine(
        Offset(newest.dx, newest.dy - 10),
        Offset(newest.dx, newest.dy + 10),
        Paint()
          ..color = marker
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SeekerTargetPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.frameSize != frameSize ||
      oldDelegate.windowSeconds != windowSeconds ||
      oldDelegate.background != background ||
      oldDelegate.grid != grid ||
      oldDelegate.target != target;
}
