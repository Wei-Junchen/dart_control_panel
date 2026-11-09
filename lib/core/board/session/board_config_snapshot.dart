import 'dart:convert';
import 'dart:io';

import 'package:dart_control_panel/core/platform/app_paths.dart';
import 'package:dart_control_panel/core/preferences/device_registry.dart';

/// A read-only observation, not proof of a historical flight configuration.
class BoardConfigSnapshot {
  BoardConfigSnapshot({
    required this.config,
    required this.capturedAt,
    required this.host,
    required this.port,
    this.deviceId,
    this.sn,
    this.source = 'connection',
    this.resolvedRoi,
  });
  final Map<String, dynamic> config;
  final DateTime capturedAt;
  final String host;
  final int port;
  final String? deviceId, sn;
  final String source;
  final List<int>? resolvedRoi;

  Map<String, dynamic> toJson() => {
    'format': 'dart_board_config_snapshot_v1',
    'captured_at': capturedAt.toUtc().toIso8601String(),
    'host': host,
    'port': port,
    'device_id': deviceId,
    'sn': sn,
    'source': source,
    if (resolvedRoi != null) 'resolved_detector_roi': resolvedRoi,
    'config': config,
  };

  static BoardConfigSnapshot? fromJson(Object? value) {
    if (value is! Map ||
        value['format'] != 'dart_board_config_snapshot_v1' ||
        value['config'] is! Map ||
        value['captured_at'] is! String ||
        value['host'] is! String) {
      return null;
    }
    final time = DateTime.tryParse(value['captured_at'] as String);
    if (time == null) return null;
    try {
      return BoardConfigSnapshot(
        config: Map<String, dynamic>.from(value['config'] as Map),
        capturedAt: time,
        host: value['host'] as String,
        port: (value['port'] as num?)?.toInt() ?? 9000,
        deviceId: value['device_id'] is String
            ? value['device_id'] as String
            : null,
        sn: value['sn'] is String ? value['sn'] as String : null,
        resolvedRoi:
            value['resolved_detector_roi'] is List &&
                (value['resolved_detector_roi'] as List).length == 4 &&
                (value['resolved_detector_roi'] as List).every(
                  (v) => v is int && v >= 0 && v <= 4096,
                )
            ? (value['resolved_detector_roi'] as List).cast<int>().toList()
            : null,
        source: value['source'] is String
            ? value['source'] as String
            : 'connection',
      );
    } catch (_) {
      return null;
    }
  }

  static Future<BoardConfigSnapshot?> read(File file) async {
    try {
      if (!await file.exists() || await file.length() > 1048576) return null;
      return fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> write(File file) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    try {
      await temp.writeAsString(jsonEncode(toJson()), flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<File> archive({Directory? root}) async {
    final base =
        root ??
        Directory(
          '${AppPaths.dataRoot.path}/dart_control_panel/config_snapshots',
        );
    final dir = Directory('${base.path}/${safeDeviceDirectory(deviceId)}');
    final file = File(
      '${dir.path}/${capturedAt.toUtc().microsecondsSinceEpoch}_$pid.json',
    );
    await write(file);
    return file;
  }
}
