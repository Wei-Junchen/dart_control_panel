import 'package:flutter/material.dart';

/// One-based frame positions, enabled after the first complete scan.
class LumaFrameNavigation extends StatefulWidget {
  const LumaFrameNavigation({
    super.key,
    required this.total,
    required this.current,
    required this.enabled,
    required this.onSeek,
  });

  final int? total;
  final int current;
  final bool enabled;
  final ValueChanged<int> onSeek;

  @override
  State<LumaFrameNavigation> createState() => _LumaFrameNavigationState();
}

class _LumaFrameNavigationState extends State<LumaFrameNavigation> {
  int? _dragging;

  @override
  Widget build(BuildContext context) {
    final total = widget.total;
    final available = widget.enabled && total != null && total > 0;
    final current = (_dragging ?? widget.current).clamp(1, total ?? 1);
    final canSlide = available && total > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '上一帧',
              onPressed: available && current > 1
                  ? () => widget.onSeek(current - 1)
                  : null,
              icon: const Icon(Icons.skip_previous),
            ),
            Expanded(
              child: Slider(
                allowedInteraction: SliderInteraction.slideThumb,
                value: current.toDouble(),
                min: 1,
                max: (total != null && total > 1 ? total : 2).toDouble(),
                onChanged: canSlide
                    ? (v) {
                        final frame = v.round();
                        if (_dragging == frame) return;
                        setState(() => _dragging = frame);
                        widget.onSeek(frame);
                      }
                    : null,
                onChangeEnd: canSlide
                    ? (v) {
                        final frame = v.round();
                        final changed = _dragging != frame;
                        setState(() => _dragging = null);
                        if (changed) widget.onSeek(frame);
                      }
                    : null,
              ),
            ),
            IconButton(
              tooltip: '下一帧',
              onPressed: available && current < total
                  ? () => widget.onSeek(current + 1)
                  : null,
              icon: const Icon(Icons.skip_next),
            ),
            Text(total == null ? '帧数未知' : '$current / $total'),
          ],
        ),
      ],
    );
  }
}
