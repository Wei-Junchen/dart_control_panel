import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/flight_csv_importer.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';

class SilentSource implements TelemetrySource {
  @override
  String get label => 'test';
  @override
  void start(void Function(TelemetrySample) onSample) {}
  @override
  Future<void> stop() async {}
}

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('flight-csv-test-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  Future<File> raw(String text) async =>
      File('${temp.path}/42.csv').writeAsString(text);
  test(
    'dynamic board columns, monotonic origin, attitude aliases and indexed replay',
    () async {
      final source = await raw(
        'seq,mono_us,frame,vision_mono_us,uart_pitch,uart_roll,uart_yaw,capture_fps,uart_rx_working_flag,uart_rx_custom,uart_schema\n'
        '1,1000000,10,900000,1,2,3,10,1,99,"field:type|other:type"\n'
        '2,1100000,11,1000000,4,5,6,10,0,101,"field:type|other:type"\n',
      );
      final archive = await FlightCsvImporter.importFile(
        source,
        Directory('${temp.path}/archive'),
      );
      expect(archive.rows, 2);
      expect(archive.durationUs, 100000);
      expect(archive.metadata['board_first_mono_us'], 1000000);
      expect(archive.metadata['flight_wall_clock_known'], false);
      expect(archive.metadata['estimated_video_fps'], 10);
      expect(
        archive.columns,
        containsAll(['pitch', 'roll', 'yaw', 'fps', 'uart_rx_custom']),
      );
      final rows = await archive.range(0, 100000).toList();
      expect(rows.last.sample.valueOf('pitch'), 4);
      expect(rows.last.sample.valueOf('uart_rx_custom'), 101);
      expect(rows.first.sample.time.microsecondsSinceEpoch, 0);
      expect(await source.readAsString(), contains('uart_schema'));
      final controller = TelemetryController(source: SilentSource());
      await controller.openArchive(archive);
      await controller.seek(100000);
      expect(controller.attitude, (pitch: 4.0, roll: 5.0, yaw: 6.0));
      expect(controller.offlineReplay, true);
      controller.dispose();
    },
  );
  test('rejects time regression and never publishes replay metadata', () async {
    final source = await raw('mono_us,uart_pitch\n20,1\n10,2\n');
    final dir = Directory('${temp.path}/invalid');
    await expectLater(
      FlightCsvImporter.importFile(source, dir),
      throwsFormatException,
    );
    expect(await File('${dir.path}/metadata.json').exists(), false);
  });
  test('rejects truncated rows and keeps original', () async {
    final source = await raw('mono_us,uart_pitch\n20\n');
    await expectLater(
      FlightCsvImporter.importFile(source, Directory('${temp.path}/invalid')),
      throwsFormatException,
    );
    expect(await source.exists(), true);
  });
  test('accepts quoted legacy schema and CRLF with BOM', () async {
    final source = await raw(
      '\uFEFFmono_us,uart_rx_pitch,uart_schema\r\n123,7,"name,with,comma"\r\n',
    );
    final archive = await FlightCsvImporter.importFile(
      source,
      Directory('${temp.path}/legacy'),
    );
    expect(archive.rows, 1);
    expect((await archive.range(0, 0).first).sample.valueOf('pitch'), 7);
  });
  test('rejects duplicate headers and empty logs', () async {
    final source = await raw('mono_us,mono_us\n1,1\n');
    await expectLater(
      FlightCsvImporter.importFile(source, Directory('${temp.path}/dupe')),
      throwsFormatException,
    );
    final empty = await raw('mono_us,pitch\n');
    await expectLater(
      FlightCsvImporter.importFile(empty, Directory('${temp.path}/empty')),
      throwsFormatException,
    );
  });
}
