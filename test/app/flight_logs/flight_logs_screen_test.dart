import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/app/flight_logs/flight_log_controller.dart';
import 'package:dart_control_panel/app/flight_logs/flight_logs_screen.dart';
import 'package:dart_control_panel/features/telemetry/flight_csv_importer.dart';

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
        await FlightCsvImporter.importFile(csv, session);
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
}
