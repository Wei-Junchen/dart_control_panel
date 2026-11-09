import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class LumaPreviewFrame {
  LumaPreviewFrame({
    required this.number,
    required this.width,
    required this.height,
    required this.found,
    required this.rect,
    required this.rgb,
    required this.y,
    required this.mask,
    required this.pixels,
  });
  final int number, width, height, pixels;
  final bool found;
  final List<int> rect;
  final Uint8List rgb, y, mask;

  static LumaPreviewFrame? fromMessage(Map<dynamic, dynamic> message) {
    final rect = message['rect'];
    final width = message['width'], height = message['height'];
    if (width is! int ||
        height is! int ||
        width < 1 ||
        height < 1 ||
        rect is! List ||
        rect.length != 4 ||
        rect.any((v) => v is! int) ||
        message['rgb'] is! Uint8List ||
        message['y'] is! Uint8List ||
        message['mask'] is! Uint8List ||
        message['frame'] is! int ||
        message['pixels'] is! int ||
        message['found'] is! bool) {
      return null;
    }
    return LumaPreviewFrame(
      number: message['frame'] as int,
      width: width,
      height: height,
      found: message['found'] as bool,
      rect: rect.cast<int>().toList(),
      rgb: message['rgb'] as Uint8List,
      y: message['y'] as Uint8List,
      mask: message['mask'] as Uint8List,
      pixels: message['pixels'] as int,
    );
  }
}

class LumaPreviewPanels extends StatefulWidget {
  const LumaPreviewPanels({
    super.key,
    required this.frame,
    this.generation = 0,
    this.expand = false,
  });
  final LumaPreviewFrame? frame;
  final bool expand;

  /// A new request can move backwards or reprocess the same frame.
  final int generation;
  @override
  State<LumaPreviewPanels> createState() => _LumaPreviewPanelsState();
}

class _LumaPreviewPanelsState extends State<LumaPreviewPanels> {
  LumaPreviewFrame? _shown, _pending;
  List<ui.Image>? _images;
  bool _decoding = false;
  int _epoch = 0, _latestNumber = -1;
  final _order = [0, 1, 2];
  bool _showDetectionBox = true;
  int get _selected => _order.first;

  @override
  void initState() {
    super.initState();
    _enqueue(widget.frame);
  }

  @override
  void didUpdateWidget(covariant LumaPreviewPanels oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.generation != widget.generation) {
      // Invalidate in-flight decoding but retain the displayed triplet until
      // the replacement is fully decoded. Frame numbers may move backwards.
      _epoch++;
      _latestNumber = -1;
      _pending = null;
      _enqueue(widget.frame);
    } else if (!identical(oldWidget.frame, widget.frame)) {
      _enqueue(widget.frame);
    }
  }

  void _disposeLater(List<ui.Image>? images) {
    if (images == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final image in images) {
        image.dispose();
      }
    });
  }

  void _enqueue(LumaPreviewFrame? frame) {
    if (frame == null) {
      _epoch++;
      _latestNumber = -1;
      _pending = null;
      _shown = null;
      _disposeLater(_images);
      _images = null;
      return;
    }
    if (frame.number < _latestNumber) return;
    _latestNumber = frame.number;
    _pending = frame;
    if (!_decoding) _decodeNext();
  }

  Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  Future<void> _decodeNext() async {
    _decoding = true;
    while (mounted && _pending != null) {
      final frame = _pending!;
      _pending = null;
      final epoch = _epoch;
      final decoded = <ui.Image>[];
      try {
        // Decode into a private set; publish only after all three are ready.
        for (final bytes in [frame.rgb, frame.y, frame.mask]) {
          decoded.add(await _decode(bytes));
        }
        if (!mounted || epoch != _epoch) {
          for (final image in decoded) {
            image.dispose();
          }
          continue;
        }
        final old = _images;
        setState(() {
          _shown = frame;
          _images = decoded;
        });
        _disposeLater(old);
      } catch (_) {
        for (final image in decoded) {
          image.dispose();
        }
      }
    }
    _decoding = false;
  }

  @override
  void dispose() {
    _epoch++;
    _pending = null;
    for (final image in _images ?? <ui.Image>[]) {
      image.dispose();
    }
    _images = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = _shown;
    final images = _images;
    final height = MediaQuery.sizeOf(context).height < 500 ? 165.0 : 260.0;
    const labels = ['原画面 / 检测框', '解码 Y 平面', '阈值掩码'];
    Widget panel(int index) =>
        _panel(labels[index], index, frame, images?[index]);
    final panels = LayoutBuilder(
      builder: (context, constraints) {
        const gap = 6.0;
        final mainWidth = (constraints.maxWidth - gap) * .75;
        final thumbnailWidth = constraints.maxWidth - mainWidth - gap;
        final thumbnailHeight = (constraints.maxHeight - gap) / 2;
        return ClipRect(
          child: Stack(
            children: [
              for (final index in _order.reversed)
                AnimatedPositioned(
                  key: ValueKey('analysis-position-$index'),
                  duration: const Duration(milliseconds: 360),
                  curve: Curves.easeInOutCubic,
                  left: index == _selected ? 0 : mainWidth + gap,
                  top: index == _selected || _order.indexOf(index) == 1
                      ? 0
                      : thumbnailHeight + gap,
                  width: index == _selected ? mainWidth : thumbnailWidth,
                  height: index == _selected
                      ? constraints.maxHeight
                      : thumbnailHeight,
                  child: panel(index),
                ),
            ],
          ),
        );
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                frame == null
                    ? '等待解码帧…'
                    : '第 ${frame.number} 帧 · ${frame.width}×${frame.height} · ${frame.found ? '发现目标（像素 ${frame.pixels}）' : '未发现目标'}',
                key: const ValueKey('analysis-frame-info'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Text('识别框', style: TextStyle(fontSize: 12)),
            SizedBox(
              width: 42,
              height: 32,
              child: FittedBox(
                child: Switch(
                  key: const ValueKey('analysis-show-detection-box'),
                  value: _showDetectionBox,
                  onChanged: (value) =>
                      setState(() => _showDetectionBox = value),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (widget.expand)
          Expanded(child: panels)
        else
          SizedBox(height: height, child: panels),
      ],
    );
  }

  Widget _panel(
    String label,
    int index,
    LumaPreviewFrame? frame,
    ui.Image? image,
  ) {
    return Semantics(
      button: true,
      selected: _selected == index,
      label: '放大$label',
      child: InkWell(
        key: ValueKey('analysis-channel-$index'),
        onTap: () => setState(() {
          final slot = _order.indexOf(index);
          _order[slot] = _order[0];
          _order[0] = index;
        }),
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xff111b28),
            borderRadius: BorderRadius.circular(8),
            border: _selected == index
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : null,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: image == null || frame == null
                      ? const Text('—', style: TextStyle(color: Colors.white54))
                      : AspectRatio(
                          aspectRatio: frame.width / frame.height,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              RawImage(image: image, fit: BoxFit.fill),
                              if (_showDetectionBox && frame.found)
                                CustomPaint(
                                  key: ValueKey(
                                    'analysis-detection-box-$index',
                                  ),
                                  painter: _TargetPainter(frame),
                                ),
                            ],
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TargetPainter extends CustomPainter {
  _TargetPainter(this.frame);
  final LumaPreviewFrame frame;
  @override
  void paint(Canvas canvas, Size size) {
    final r = frame.rect;
    final rect = Rect.fromLTWH(
      r[0] * size.width / frame.width,
      r[1] * size.height / frame.height,
      r[2] * size.width / frame.width,
      r[3] * size.height / frame.height,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.lightGreenAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _TargetPainter oldDelegate) =>
      oldDelegate.frame != frame;
}
