import 'dart:io';
import 'package:dart_control_panel/core/platform/app_paths.dart';

/// Native MediaMuxer runs on a dedicated Android executor, never Flutter's UI.
class AndroidH264Remuxer {
  static Future<File> convert(File raw, double fps) async {
    if (!fps.isFinite || fps < 1 || fps > 1000) {
      throw ArgumentError('帧率应在1..1000之间');
    }
    if (!raw.path.toLowerCase().endsWith('.h264')) {
      throw ArgumentError('需要 H.264 原文件');
    }
    final source = await raw.resolveSymbolicLinks();
    final info = await AppPaths.channel.invokeMapMethod<String, dynamic>(
      'remuxH264',
      {'path': raw.path, 'fps': fps},
    );
    final expected = '${source.substring(0, source.length - 5)}.mp4';
    if (info?['path'] != expected ||
        !await File(expected).exists() ||
        await File(expected).length() == 0) {
      throw StateError('MP4 封装未生成有效文件');
    }
    return File(expected);
  }
}
