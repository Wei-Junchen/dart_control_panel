import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:dart_control_panel/core/platform/app_paths.dart';

String safeDeviceDirectory(String? deviceId) {
  final value = (deviceId ?? '').trim();
  if (value.isEmpty) return '_unknown';
  final safe = value
      .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')
      .replaceAll(RegExp(r'^\.+'), '_');
  return safe.isEmpty
      ? '_unknown'
      : safe.substring(0, safe.length.clamp(1, 96));
}

class DeviceRecord {
  const DeviceRecord({
    required this.deviceId,
    this.sn,
    this.status = 'UNKNOWN',
    this.host,
    this.port = 9000,
    this.lastSeen,
  });

  final String deviceId;
  final String? sn;
  final String status;
  final String? host;
  final int port;
  final DateTime? lastSeen;

  String get label => sn?.isNotEmpty == true ? sn! : deviceId;

  factory DeviceRecord.fromJson(Map<String, dynamic> json) => DeviceRecord(
    deviceId: json['device_id'] is String ? json['device_id'] as String : '',
    sn: json['sn'] is String ? json['sn'] as String : null,
    status: json['status'] is String ? json['status'] as String : 'UNKNOWN',
    host: json['host'] is String ? json['host'] as String : null,
    port: json['port'] is num ? (json['port'] as num).toInt() : 9000,
    lastSeen: json['last_seen'] is String
        ? DateTime.tryParse(json['last_seen'] as String)
        : null,
  );

  Map<String, dynamic> toJson() => {
    'device_id': deviceId,
    'sn': sn,
    'status': status,
    'host': host,
    'port': port,
    'last_seen': lastSeen?.toUtc().toIso8601String(),
  };
}

/// Persistent mapping between board device_id and its business SN/last endpoint.
/// Directory partitioning uses [safeDeviceDirectory] so a malformed device_id
/// can never escape the selected local root.
class DeviceRegistry extends ChangeNotifier {
  DeviceRegistry({File? file}) : file = file ?? _defaultFile();

  final File file;

  static final DeviceRegistry instance = DeviceRegistry();

  static File _defaultFile() =>
      File('${AppPaths.configRoot.path}/dart_control_panel/devices.json');

  static const int maxEntries = 64;

  List<DeviceRecord> load() {
    if (!file.existsSync()) return const [];
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return const [];
      final records = <DeviceRecord>[];
      for (final entry in decoded) {
        if (entry is Map) {
          final record = DeviceRecord.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (record.deviceId.isNotEmpty) records.add(record);
        }
      }
      records.sort((a, b) {
        final at = a.lastSeen?.microsecondsSinceEpoch ?? 0;
        final bt = b.lastSeen?.microsecondsSinceEpoch ?? 0;
        return bt.compareTo(at);
      });
      return records;
    } catch (_) {
      return const [];
    }
  }

  Future<void> remember({
    required String deviceId,
    String? sn,
    String? status,
    String? host,
    int port = 9000,
  }) async {
    if (deviceId.isEmpty) return;
    final records = load().where((r) => r.deviceId != deviceId).toList();
    records.insert(
      0,
      DeviceRecord(
        deviceId: deviceId,
        sn: sn,
        status: status ?? 'UNKNOWN',
        host: host,
        port: port,
        lastSeen: DateTime.now().toUtc(),
      ),
    );
    if (records.length > maxEntries) {
      records.removeRange(maxEntries, records.length);
    }
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode([for (final record in records) record.toJson()]),
        flush: true,
      );
      await tmp.rename(file.path);
      notifyListeners();
    } catch (_) {
      // Best-effort persistence; never break a live connection over this file.
    }
  }

  Future<void> remove(String deviceId) async {
    final records = load().where((r) => r.deviceId != deviceId).toList();
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode([for (final record in records) record.toJson()]),
        flush: true,
      );
      await tmp.rename(file.path);
      notifyListeners();
    } catch (_) {}
  }

  DeviceRecord? find(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) return null;
    for (final record in load()) {
      if (record.deviceId == deviceId) return record;
    }
    return null;
  }
}
