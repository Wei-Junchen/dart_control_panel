import 'package:dart_control_panel/core/platform/app_paths.dart';
import 'dart:convert';
import 'dart:io';

class TelemetryLogSettings {
  const TelemetryLogSettings({
    this.directory,
    this.name = '日志',
    this.tags = const [],
  });
  final String? directory;
  final String name;
  final List<String> tags;
  static List<String> parseTags(String value) => value
      .split(RegExp('[,，]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();
  Map<String, dynamic> toJson() => {
    'version': 1,
    'directory': directory,
    'name': name,
    'tags': tags,
  };
}

class TelemetryLogSettingsStore {
  TelemetryLogSettingsStore({File? file}) : file = file ?? defaultFile();
  final File file;
  static File defaultFile() {
    return File(
      '${AppPaths.configRoot.path}/dart_control_panel/telemetry.json',
    );
  }

  TelemetryLogSettings load() {
    try {
      if (!file.existsSync()) return const TelemetryLogSettings();
      final doc = jsonDecode(file.readAsStringSync());
      if (doc is! Map || doc['version'] != 1) {
        return const TelemetryLogSettings();
      }
      return TelemetryLogSettings(
        directory:
            doc['directory'] is String &&
                (doc['directory'] as String).trim().isNotEmpty
            ? doc['directory'] as String
            : null,
        name: doc['name'] is String ? doc['name'] as String : '日志',
        tags: doc['tags'] is List
            ? List.unmodifiable((doc['tags'] as List).whereType<String>())
            : const [],
      );
    } catch (_) {
      return const TelemetryLogSettings();
    }
  }

  Future<void> save(TelemetryLogSettings settings) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(settings.toJson()), flush: true);
    await tmp.rename(file.path);
  }
}
