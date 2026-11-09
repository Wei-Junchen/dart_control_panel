import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dart_control_panel/features/flight_analysis/luma_analysis_service.dart';
import 'package:dart_control_panel/features/flight_analysis/luma_preview.dart';
import 'package:dart_control_panel/features/flight_analysis/luma_frame_navigation.dart';
import 'package:dart_control_panel/core/board/session/board_config_snapshot.dart';

class LumaAnalysisScreen extends StatefulWidget {
  const LumaAnalysisScreen({
    super.key,
    required this.video,
    this.service,
    this.snapshot,
    this.previewSupported,
  });
  final File video;
  final LumaAnalysisService? service;
  final BoardConfigSnapshot? snapshot;
  @visibleForTesting
  final bool? previewSupported;
  @override
  State<LumaAnalysisScreen> createState() => _LumaAnalysisScreenState();
}

class _LumaAnalysisScreenState extends State<LumaAnalysisScreen> {
  late final LumaAnalysisService _service =
      widget.service ?? LumaAnalysisService();
  final _values = <String, int>{
    'green_y_min': 20,
    'green_g_min': 50,
    'green_score_min': 60,
    'green_rg_min': 20,
    'green_gb_min': 20,
  };
  String _mode = 'luma_ellipse';
  final _luma = <String, num>{
    'luma_threshold': 80,
    'ellipse_min_pixels': 9,
    'ellipse_max_axis_ratio': 2.0,
    'ellipse_min_iou': 0.9,
    'ellipse_green_min_fraction': 0.25,
    'ellipse_color_scale': 1.5,
  };
  static const _lumaRanges = <String, (num, num, bool)>{
    'luma_threshold': (0, 255, true),
    'ellipse_min_pixels': (9, 1000000, true),
    'ellipse_max_axis_ratio': (1, 2, false),
    'ellipse_min_iou': (0.01, 1, false),
    'ellipse_green_min_fraction': (0, 1, false),
    'ellipse_color_scale': (1, 2, false),
  };
  Map<String, dynamic> _detectorConfig = {};
  bool _autoRoiUnresolved = false;
  final _invalid = <String>{};
  bool _busy = false;
  int? _totalFrames;
  int _currentFrame = 1;
  int _previewGeneration = 0;
  int _progressFrames = 0;
  int _seekSequence = 0;
  bool _previewPending = false;
  bool _seekInFlight = false;
  int? _queuedFrame;
  bool _preparing = false;
  Timer? _previewDebounce;
  bool get _supportsPreview => widget.previewSupported ?? Platform.isAndroid;
  LumaPreviewFrame? _frame;
  String? _error;
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _loadSnapshot();
    if (_supportsPreview) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _prepare();
      });
    }
  }

  void _loadSnapshot() {
    final raw = widget.snapshot?.config['detector'];
    if (raw is! Map) return;
    _detectorConfig = Map<String, dynamic>.from(raw);
    _mode = raw['mode'] == 'luma_ellipse' ? 'luma_ellipse' : 'nv21_green';
    for (final key in _values.keys) {
      final value = raw[key];
      final max = key == 'green_score_min' ? 510 : 255;
      final min = key == 'green_y_min' || key == 'green_g_min' ? 0 : -max;
      if (value is int && value >= min && value <= max) _values[key] = value;
    }
    for (final key in _luma.keys) {
      final value = raw[key];
      final range = _lumaRanges[key]!;
      if (value is num &&
          value.isFinite &&
          value >= range.$1 &&
          value <= range.$2 &&
          (!range.$3 || value is int)) {
        _luma[key] = value;
      }
    }
    if (raw['roi'] == 'auto' || !raw.containsKey('roi')) {
      final roi = widget.snapshot?.resolvedRoi;
      if (roi != null && roi.length == 4 && roi[2] > 0 && roi[3] > 0) {
        _detectorConfig['roi'] = roi;
      } else {
        _autoRoiUnresolved = true;
      }
    }
  }

  @override
  void dispose() {
    _seekSequence++;
    _previewDebounce?.cancel();
    _service.dispose();
    super.dispose();
  }

  Future<void> _seek(int number) async {
    setState(() {
      _currentFrame = number;
      _previewPending = true;
      _error = null;
    });
    _queuedFrame = number;
    if (_seekInFlight) return;
    _seekInFlight = true;
    try {
      while (mounted && _queuedFrame != null) {
        final requestedFrame = _queuedFrame!;
        _queuedFrame = null;
        final request = _seekSequence;
        try {
          final message = await _service.readCachedFrame(
            requestedFrame,
            Map.of(_values),
            mode: _mode,
            luma: Map.of(_luma),
            detectorConfig: Map.of(_detectorConfig),
          );
          final frame = LumaPreviewFrame.fromMessage(message);
          if (frame == null || frame.number != requestedFrame) {
            throw const FormatException('缓存帧格式无效');
          }
          if (mounted && request == _seekSequence) {
            setState(() {
              _previewGeneration++;
              _frame = frame;
              _previewPending = _queuedFrame != null;
            });
          }
        } catch (e) {
          if (mounted && request == _seekSequence && _queuedFrame == null) {
            setState(() {
              _error = '$e';
              _previewPending = false;
            });
          }
        }
      }
    } finally {
      _seekInFlight = false;
    }
  }

  void _parametersUpdated() {
    _previewDebounce?.cancel();
    _seekSequence++;
    _queuedFrame = null;
    setState(() {
      _data = null;
      _error = null;
      _previewPending =
          _supportsPreview && _totalFrames != null && _invalid.isEmpty;
    });
    if (_supportsPreview &&
        _totalFrames != null &&
        _invalid.isEmpty &&
        !_busy) {
      _previewDebounce = Timer(const Duration(milliseconds: 200), () {
        if (mounted) _seek(_currentFrame);
      });
    }
  }

  Future<void> _prepare() async {
    final wantedFrame = _currentFrame;
    _previewDebounce?.cancel();
    _seekSequence++;
    _queuedFrame = null;
    setState(() {
      _busy = true;
      _preparing = true;
      _error = null;
      _data = null;
      _totalFrames = null;
      _progressFrames = 0;
      _previewGeneration++;
      _frame = null;
      _previewPending = false;
    });
    try {
      final data = await _service.analyze(
        widget.video,
        Map.of(_values),
        mode: _mode,
        luma: Map.of(_luma),
        detectorConfig: _detectorConfig,
        cacheAll: true,
        pacePreview: false,
        onProgress: (count) {
          if (mounted) setState(() => _progressFrames = count);
        },
      );
      if (!mounted) return;
      final video = data['video'];
      final frames = video is Map ? video['frames'] : null;
      if (frames is! int || frames < 1) throw const FormatException('视频帧数无效');
      setState(() {
        _totalFrames = frames;
        _currentFrame = wantedFrame.clamp(1, frames);
      });
      await _seek(_currentFrame);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _preparing = false;
        });
      }
    }
  }

  Future<void> _analyzeAll() async {
    _previewDebounce?.cancel();
    setState(() {
      _busy = true;
      _preparing = false;
      _data = null;
      _error = null;
    });
    try {
      final data = await _service.analyze(
        widget.video,
        Map.of(_values),
        mode: _mode,
        luma: Map.of(_luma),
        detectorConfig: _detectorConfig,
        pacePreview: false,
      );
      if (mounted) {
        setState(() => _data = data);
        if (_supportsPreview && _previewPending && _totalFrames != null) {
          await _seek(_currentFrame);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final run = (_data?['runs'] as List?)?.firstOrNull;
    final summary = run is Map ? run['summary'] : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('H.264 离线分析'),
        actions: [
          IconButton(
            tooltip: '分析说明',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('离线分析说明'),
                content: SingleChildScrollView(
                  child: SelectableText(
                    '录像：${widget.video.path}\n\n'
                    '分析只在本地进行，不会修改录像或板端配置。'
                    '录像叠加、解码和压缩可能影响结果；默认参数不一定是录像时的配置。\n\n'
                    'luma_ellipse 是本地实验性算法。掩码仅表示阈值通过，不等同于最终检测结果。'
                    '先缓存全分辨率 NV21 原始帧；调整参数只重算当前帧。单帧预览重置跟踪器，全片统计则连续跟踪，结果可能不同。缓存上限 1 GiB，退出页面后清理。'
                    '${Platform.isAndroid ? "Android 仅支持 I/P 帧 H.264。" : "Linux 参考工具会缓存解码帧（最多 2 GiB）。"}',
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _busy || _invalid.isNotEmpty
                ? null
                : (_supportsPreview && _totalFrames == null
                      ? _prepare
                      : _analyzeAll),
            icon: const Icon(Icons.play_arrow),
            label: Text(
              _supportsPreview && _totalFrames == null ? '准备视频' : '全片统计',
            ),
          ),
          if (_busy)
            TextButton(onPressed: _service.cancel, child: const Text('取消')),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (_supportsPreview &&
              constraints.maxWidth >= 700 &&
              constraints.maxHeight >= 250) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 6, 12),
                    child: Column(
                      children: [
                        Expanded(
                          child: LumaPreviewPanels(
                            generation: _previewGeneration,
                            frame: _frame,
                            expand: true,
                          ),
                        ),
                        LumaFrameNavigation(
                          total: _totalFrames,
                          current: _currentFrame,
                          enabled: !_busy && _invalid.isEmpty,
                          onSeek: _seek,
                        ),
                      ],
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _settings(context, summary, includePreview: false),
                ),
              ],
            );
          }
          return _settings(context, summary, includePreview: true);
        },
      ),
    );
  }

  Widget _settings(
    BuildContext context,
    Object? summary, {
    required bool includePreview,
  }) {
    return ListView(
      key: const ValueKey('analysis-settings'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      children: [
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final mode in ['luma_ellipse', 'nv21_green'])
              ChoiceChip(
                label: Text(mode),
                selected: _mode == mode,
                onSelected: _busy
                    ? null
                    : (_) {
                        if (_mode == mode) return;
                        setState(() {
                          _mode = mode;
                          _invalid.clear();
                        });
                        _parametersUpdated();
                      },
              ),
            if (_busy && _preparing) Text('已缓存 $_progressFrames 帧…'),
            if (!_busy && _previewPending) const Text('正在更新当前帧…'),
          ],
        ),
        if (widget.snapshot != null)
          Text(
            _autoRoiUnresolved
                ? '连接时配置（录像时可能不同）；自动 ROI 按全画面'
                : '连接时配置（录像时可能不同）',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (_invalid.isNotEmpty)
          Text(
            '参数无效：${_invalid.join('、')}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_supportsPreview && includePreview) ...[
          const SizedBox(height: 8),
          LumaFrameNavigation(
            total: _totalFrames,
            current: _currentFrame,
            enabled: !_busy && _invalid.isEmpty,
            onSeek: _seek,
          ),
          const Text('单帧预览（跟踪器已重置）', style: TextStyle(fontSize: 12)),
          LumaPreviewPanels(generation: _previewGeneration, frame: _frame),
        ] else if (!_supportsPreview)
          const Text('当前平台不支持逐帧缓存和预览；可手动运行全片统计。'),
        const SizedBox(height: 8),
        Text(_mode == 'luma_ellipse' ? '椭圆参数（颜色校验使用连接配置或默认绿色阈值）' : '绿色阈值'),
        const SizedBox(height: 12),
        Wrap(
          key: const ValueKey('detector-fields'),
          spacing: 12,
          runSpacing: 8,
          children: [
            if (_mode == 'luma_ellipse')
              for (final entry in _luma.entries)
                SizedBox(
                  width: 190,
                  child: TextFormField(
                    key: ValueKey('luma-${entry.key}'),
                    initialValue: '${entry.value}',
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: entry.key,
                      helperText:
                          '${_lumaRanges[entry.key]!.$1}..${_lumaRanges[entry.key]!.$2}',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      final range = _lumaRanges[entry.key]!;
                      final n = range.$3
                          ? int.tryParse(value)
                          : double.tryParse(value);
                      setState(() {
                        if (n == null ||
                            !n.isFinite ||
                            n < range.$1 ||
                            n > range.$2) {
                          _invalid.add(entry.key);
                        } else {
                          _invalid.remove(entry.key);
                          _luma[entry.key] = n;
                        }
                      });
                      _parametersUpdated();
                    },
                  ),
                ),
            if (_mode == 'nv21_green')
              for (final entry in _values.entries)
                SizedBox(
                  width: 190,
                  child: TextFormField(
                    key: ValueKey('green-${entry.key}'),
                    initialValue: '${entry.value}',
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                    ),
                    decoration: InputDecoration(
                      labelText: entry.key,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      final n = int.tryParse(value);
                      final limit = entry.key == 'green_score_min' ? 510 : 255;
                      final min =
                          entry.key == 'green_y_min' ||
                              entry.key == 'green_g_min'
                          ? 0
                          : -limit;
                      setState(() {
                        if (n == null || n < min || n > limit) {
                          _invalid.add(entry.key);
                        } else {
                          _invalid.remove(entry.key);
                          _values[entry.key] = n;
                        }
                      });
                      _parametersUpdated();
                    },
                  ),
                ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _busy || _invalid.isNotEmpty
                  ? null
                  : (_supportsPreview && _totalFrames == null
                        ? _prepare
                        : _analyzeAll),
              icon: const Icon(Icons.analytics_outlined),
              label: Text(
                _supportsPreview && _totalFrames == null ? '准备视频' : '全片统计',
              ),
            ),
            if (_busy) ...[
              const SizedBox(width: 12),
              Text(_preparing ? '正在缓存原始帧…' : '正在连续跟踪统计…'),
              TextButton(onPressed: _service.cancel, child: const Text('取消')),
            ],
          ],
        ),
        if (summary is Map) ...[
          const SizedBox(height: 12),
          Text('分析结果', style: Theme.of(context).textTheme.titleMedium),
          Text(
            '帧数：${summary['frames']}　检测到：${summary['found']}　检出率：${((summary['found_rate'] as num? ?? 0) * 100).toStringAsFixed(1)}%',
          ),
          Text('丢失次数：${summary['lost']}　最长连续丢失：${summary['longest_lost']} 帧'),
          Text(
            '本机耗时：平均 ${((summary['mean_ms'] as num?) ?? 0).toStringAsFixed(3)} ms　P99 ${((summary['p99_ms'] as num?) ?? 0).toStringAsFixed(3)} ms（非板端性能）',
          ),
        ],
      ],
    );
  }
}
