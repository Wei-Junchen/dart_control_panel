import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/preferences/telemetry_view_settings.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_screen.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';

class _Source implements TelemetrySource {
  @override
  String get label => 'preferences-test';
  @override
  void start(void Function(TelemetrySample) onSample) {}
  @override
  Future<void> stop() async {}
}

void main() {
  late Directory root;
  late File file;
  setUp(() {
    root = Directory.systemTemp.createTempSync('telemetry-view-test-');
    file = File('${root.path}/preferences/view.json');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('multiple, unknown and empty channels survive disk roundtrip', () {
    final store = TelemetryViewSettingsStore(file: file);
    expect(store.load().channels, ['pitch', 'roll', 'yaw']);
    expect(
      store.save(
        const TelemetryViewSettings(
          channels: ['pitch', 'fps', 'uart_rx_new_sensor', 'fps'],
        ),
      ),
      isTrue,
    );
    expect(TelemetryViewSettingsStore(file: file).load().channels, [
      'pitch',
      'fps',
      'uart_rx_new_sensor',
    ]);
    store.save(const TelemetryViewSettings(channels: [], remember: false));
    expect(store.load().channels, isEmpty);
    expect(store.load().remember, isFalse);
    expect(
      root.listSync(recursive: true).where((f) => f.path.contains('.tmp.')),
      isEmpty,
    );
  });

  test('corrupt or invalid settings safely use initial curves', () {
    file.parent.createSync(recursive: true);
    final store = TelemetryViewSettingsStore(file: file);
    for (final input in [
      '{',
      '{"version":2,"channels":["fps"]}',
      '{"version":1,"channels":[1]}',
      '{"version":1,"channels":[""]}',
      'x' * 65537,
    ]) {
      file.writeAsStringSync(input);
      expect(store.load().channels, ['pitch', 'roll', 'yaw']);
    }
  });

  test('failed save is reported without throwing', () {
    final blocker = File('${root.path}/blocker')..writeAsStringSync('file');
    final store = TelemetryViewSettingsStore(
      file: File('${blocker.path}/view'),
    );
    expect(store.save(const TelemetryViewSettings()), isFalse);
    expect(store.error, isNotNull);
    expect(blocker.readAsStringSync(), 'file');
  });

  testWidgets('autosave debounces and restores several curves after restart', (
    tester,
  ) async {
    final store = TelemetryViewSettingsStore(file: file);
    final c = TelemetryController(source: _Source(), viewSettingsStore: store);
    c.toggleChannel('fps');
    c.toggleChannel('process_ms');
    c.toggleChannel('pitch');
    expect(file.existsSync(), isFalse);
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.load().channels.toSet(), c.selected);
    c.dispose();
    final reopened = TelemetryController(
      source: _Source(),
      viewSettingsStore: TelemetryViewSettingsStore(file: file),
    );
    expect(reopened.selected, {'roll', 'yaw', 'fps', 'process_ms'});
    reopened.dispose();
  });

  test('dispose flushes pending edits and retains unavailable channels', () {
    final store = TelemetryViewSettingsStore(file: file);
    final c = TelemetryController(source: _Source(), viewSettingsStore: store);
    c.toggleChannel('uart_rx_future');
    c.dispose();
    final reopened = TelemetryController(
      source: _Source(),
      viewSettingsStore: store,
    );
    expect(reopened.selected, contains('uart_rx_future'));
    reopened.dispose();
  });

  testWidgets(
    'disable remember preserves default; manual save/load still work',
    (tester) async {
      final store = TelemetryViewSettingsStore.memory();
      final c = TelemetryController(
        source: _Source(),
        viewSettingsStore: store,
      );
      c.toggleChannel('fps');
      c.saveDefaultChannels();
      final saved = c.selected;
      c.setRememberChannels(false);
      c.toggleChannel('process_ms');
      await tester.pump(const Duration(milliseconds: 400));
      expect(store.load().channels.toSet(), saved);
      c.loadDefaultChannels();
      expect(c.selected, saved);
      c.toggleChannel('process_ms');
      expect(c.saveDefaultChannels(), isTrue);
      expect(store.load().channels, contains('process_ms'));
      c.restoreInitialChannels();
      expect(c.selected, {'pitch', 'roll', 'yaw'});
      expect(store.load().channels, contains('process_ms'));
      c.setRememberChannels(true);
      expect(store.load().channels.toSet(), c.selected);
      c.dispose();
    },
  );

  test('empty selection remains empty across restart', () {
    final store = TelemetryViewSettingsStore.memory();
    final c = TelemetryController(source: _Source(), viewSettingsStore: store);
    for (final id in c.selected.toList()) {
      c.toggleChannel(id);
    }
    c.dispose();
    final reopened = TelemetryController(
      source: _Source(),
      viewSettingsStore: store,
    );
    expect(reopened.selected, isEmpty);
    reopened.dispose();
  });

  test(
    'opening different logs keeps multi-curve defaults and missing fields',
    () async {
      final store = TelemetryViewSettingsStore.memory();
      store.save(
        const TelemetryViewSettings(channels: ['pitch', 'fps', 'future']),
      );
      final c = TelemetryController(
        source: _Source(),
        viewSettingsStore: store,
      );
      try {
        for (final fields in [
          ['pitch', 'fps'],
          ['pitch', 'fps', 'future'],
        ]) {
          final log = Directory('${root.path}/log${fields.length}')
            ..createSync();
          File('${log.path}/metadata.json').writeAsStringSync(
            jsonEncode({
              'format': 'dart_telemetry_csv_v1',
              'columns': fields,
              'complete': true,
            }),
          );
          File('${log.path}/samples.csv').writeAsStringSync(
            'client_elapsed_us,client_received_at,${fields.join(',')}\n'
            '0,2026-10-18T00:00:00Z,${fields.map((_) => '1').join(',')}\n'
            '10000,2026-10-18T00:00:00Z,${fields.map((_) => '2').join(',')}\n',
          );
          await c.openArchive(await TelemetryArchive.open(log));
          expect(c.selected, {'pitch', 'fps', 'future'});
          for (final field in fields) {
            expect(c.seriesFor(field), isNotEmpty);
          }
        }
        expect(c.channels.map((field) => field.id), contains('future'));
      } finally {
        c.dispose();
      }
    },
  );

  testWidgets('preferences menu offers load, save, reset and remember', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = TelemetryViewSettingsStore.memory();
    store.save(const TelemetryViewSettings(channels: ['fps', 'process_ms']));
    final c = TelemetryController(source: _Source(), viewSettingsStore: store);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TelemetryScreen(controller: c)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('telemetry-view-preferences')));
    await tester.pumpAndSettle();
    expect(find.text('自动记住曲线选择'), findsOneWidget);
    expect(find.text('保存当前为默认'), findsOneWidget);
    expect(find.text('加载默认曲线'), findsOneWidget);
    await tester.tap(find.text('恢复初始曲线'));
    await tester.pumpAndSettle();
    expect(c.selected, {'pitch', 'roll', 'yaw'});
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
