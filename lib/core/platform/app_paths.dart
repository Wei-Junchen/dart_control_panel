import 'dart:io';
import 'package:flutter/services.dart';

/// Bootstrap Android's app-owned writable paths before constructing stores.
/// Desktop paths remain compatible with the existing installations.
class AppPaths {
  static const channel = MethodChannel(
    'com.litwei.dart_control_panel/platform',
  );
  static Directory? _mobileConfig, _mobileData;
  static Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    final paths = await channel.invokeMapMethod<String, String>('paths');
    if (paths?['config'] == null || paths?['data'] == null) {
      throw StateError('Android storage initialization failed');
    }
    _mobileConfig = Directory(paths!['config']!);
    _mobileData = Directory(paths['data']!);
    await _mobileConfig!.create(recursive: true);
    await _mobileData!.create(recursive: true);
  }

  static Directory get configRoot {
    if (_mobileConfig != null) return _mobileConfig!;
    final env = Platform.environment;
    return Directory(
      Platform.isWindows
          ? env['APPDATA'] ?? env['USERPROFILE'] ?? '.'
          : env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? '.'}/.config',
    );
  }

  static Directory get dataRoot {
    if (_mobileData != null) return _mobileData!;
    final env = Platform.environment;
    return Directory(
      Platform.isWindows
          ? env['LOCALAPPDATA'] ?? env['USERPROFILE'] ?? '.'
          : env['XDG_DATA_HOME'] ?? '${env['HOME'] ?? '.'}/.local/share',
    );
  }

  static Future<void> prepareWifi({bool bindWifi = true}) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod<bool>(
        bindWifi ? 'bindWifi' : 'useSystemNetwork',
      );
    }
  }
}
