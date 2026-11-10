import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/core/preferences/device_registry.dart';

void main() {
  test('device registry persists device_id, SN and last endpoint', () async {
    final temp = await Directory.systemTemp.createTemp('device-registry-');
    addTearDown(() => temp.delete(recursive: true));
    final registry = DeviceRegistry(file: File('${temp.path}/devices.json'));
    await registry.remember(
      deviceId: 'dv1_abc',
      sn: 'DART-1',
      status: 'READY',
      host: '10.0.0.1',
      port: 9000,
    );
    await registry.remember(
      deviceId: 'dv1_def',
      sn: 'DART-2',
      status: 'SETUP',
      host: '10.0.0.2',
    );
    final records = registry.load();
    expect(records, hasLength(2));
    expect(records.first.deviceId, 'dv1_def');
    expect(registry.find('dv1_abc')!.sn, 'DART-1');
    expect(registry.find('dv1_abc')!.host, '10.0.0.1');
    await registry.remove('dv1_def');
    expect(registry.load().single.deviceId, 'dv1_abc');
  });

  test('unsafe device_id cannot escape the selected root', () {
    expect(safeDeviceDirectory('../evil/path'), isNot(contains('/')));
    expect(safeDeviceDirectory(''), '_unknown');
  });
}
