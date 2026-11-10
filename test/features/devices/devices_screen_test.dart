import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/core/board/models/daemon_state.dart';
import 'package:dart_control_panel/core/board/session/board_session.dart';
import 'package:dart_control_panel/core/preferences/device_registry.dart';
import 'package:dart_control_panel/features/devices/devices_screen.dart';

class FakeConnectedSession extends BoardSession {
  FakeConnectedSession(this._state) {
    host = '10.0.0.1';
  }

  final DaemonState _state;

  @override
  bool get connected => true;
  @override
  DaemonState? get state => _state;
  @override
  bool get connecting => false;
  @override
  bool get busy => false;
}

void main() {
  testWidgets('current device button is disabled and rows open logs', (
    tester,
  ) async {
    final temp = await tester.runAsync(
      () => Directory.systemTemp.createTemp('devices-screen-'),
    );
    addTearDown(() => temp!.delete(recursive: true));
    final registry = DeviceRegistry(file: File('${temp!.path}/devices.json'));
    await tester.runAsync(() async {
      await registry.remember(
        deviceId: 'dv1_a',
        sn: 'DART-A',
        status: 'READY',
        host: '10.0.0.1',
      );
      await registry.remember(
        deviceId: 'dv1_b',
        sn: 'DART-B',
        status: 'READY',
        host: '10.0.0.2',
      );
    });
    final state = DaemonState.fromEnvelope({
      'v': 1,
      'payload': {
        'device': {'device_id': 'dv1_a', 'sn': 'DART-A', 'status': 'READY'},
      },
    });
    final session = FakeConnectedSession(state);
    DeviceRecord? opened;
    var openedAll = false;
    var openedUnknown = false;
    await tester.pumpWidget(
      MaterialApp(
        home: DevicesScreen(
          registry: registry,
          session: session,
          onConnect: (host, port) {},
          onOpenLogs: (record) => opened = record,
          onOpenAllLogs: () => openedAll = true,
          onOpenUnknownLogs: () => openedUnknown = true,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('all-flight-logs')));
    expect(openedAll, isTrue);
    await tester.tap(find.byKey(const ValueKey('unknown-device')));
    expect(openedUnknown, isTrue);
    final connected = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '已连接'),
    );
    expect(connected.onPressed, isNull);
    final other = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '连接'),
    );
    expect(other.onPressed, isNotNull);
    await tester.tap(find.text('DART-B · READY'));
    await tester.pumpAndSettle();
    expect(opened!.deviceId, 'dv1_b');
  });
}
