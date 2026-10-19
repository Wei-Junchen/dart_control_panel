import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:dart_control_panel/shared/widgets/mobile_ui_scale.dart';

import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';

/// Realtime multi-series chart with theme-aware numeric axes and highlighted
/// latest samples.
class TelemetryChart extends StatefulWidget {
  const TelemetryChart({super.key, required this.controller});

  final TelemetryController controller;

  @override
  State<TelemetryChart> createState() => _TelemetryChartState();
}

class _TelemetryChartState extends State<TelemetryChart> {
  double? _min, _max;
  int? _seriesKey;
  int? _capturedLiveRevision;
  Map<TelemetryChannel, List<TelemetryPoint>> _cachedSeries = {};
  bool _manualScale = false;
  int? _archiveOpenRevision;
  Offset? _hover;
  Size _size = Size.zero;
  int? _queuedCenter;
  double? _queuedWindow;
  Offset? _middleAnchor, _lastMiddle;
  int _queuedEpoch = 0;
  bool _navigating = false;
  double _gestureCenter = 0, _gestureWindow = 20;
  double _gestureMin = -1, _gestureMax = 1;
  Offset _lastFocal = Offset.zero;
  TelemetryController get controller => widget.controller;
  Rect get _plot => Rect.fromLTRB(48, 22, _size.width - 8, _size.height - 24);
  double get _right => controller.chartRightUs / 1000000.0;
  double get _center => controller.replaying
      ? (controller.chartFocusUs ?? controller.cursorUs).toDouble()
      : controller.chartRightUs - controller.chartWindow * 500000.0;

  void _navigate(int center, [double? window]) {
    _queuedCenter = center;
    _queuedEpoch = controller.chartNavigationEpoch;
    _queuedWindow = window ?? _queuedWindow;
    if (_navigating) return;
    _navigating = true;
    unawaited(() async {
      try {
        while (mounted && _queuedCenter != null) {
          if (_queuedEpoch != controller.chartNavigationEpoch) {
            _queuedCenter = null;
            _queuedWindow = null;
            break;
          }
          final center = _queuedCenter!;
          final window = _queuedWindow;
          _queuedCenter = null;
          _queuedWindow = null;
          await controller.inspectChart(
            centerUs: center,
            windowSeconds: window,
          );
        }
      } finally {
        _navigating = false;
      }
    }());
  }

  void _zoomY(double factor, [double ratio = .5]) {
    final min = _min ?? -1, max = _max ?? 1;
    final anchor = max - ratio * (max - min);
    final span = ((max - min) * factor).clamp(1e-6, 1e12);
    setState(() {
      _min = anchor - (1 - ratio) * span;
      _max = anchor + ratio * span;
      _manualScale = true;
    });
  }

  double _zoomX(double factor, [double ratio = .5]) {
    final old = controller.chartWindow;
    final next = (old * factor).clamp(.001, 3600).toDouble();
    final right = _right;
    final anchor = right - old * (1 - ratio);
    _navigate(((anchor + (.5 - ratio) * next) * 1e6).round(), next);
    return next / old;
  }

  void _zoomTogether(double factor, Offset position) {
    final plot = _plot;
    final keys = HardwareKeyboard.instance;
    if (!keys.isShiftPressed) {
      factor = _zoomX(
        factor,
        ((position.dx - plot.left) / plot.width).clamp(0, 1),
      );
    }
    if (!keys.isControlPressed) {
      _zoomY(factor, ((position.dy - plot.top) / plot.height).clamp(0, 1));
    }
  }

  void _resetY() => setState(() {
    _min = _max = null;
    _manualScale = false;
  });

  Widget _button(String label, String hint, VoidCallback action) => Tooltip(
    message: hint,
    child: TextButton(
      key: ValueKey('chart-$label'),
      onPressed: action,
      style: TextButton.styleFrom(
        minimumSize: const Size(36, 30),
        padding: const EdgeInsets.symmetric(horizontal: 7),
      ),
      child: Text(label),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (_archiveOpenRevision != controller.archiveOpenRevision) {
        _archiveOpenRevision = controller.archiveOpenRevision;
        _manualScale = false;
        _min = _max = null;
        _hover = null;
      }
      if (controller.followingLatest &&
          _capturedLiveRevision != controller.chartDataRevision) {
        controller.captureLiveChartFrame();
        _capturedLiveRevision = controller.chartDataRevision;
      }
      final columns = (_size.width > 56 ? _size.width - 56 : 1024)
          .round()
          .clamp(64, 2048);
      final key = Object.hash(
        controller.replaying,
        controller.replaying
            ? Object.hash(controller.archive, controller.chartViewRevision)
            : controller.chartDataRevision,
        controller.replaying ? controller.chartRightUs : 0,
        controller.replaying ? controller.cursorUs : 0,
        controller.selected.join('|'),
        controller.chartWindow,
        columns,
      );
      final changed = key != _seriesKey;
      if (changed) {
        _cachedSeries = {
          for (final channel in controller.channels)
            if (controller.selected.contains(channel.id))
              channel: controller.seriesFor(channel.id, maxPoints: columns * 4),
        };
        _seriesKey = key;
      }
      final series = _cachedSeries;
      if (!_manualScale && (changed || _min == null || _max == null)) {
        for (final points in series.values) {
          for (final point in points) {
            final padding = math.max(point.value.abs() * .05, 1.0);
            _min = math.min(_min ?? double.infinity, point.value - padding);
            _max = math.max(
              _max ?? double.negativeInfinity,
              point.value + padding,
            );
          }
        }
      }
      final colors = Theme.of(context).colorScheme;
      return Column(
        children: [
          SizedBox(
            height: MobileUiScale.isHandset(context) ? 28 : 34,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _button('X+', '时间轴放大', () => _zoomX(.8)),
                  _button('X−', '时间轴缩小', () => _zoomX(1.25)),
                  _button('Y+', '数值轴放大', () => _zoomY(.8)),
                  _button('Y−', '数值轴缩小', () => _zoomY(1.25)),
                  _button('适配Y', '按当前窗口重新适配 Y 轴；之后只自动扩大', _resetY),
                  _button('全览', '查看完整会话', () {
                    final duration = controller.timelineDurationUs;
                    _resetY();
                    _navigate(
                      duration ~/ 2,
                      (duration / 1e6).clamp(.001, 3600).toDouble(),
                    );
                  }),
                  Tooltip(
                    message:
                        '左键拖动平移 · 中键拖动/滚轮等比缩放 XY · Ctrl 仅 X · Shift 仅 Y · 双击适配 Y · 双指缩放',
                    child: Text(
                      '   ${controller.chartWindow.toStringAsFixed(controller.chartWindow < 1 ? 3 : 1)}s  ⓘ',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _size = constraints.biggest;
                final plot = _plot;
                controller.setChartPixelWidth(plot.width);
                final hover = _hover != null && plot.contains(_hover!)
                    ? _hover
                    : null;
                final secondsBack = hover == null
                    ? 0.0
                    : (plot.right - hover.dx) /
                          plot.width *
                          controller.chartWindow;
                final hoverText = <String>[];
                if (hover != null) {
                  final time = controller.replaying
                      ? _right - secondsBack
                      : controller.timelineDurationUs / 1e6 - secondsBack;
                  hoverText.add(
                    't = ${time.toStringAsFixed(controller.chartWindow < 1 ? 6 : 3)} s',
                  );
                  for (final entry in series.entries) {
                    if (entry.value.isEmpty) continue;
                    var nearest = entry.value.first;
                    for (final point in entry.value) {
                      if ((point.seconds - secondsBack).abs() <
                          (nearest.seconds - secondsBack).abs()) {
                        nearest = point;
                      }
                    }
                    hoverText.add(
                      '${entry.key.label}: ${nearest.value.toStringAsPrecision(6)}${entry.key.unit}',
                    );
                  }
                }
                return MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  onHover: (event) =>
                      setState(() => _hover = event.localPosition),
                  onExit: (_) => setState(() => _hover = null),
                  child: Listener(
                    onPointerDown: (event) {
                      if (event.buttons & kMiddleMouseButton != 0 &&
                          plot.contains(event.localPosition)) {
                        _middleAnchor = _lastMiddle = event.localPosition;
                      }
                    },
                    onPointerMove: (event) {
                      if (_middleAnchor == null ||
                          _lastMiddle == null ||
                          event.buttons & kMiddleMouseButton == 0) {
                        return;
                      }
                      final delta = event.localPosition - _lastMiddle!;
                      _zoomTogether(
                        math.exp(
                          (delta.distance *
                                      (delta.dy != 0
                                          ? delta.dy.sign
                                          : delta.dx.sign))
                                  .clamp(-200, 200) /
                              300,
                        ),
                        _middleAnchor!,
                      );
                      _lastMiddle = event.localPosition;
                    },
                    onPointerUp: (_) {
                      _middleAnchor = _lastMiddle = null;
                    },
                    onPointerCancel: (_) {
                      _middleAnchor = _lastMiddle = null;
                    },
                    onPointerSignal: (event) {
                      if (event is! PointerScrollEvent ||
                          !plot.contains(event.localPosition)) {
                        return;
                      }
                      GestureBinding.instance.pointerSignalResolver.register(
                        event,
                        (_) {
                          _zoomTogether(
                            math.exp(
                              event.scrollDelta.dy.clamp(-200, 200) / 500,
                            ),
                            event.localPosition,
                          );
                        },
                      );
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onDoubleTap: _resetY,
                      onLongPressStart: (event) =>
                          setState(() => _hover = event.localPosition),
                      onLongPressMoveUpdate: (event) =>
                          setState(() => _hover = event.localPosition),
                      onLongPressEnd: (_) => setState(() => _hover = null),
                      onLongPressCancel: () => setState(() => _hover = null),
                      onScaleStart: (event) {
                        _gestureCenter = _center;
                        _gestureWindow = controller.chartWindow.toDouble();
                        _gestureMin = _min ?? -1;
                        _gestureMax = _max ?? 1;
                        _lastFocal = event.localFocalPoint;
                        setState(() => _hover = null);
                      },
                      onScaleUpdate: (event) {
                        if (plot.width <= 0 || plot.height <= 0) return;
                        if (event.pointerCount > 1) {
                          final next = (_gestureWindow / event.scale)
                              .clamp(.001, 3600)
                              .toDouble();
                          _navigate(_gestureCenter.round(), next);
                          final mid = (_gestureMin + _gestureMax) / 2;
                          final span =
                              ((_gestureMax - _gestureMin) *
                                      (next / _gestureWindow))
                                  .clamp(1e-6, 1e12);
                          setState(() {
                            _min = mid - span / 2;
                            _max = mid + span / 2;
                            _manualScale = true;
                          });
                        } else {
                          final delta = event.localFocalPoint - _lastFocal;
                          _gestureCenter -=
                              delta.dx /
                              plot.width *
                              controller.chartWindow *
                              1e6;
                          _navigate(_gestureCenter.round());
                          final shift =
                              delta.dy /
                              plot.height *
                              ((_max ?? 1) - (_min ?? -1));
                          setState(() {
                            _min = (_min ?? -1) + shift;
                            _max = (_max ?? 1) + shift;
                            _manualScale = true;
                          });
                        }
                        _lastFocal = event.localFocalPoint;
                      },
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CustomPaint(
                            key: const ValueKey('telemetry-chart-plot'),
                            size: Size.infinite,
                            painter: _ChartPainter(
                              series: series,
                              fontFamily: Theme.of(
                                context,
                              ).textTheme.bodySmall?.fontFamily,
                              windowSeconds: controller.chartWindow.toDouble(),
                              cursorSeconds: controller.replaying
                                  ? _right
                                  : null,
                              yMin: _min ?? -1,
                              yMax: _max ?? 1,
                              hover: hover,
                              markers: controller.replaying
                                  ? {
                                      '起点': (
                                        controller.selectionStartUs / 1e6,
                                        Colors.green,
                                      ),
                                      '终点': (
                                        controller.selectionEndUs / 1e6,
                                        Colors.orange,
                                      ),
                                    }
                                  : {},
                              axisColor: colors.onSurfaceVariant,
                              gridColor: colors.outlineVariant,
                            ),
                          ),
                          if (hover != null)
                            IgnorePointer(
                              child: CustomSingleChildLayout(
                                delegate: _ProbeLayout(hover, plot),
                                child: Container(
                                  key: const ValueKey('chart-probe'),
                                  constraints: BoxConstraints(
                                    maxWidth: math.max(80, plot.width * .6),
                                    maxHeight: math.max(30, plot.height * .7),
                                  ),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: colors.surface.withValues(
                                      alpha: .94,
                                    ),
                                    border: Border.all(
                                      color: colors.outlineVariant,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: SingleChildScrollView(
                                    child: Text(
                                      hoverText.join('\n'),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    },
  );
}

/// Anchor to the crosshair; flip only when the preferred quadrant is clipped.
class _ProbeLayout extends SingleChildLayoutDelegate {
  const _ProbeLayout(this.point, this.bounds);
  final Offset point;
  final Rect bounds;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(Size(bounds.width * .6, bounds.height * .7));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const gap = 12.0;
    var x = point.dx + gap;
    var y = point.dy - childSize.height - gap;
    if (x + childSize.width > bounds.right) {
      x = point.dx - childSize.width - gap;
    }
    if (y < bounds.top) y = point.dy + gap;
    return Offset(
      x.clamp(
        bounds.left,
        math.max(bounds.left, bounds.right - childSize.width),
      ),
      y.clamp(
        bounds.top,
        math.max(bounds.top, bounds.bottom - childSize.height),
      ),
    );
  }

  @override
  bool shouldRelayout(covariant _ProbeLayout oldDelegate) =>
      oldDelegate.point != point || oldDelegate.bounds != bounds;
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.series,
    this.hover,
    required this.fontFamily,
    required this.windowSeconds,
    required this.cursorSeconds,
    required this.yMin,
    required this.yMax,
    required this.markers,
    required this.axisColor,
    required this.gridColor,
  });

  final Map<TelemetryChannel, List<TelemetryPoint>> series;
  final Offset? hover;
  final String? fontFamily;
  final double windowSeconds;
  final double? cursorSeconds;
  final double yMin, yMax;
  final Map<String, (double, Color)> markers;
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

    final min = yMin, max = yMax;
    _grid(canvas, plot, min, max);
    _timeAxis(canvas, plot);
    double xFor(double seconds) =>
        plot.right - (seconds / windowSeconds) * plot.width;
    double yFor(double value) =>
        plot.bottom - ((value - min) / (max - min)) * plot.height;

    canvas.save();
    canvas.clipRect(plot);
    // A reference line, not an auto-range constraint: manual zoom stays intact.
    if (min <= 0 && max >= 0 && max > min) {
      final y = yFor(0);
      final pen = Paint()
        ..color = axisColor.withValues(alpha: .8)
        ..strokeWidth = 1.2;
      for (double x = plot.left; x < plot.right; x += 10) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 6, plot.right), y),
          pen,
        );
      }
    }
    for (final entry in markers.entries) {
      final x = xFor(cursorSeconds! - entry.value.$1);
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        Paint()
          ..color = entry.value.$2
          ..strokeWidth = 1.5,
      );
      final label = TextPainter(
        text: TextSpan(
          text: entry.key,
          style: TextStyle(
            fontFamily: fontFamily,
            color: entry.value.$2,
            fontSize: 11,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(x + 4, plot.top + 3));
    }
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
    if (hover != null) {
      final pen = Paint()
        ..color = axisColor.withValues(alpha: .7)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(hover!.dx, plot.top),
        Offset(hover!.dx, plot.bottom),
        pen,
      );
      canvas.drawLine(
        Offset(plot.left, hover!.dy),
        Offset(plot.right, hover!.dy),
        pen,
      );
    }
    canvas.restore();
    _drawLegend(canvas, size);
  }

  void _grid(Canvas canvas, Rect plot, double min, double max) {
    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.65)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final value = min + (max - min) * i / 4;
      final y = plot.bottom - ((value - min) / (max - min)) * plot.height;
      // Avoid a solid grid line showing through the gaps of the zero dash.
      if (value.abs() > (max - min).abs() * 1e-12) {
        canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      }
      final label = TextPainter(
        text: TextSpan(
          text: value.toStringAsFixed(value.abs() >= 100 ? 0 : 1),
          style: TextStyle(
            fontFamily: fontFamily,
            color: axisColor,
            fontSize: 10,
          ),
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
          text: cursorSeconds != null
              ? '${(cursorSeconds! - seconds).toStringAsFixed(windowSeconds < .01
                    ? 6
                    : windowSeconds < 1
                    ? 3
                    : 1)}s'
              : i == 4
              ? 'now'
              : '-${seconds.toStringAsFixed(0)}s',
          style: TextStyle(
            fontFamily: fontFamily,
            color: axisColor,
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(x - label.width / 2, plot.bottom + 4));
    }
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
          style: TextStyle(
            fontFamily: fontFamily,
            color: channel.color,
            fontSize: 11,
          ),
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
