import 'package:flutter/material.dart';

/// Three independently draggable handles share one monotonic time axis.
/// Endpoint handles sit above/below the axis so coincident times stay usable.
class TelemetrySelectionTimeline extends StatefulWidget {
  const TelemetrySelectionTimeline({
    super.key,
    required this.duration,
    required this.start,
    required this.current,
    required this.end,
    required this.onStart,
    required this.onCurrent,
    required this.onEnd,
    required this.onCurrentStart,
    required this.onCurrentEnd,
  });
  final double duration, start, current, end;
  final ValueChanged<double> onStart, onCurrent, onEnd;
  final VoidCallback onCurrentStart;
  final ValueChanged<double> onCurrentEnd;

  @override
  State<TelemetrySelectionTimeline> createState() =>
      _TelemetrySelectionTimelineState();
}

class _TelemetrySelectionTimelineState
    extends State<TelemetrySelectionTimeline> {
  final _axisKey = GlobalKey();
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final duration = widget.duration,
          start = widget.start,
          current = widget.current,
          end = widget.end;
      final onStart = widget.onStart,
          onCurrent = widget.onCurrent,
          onEnd = widget.onEnd;
      final onCurrentStart = widget.onCurrentStart,
          onCurrentEnd = widget.onCurrentEnd;
      const padding = 18.0;
      final width = (constraints.maxWidth - 2 * padding).clamp(
        1.0,
        double.infinity,
      );
      final max = duration > 0 ? duration : 1.0;
      final axisKey = _axisKey;
      double position(double value) => padding + value / max * width;
      double time(Offset global) {
        final box = axisKey.currentContext!.findRenderObject()! as RenderBox;
        return ((box.globalToLocal(global).dx - padding) / width * max).clamp(
          0.0,
          max,
        );
      }

      Widget handle(
        String name,
        String key,
        double value,
        double y,
        Color color,
        double lower,
        double upper,
        ValueChanged<double> changed, {
        bool play = false,
      }) {
        double constrained(double value) => value.clamp(lower, upper);
        return Positioned(
          left: position(value) - 14,
          top: y - 10,
          child: Semantics(
            label: '$name ${value.toStringAsFixed(3)} 秒',
            slider: true,
            onIncrease: duration == 0
                ? null
                : () => changed(constrained(value + max / 100)),
            onDecrease: duration == 0
                ? null
                : () => changed(constrained(value - max / 100)),
            child: Tooltip(
              message: '$name ${value.toStringAsFixed(3)}s',
              child: GestureDetector(
                key: ValueKey(key),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: duration == 0
                    ? null
                    : (event) {
                        if (play) onCurrentStart();
                        changed(constrained(time(event.globalPosition)));
                      },
                onHorizontalDragUpdate: duration == 0
                    ? null
                    : (event) =>
                          changed(constrained(time(event.globalPosition))),
                onHorizontalDragEnd: duration == 0
                    ? null
                    : (_) {
                        if (play) onCurrentEnd(value);
                      },
                onTap: duration == 0
                    ? null
                    : () {
                        if (play) onCurrentStart();
                        changed(value);
                        if (play) onCurrentEnd(value);
                      },
                child: SizedBox(
                  width: 28,
                  height: 20,
                  child: Icon(
                    play
                        ? Icons.circle
                        : name == '起点'
                        ? Icons.arrow_drop_down
                        : Icons.arrow_drop_up,
                    size: play ? 18 : 28,
                    color: color,
                  ),
                ),
              ),
            ),
          ),
        );
      }

      return SizedBox(
        key: axisKey,
        height: 88,
        child: Stack(
          children: [
            Positioned(
              left: padding,
              right: padding,
              top: 32,
              child: Container(
                height: 4,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            Positioned(
              left: position(start),
              width: ((end - start) / max * width).clamp(0.0, width),
              top: 32,
              child: Container(height: 4, color: Colors.teal),
            ),
            for (var i = 0; i <= 4; i++)
              Positioned(
                left: padding + width * i / 4 - 22,
                top: 70,
                child: SizedBox(
                  width: 44,
                  child: Text(
                    '${(max * i / 4).toStringAsFixed(1)}s',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
              ),
            handle(
              '起点',
              'telemetry-start-slider',
              start,
              14,
              Colors.green,
              0,
              current,
              onStart,
            ),
            handle(
              '播放',
              'telemetry-history-slider',
              current,
              34,
              Colors.blue,
              start,
              end,
              onCurrent,
              play: true,
            ),
            handle(
              '终点',
              'telemetry-end-slider',
              end,
              54,
              Colors.orange,
              current,
              max,
              onEnd,
            ),
          ],
        ),
      );
    },
  );
}
