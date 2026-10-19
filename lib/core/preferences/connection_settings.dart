import 'dart:convert';
import 'dart:io';
import 'package:dart_control_panel/core/platform/app_paths.dart';

class ConnectionSettings {
  const ConnectionSettings({this.automatic = true, this.bindWifi = true});
  final bool automatic;
  final bool bindWifi;
}

class ConnectionSettingsStore {
  ConnectionSettingsStore({File? file})
    : file =
          file ??
          File(
            '${AppPaths.configRoot.path}/dart_control_panel/connection.json',
          );
  ConnectionSettingsStore.memory() : file = null;
  final File? file;
  ConnectionSettings _memory = const ConnectionSettings();
  ConnectionSettings load() {
    final file = this.file;
    if (file == null) return _memory;
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return const ConnectionSettings();
      return ConnectionSettings(
        automatic: json['automatic'] is bool ? json['automatic'] : true,
        bindWifi: json['bind_wifi'] is bool ? json['bind_wifi'] : true,
      );
    } catch (_) {
      return const ConnectionSettings();
    }
  }

  // Small, infrequent UI setting; synchronous write avoids overlapping saves.
  void save(ConnectionSettings settings) {
    _memory = settings;
    final file = this.file;
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'automatic': settings.automatic,
          'bind_wifi': settings.bindWifi,
        }),
      );
    } catch (_) {
      /* Preferences are best effort, never block connecting. */
    }
  }
}
