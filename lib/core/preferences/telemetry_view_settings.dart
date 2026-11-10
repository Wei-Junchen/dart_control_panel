import 'dart:convert';
import 'dart:io';
import 'package:dart_control_panel/core/platform/app_paths.dart';

class TelemetryViewSettings {
  const TelemetryViewSettings({
    this.channels = const ['pitch', 'roll', 'yaw'],
    this.remember = true,
  });
  final List<String> channels;
  final bool remember;
}

/// Only explicit UI changes are persisted; never runs on the UDP sample path.
class TelemetryViewSettingsStore {
  TelemetryViewSettingsStore({File? file})
    : file =
          file ??
          File(
            '${AppPaths.configRoot.path}/dart_control_panel/telemetry_view.json',
          );
  TelemetryViewSettingsStore.memory() : file = null;
  final File? file;
  TelemetryViewSettings _memory = const TelemetryViewSettings();
  String? error;
  TelemetryViewSettings load() {
    if (file == null) return _memory;
    try {
      if (file!.lengthSync() > 65536) return const TelemetryViewSettings();
      final doc = jsonDecode(file!.readAsStringSync());
      if (doc is! Map || doc['version'] != 1 || doc['channels'] is! List) {
        return const TelemetryViewSettings();
      }
      final raw = doc['channels'] as List;
      if (raw.length > 512 ||
          raw.any((c) => c is! String || c.trim().isEmpty || c.length > 256)) {
        return const TelemetryViewSettings();
      }
      return TelemetryViewSettings(
        channels: List.unmodifiable(raw.cast<String>().toSet()),
        remember: doc['remember'] is bool ? doc['remember'] : true,
      );
    } catch (_) {
      return const TelemetryViewSettings();
    }
  }

  bool save(TelemetryViewSettings settings) {
    _memory = TelemetryViewSettings(
      channels: List.unmodifiable(settings.channels),
      remember: settings.remember,
    );
    error = null;
    if (file == null) return true;
    final temporary = File('${file!.path}.tmp.$pid');
    try {
      file!.parent.createSync(recursive: true);
      temporary.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'remember': settings.remember,
          'channels': settings.channels,
        }),
        flush: true,
      );
      temporary.renameSync(file!.path);
      return true;
    } catch (e) {
      error = '$e';
      try {
        if (temporary.existsSync()) temporary.deleteSync();
      } catch (_) {}
      return false;
    }
  }
}
