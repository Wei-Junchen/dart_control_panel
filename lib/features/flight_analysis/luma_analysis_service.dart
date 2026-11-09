import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:dart_control_panel/core/platform/app_paths.dart';
import 'package:flutter/services.dart';

/// Runs the reference detector against decoded NV21, without altering source
/// video or board configuration. Requires the separate desktop toolchain.
class LumaAnalysisService {
  LumaAnalysisService({this.script, this.python = 'python3'});
  final File? script;
  final String python;
  Process? _process;
  bool _cancelled = false;
  bool _androidBusy = false;
  String? _cacheId;
  static const _frames = MethodChannel(
    'com.litwei.dart_control_panel/analysis_frames',
  );
  static final _frameListeners =
      <String, void Function(Map<dynamic, dynamic>)>{};
  static final _progressListeners = <String, void Function(int)>{};
  static bool _handlerReady = false;
  static int _sequence = 0;

  static void _initFrameHandler() {
    if (_handlerReady) return;
    _handlerReady = true;
    _frames.setMethodCallHandler((call) async {
      if (call.arguments is! Map) return;
      final frame = call.arguments as Map<dynamic, dynamic>;
      final id = frame['analysis_id'];
      if (id is! String) return;
      if (call.method == 'frame') _frameListeners[id]?.call(frame);
      if (call.method == 'progress' && frame['frame'] is int) {
        _progressListeners[id]?.call(frame['frame'] as int);
      }
    });
  }

  /// Accept only valid, understood detector fields from untrusted snapshots.
  static Map<String, dynamic> normalizedDetectorParameters(
    Map<String, dynamic> config,
  ) {
    int field(String key, int fallback, int max) {
      final v = config[key];
      return v is int && v >= 1 && v <= max ? v : fallback;
    }

    final value = config['roi'];
    final roi =
        value is List &&
            value.length == 4 &&
            value.every((v) => v is int && v >= 0 && v <= 4096) &&
            value[2] > 0 &&
            value[3] > 0
        ? value.cast<int>().toList()
        : <int>[0, 0, 0, 0];
    return {
      'search_radius': field('search_radius', 20, 2147483647),
      'area_threshold': field('area_threshold', 1, 2147483647),
      'pixels_threshold': field('pixels_threshold', 1, 2147483647),
      'x_stride': field('x_stride', 1, 8),
      'y_stride': field('y_stride', 1, 8),
      'roi': roi,
    };
  }

  static File defaultScript() {
    final env = Platform.environment['DART_LUMA_TUNER'];
    if (env != null && env.trim().isNotEmpty) return File(env);
    return File(
      '${Directory.current.parent.path}/DartVision2027/scripts/luma_tuner.py',
    );
  }

  void cancel() {
    _cancelled = true;
    _process?.kill();
    if (_androidBusy) {
      unawaited(
        AppPaths.channel
            .invokeMethod<void>('cancelH264Analysis')
            .catchError((_) {}),
      );
    }
  }

  Future<void> releaseCache() async {
    final id = _cacheId;
    _cacheId = null;
    if (id != null && Platform.isAndroid) {
      await AppPaths.channel.invokeMethod<void>('releaseAnalysisCache', {
        'analysis_id': id,
      });
    }
  }

  void dispose() {
    cancel();
    unawaited(releaseCache().catchError((_) {}));
  }

  static Map<String, dynamic> detectorArguments(
    Map<String, int> thresholds,
    String mode,
    Map<String, num> luma,
    Map<String, dynamic> detectorConfig,
  ) {
    final common = normalizedDetectorParameters(detectorConfig);
    return {
      'mode': mode,
      'detector_common': [
        common['search_radius'],
        common['area_threshold'],
        common['pixels_threshold'],
        common['x_stride'],
        common['y_stride'],
        ...(common['roi'] as List<int>),
      ],
      'luma_ints': [
        luma['luma_threshold'] ?? 80,
        luma['ellipse_min_pixels'] ?? 9,
      ],
      'luma_floats': [
        luma['ellipse_max_axis_ratio'] ?? 2.0,
        luma['ellipse_min_iou'] ?? 0.9,
        luma['ellipse_green_min_fraction'] ?? 0.25,
        luma['ellipse_color_scale'] ?? 1.5,
      ],
      'thresholds': [
        for (final key in [
          'green_y_min',
          'green_g_min',
          'green_score_min',
          'green_rg_min',
          'green_gb_min',
        ])
          thresholds[key],
      ],
    };
  }

  Future<Map<dynamic, dynamic>> readCachedFrame(
    int frame,
    Map<String, int> thresholds, {
    String mode = 'nv21_green',
    Map<String, num> luma = const {},
    Map<String, dynamic> detectorConfig = const {},
  }) async {
    final id = _cacheId;
    if (id == null) throw StateError('帧缓存不可用，请重新准备视频');
    final result = await AppPaths.channel
        .invokeMapMethod<dynamic, dynamic>('readAnalysisFrame', {
          'analysis_id': id,
          'frame': frame,
          ...detectorArguments(thresholds, mode, luma, detectorConfig),
        });
    if (result == null) throw StateError('无法读取缓存帧');
    return result;
  }

  Future<Map<String, dynamic>> analyze(
    File video,
    Map<String, int> thresholds, {
    String mode = 'nv21_green',
    Map<String, num> luma = const {},
    Map<String, dynamic> detectorConfig = const {},
    void Function(Map<dynamic, dynamic>)? onFrame,
    bool pacePreview = true,
    int? targetFrame,
    bool cacheAll = false,
    void Function(int)? onProgress,
  }) async {
    if (targetFrame != null && (targetFrame < 1 || targetFrame > 100000)) {
      throw ArgumentError('目标帧超出范围');
    }
    if (targetFrame != null && !Platform.isAndroid) {
      throw UnsupportedError('逐帧定位目前仅支持 Android');
    }
    final common = normalizedDetectorParameters(detectorConfig);
    if (mode != 'nv21_green' && mode != 'luma_ellipse') {
      throw ArgumentError('不支持的离线检测模式：$mode');
    }
    if (_process != null || _androidBusy) throw StateError('已有分析正在运行');
    _cancelled = false;
    if (!await video.exists() || !video.path.toLowerCase().endsWith('.h264')) {
      throw ArgumentError('请选择本地 H.264 录像');
    }
    if (_cancelled) throw StateError('分析已取消');
    if (Platform.isAndroid) {
      _androidBusy = true;
      final id = '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
      if (onFrame != null || onProgress != null) _initFrameHandler();
      if (onFrame != null) _frameListeners[id] = onFrame;
      if (onProgress != null) _progressListeners[id] = onProgress;
      try {
        if (cacheAll) await releaseCache();
        if (_cancelled) throw StateError('分析已取消');
        final result = await AppPaths.channel
            .invokeMapMethod<String, dynamic>('analyzeH264', {
              'path': video.path,
              'analysis_id': id,
              'preview': onFrame != null,
              'pace_preview': pacePreview,
              'target_frame': targetFrame,
              'cache_all': cacheAll,
              ...detectorArguments(thresholds, mode, luma, detectorConfig),
            });
        if (cacheAll && result != null) _cacheId = id;
        if (_cancelled) {
          if (cacheAll) await releaseCache();
          throw StateError('分析已取消');
        }
        if (result == null) throw const FormatException('原生分析无结果');
        final lastPreview = result.remove('last_preview');
        if (lastPreview is Map) onFrame?.call(lastPreview);
        return result;
      } finally {
        _frameListeners.remove(id);
        _progressListeners.remove(id);
        _androidBusy = false;
      }
    }
    if (!Platform.isLinux) throw UnsupportedError('当前仅支持 Android 和 Linux');
    final tool = script ?? defaultScript();
    if (!await tool.exists()) {
      throw StateError('找不到分析脚本：${tool.path}；可设置 DART_LUMA_TUNER');
    }
    if (_cancelled) throw StateError('分析已取消');
    final temp = await Directory.systemTemp.createTemp('dart-luma-analysis-');
    try {
      final config = File('${temp.path}/config.json');
      await config.writeAsString(
        jsonEncode({
          'detector': {...common, 'mode': mode, ...thresholds, ...luma},
        }),
      );
      if (_cancelled) throw StateError('分析已取消');
      final process = await Process.start(python, [
        tool.absolute.path,
        video.absolute.path,
        '--config',
        config.path,
        '--no-prefer-raw',
        '--analyze',
        '--output',
        '${temp.path}/out',
      ]);
      _process = process;
      if (_cancelled) process.kill();
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode.timeout(
        const Duration(minutes: 10),
        onTimeout: () {
          process.kill();
          throw StateError('分析超时');
        },
      );
      final output = await stdoutFuture;
      final error = await stderrFuture;
      if (_cancelled) throw StateError('分析已取消');
      if (code != 0) {
        throw StateError(
          '分析失败：${error.isNotEmpty ? error.trim() : output.trim()}',
        );
      }
      final data = jsonDecode(
        await File('${temp.path}/out/runs.json').readAsString(),
      );
      if (data is! Map<String, dynamic> ||
          data['runs'] is! List ||
          (data['runs'] as List).isEmpty) {
        throw const FormatException('分析结果格式无效');
      }
      return data;
    } finally {
      _process = null;
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }
}
