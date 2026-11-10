import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/preferences/connection_settings.dart';

void main() {
  test(
    'automatic default; advanced route choice persists, corrupt settings recover',
    () {
      final directory = Directory.systemTemp.createTempSync('dart-connect-');
      try {
        final file = File('${directory.path}/connection.json');
        final store = ConnectionSettingsStore(file: file);
        expect(store.load().automatic, isTrue);
        store.save(const ConnectionSettings(automatic: false, bindWifi: false));
        final restored = ConnectionSettingsStore(file: file).load();
        expect(restored.automatic, isFalse);
        expect(restored.bindWifi, isFalse);
        file.writeAsStringSync('{broken');
        expect(store.load().automatic, isTrue);
        file.writeAsStringSync('{"automatic":"false","bind_wifi":0}');
        expect(store.load().automatic, isTrue);
        expect(store.load().bindWifi, isTrue);
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );
}
