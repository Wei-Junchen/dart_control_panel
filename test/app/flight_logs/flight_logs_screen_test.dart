import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/app/flight_logs/flight_log_controller.dart';
import 'package:dart_control_panel/app/flight_logs/flight_logs_screen.dart';

void main() {
  testWidgets(
    'offline list exposes replay and deletion requires confirmation',
    (tester) async {
      late Directory temp;
      late FlightLogController c;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('flight-log-ui-');
        final session = Directory('${temp.path}/saved');
        await session.create();
        final csv = File('${session.path}/2.csv');
        await csv.writeAsString(
          'mono_us,uart_pitch,uart_roll,uart_yaw\n100,1,2,3\n200,4,5,6\n',
        );
        await File('${session.path}/flight.json').writeAsString(
          jsonEncode({
            'remote_name': 'flight_2',
            'source_host': 'board.test',
            'files': ['2.csv'],
            'complete': true,
            'copied_at': '2026-10-16T00:00:00Z',
          }),
        );
        c = FlightLogController(
          localRoot: temp,
          settingsFile: File('${temp.path}/settings.json'),
        );
        await c.init();
      });
      tester.view.resetPhysicalSize();
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FlightLogsScreen(
            controller: c,
            onReplay: (archive) async {
              expect(archive.rows, 2);
            },
          ),
        ),
      );
      expect(find.textContaining('自动扫描记录'), findsOneWidget);
      await tester.tap(find.text('本地副本 / 回放'));
      await tester.pumpAndSettle();
      expect(find.textContaining('flight_2 · board.test'), findsOneWidget);
      expect(find.textContaining('未关联（旧记录）'), findsOneWidget);
      final replay = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '遥测回放'),
      );
      expect(replay.onPressed, isNotNull);
      await tester.tap(find.byTooltip('删除本地副本'));
      await tester.pumpAndSettle();
      expect(find.text('删除本地 flight_2？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.local, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.runAsync(() => temp.delete(recursive: true));
    },
  );

  testWidgets('device-filtered log view only lists that device', (
    tester,
  ) async {
    late Directory temp;
    late FlightLogController c;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('flight-log-filter-');
      for (final device in ['dv1_a', 'dv1_b']) {
        final dir = Directory('${temp.path}/$device/saved_$device');
        await dir.create(recursive: true);
        await File(
          '${dir.path}/$device.csv',
        ).writeAsString('mono_us,uart_pitch\n100,1\n200,2\n');
        await File('${dir.path}/flight.json').writeAsString(
          jsonEncode({
            'remote_name': 'flight_$device',
            'source_host': 'board.test',
            'files': ['$device.csv'],
            'complete': true,
            'device_id': device,
            'sn': 'SN-$device',
            'copied_at': '2026-10-16T00:00:00Z',
          }),
        );
      }
      c = FlightLogController(
        localRoot: temp,
        settingsFile: File('${temp.path}/settings.json'),
      );
      await c.init();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: FlightLogsScreen(
          controller: c,
          deviceIdFilter: 'dv1_a',
          deviceLabel: 'SN-dv1_a',
          onReplay: (archive) async {},
        ),
      ),
    );
    await tester.tap(find.text('本地副本 / 回放'));
    await tester.pumpAndSettle();
    expect(find.textContaining('flight_dv1_a'), findsOneWidget);
    expect(find.textContaining('flight_dv1_b'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.runAsync(() => temp.delete(recursive: true));
  });

  testWidgets('unknown group displays only unidentified records', (
    tester,
  ) async {
    late Directory temp;
    late FlightLogController controller;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('flight-unknown-');
      for (final id in ['known', 'unknown']) {
        final dir = Directory('${temp.path}/flight_$id');
        await dir.create(recursive: true);
        await File('${dir.path}/video.mp4').writeAsBytes([1]);
        await File('${dir.path}/flight.json').writeAsString(
          jsonEncode({
            'remote_name': 'flight_$id',
            'files': ['video.mp4'],
            if (id == 'known') 'device_id': 'dv1_known',
            'complete': true,
          }),
        );
      }
      controller = FlightLogController(
        localRoot: temp,
        settingsFile: File('${temp.path}/settings.json'),
      );
      await controller.init();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: FlightLogsScreen(
          controller: controller,
          onReplay: (_) async {},
          unknownOnly: true,
          deviceLabel: 'unknown',
          initialTab: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('flight_unknown · '), findsOneWidget);
    expect(find.textContaining('flight_known'), findsNothing);
    expect(find.text('叠加录像'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.runAsync(() => temp.delete(recursive: true));
  });

  testWidgets('raw video action only appears when raw files exist', (
    tester,
  ) async {
    late Directory temp;
    late FlightLogController c;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('flight-log-video-');
      Future<void> addLog(String name, bool raw) async {
        final dir = Directory('${temp.path}/dv1_a/$name');
        await dir.create(recursive: true);
        await File(
          '${dir.path}/$name.csv',
        ).writeAsString('mono_us,uart_pitch\n100,1\n200,2\n');
        await File('${dir.path}/$name.h264').writeAsBytes(const []);
        if (raw) {
          await File('${dir.path}/$name.raw.h264').writeAsBytes(const []);
        }
        await File('${dir.path}/flight.json').writeAsString(
          jsonEncode({
            'remote_name': 'flight_$name',
            'files': ['$name.csv', '$name.h264', if (raw) '$name.raw.h264'],
            'complete': true,
            'device_id': 'dv1_a',
            'sn': 'DART-A',
          }),
        );
      }

      await addLog('overlay_only', false);
      await addLog('with_raw', true);
      c = FlightLogController(
        localRoot: temp,
        settingsFile: File('${temp.path}/settings.json'),
      );
      await c.init();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: FlightLogsScreen(
          controller: c,
          deviceIdFilter: 'dv1_a',
          deviceLabel: 'DART-A',
          onReplay: (archive) async {},
        ),
      ),
    );
    await tester.tap(find.text('本地副本 / 回放'));
    await tester.pumpAndSettle();
    expect(find.text('叠加录像'), findsNWidgets(2));
    expect(find.text('原始录像'), findsOneWidget);
    if (Platform.isLinux) {
      final tile = find.ancestor(
        of: find.textContaining('with_raw ·'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: tile,
          matching: find.byKey(const ValueKey('analyze-h264')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('H.264 离线分析'), findsOneWidget);
      await tester.tap(find.byTooltip('分析说明'));
      await tester.pumpAndSettle();
      expect(find.textContaining('with_raw.raw.h264'), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.runAsync(() => temp.delete(recursive: true));
  });
}
