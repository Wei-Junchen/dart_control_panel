import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';

void main() {
  test('telemetry sessions are stored under device_id', () async {
    final root = await Directory.systemTemp.createTemp('telemetry-device-');
    addTearDown(() => root.delete(recursive: true));
    final recorder = TelemetryRecorder(directory: root)
      ..deviceId = 'dv1_0123456789abcdef0123456789abcdef';
    await recorder.beginSession('10.0.0.1:9000');
    expect(
      recorder.sessionDirectory!.path,
      startsWith(
        '${root.path}/dv1_0123456789abcdef0123456789abcdef/connection_',
      ),
    );
    await recorder.endSession();
    await recorder.close();
  });
}
