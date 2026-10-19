import 'dart:io';
import 'app_paths.dart';

/// The native worker streams one session into a ZIP and grants a read-only URI.
class AndroidLogShare {
  static Future<void> share(Directory directory) async {
    if (!await directory.exists()) throw StateError('日志目录不存在');
    await AppPaths.channel.invokeMethod<void>('shareLogZip', {
      'path': directory.absolute.path,
    });
  }
}
