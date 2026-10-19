import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_envelope.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';

class Silent implements TelemetrySource {
  @override
  String get label => 'test';
  @override
  void start(void Function(TelemetrySample) onSample) {}
  @override
  Future<void> stop() async {}
}

void main() {
  test(
    'pixel envelopes bound output, preserve spikes and reverse-time order',
    () {
      final envelope = TelemetryEnvelope(0, 99999, 100);
      for (var i = 99999; i >= 0; i--) {
        envelope.add(
          TelemetryPoint(
            i.toDouble(),
            i == 12345
                ? 999
                : i == 12346
                ? -999
                : 0,
          ),
        );
      }
      final points = envelope.points;
      expect(points.length, lessThanOrEqualTo(400));
      expect(points.first.seconds, 99999);
      expect(points.last.seconds, 0);
      expect(points.map((p) => p.value), containsAll([999, -999]));
      for (var i = 1; i < points.length; i++) {
        expect(points[i].seconds, lessThan(points[i - 1].seconds));
      }
    },
  );

  test(
    'large replay uses peak-preserving overview; exact cursor and zoom detail remain raw',
    () async {
      final root = await Directory.systemTemp.createTemp('telemetry-lod-');
      final c = TelemetryController(source: Silent(), window: 1);
      try {
        await File('${root.path}/metadata.json').writeAsString(
          jsonEncode({
            'format': 'dart_telemetry_csv_v1',
            'columns': ['pitch'],
            'complete': true,
          }),
        );
        final csv = StringBuffer(
          'client_elapsed_us,client_received_at,pitch\n',
        );
        for (var i = 0; i <= 30000; i++) {
          csv.writeln(
            '${i * 10000},2026-10-18T00:00:00Z,${i == 12345
                ? 999
                : i == 12346
                ? -999
                : i % 10}',
          );
        }
        await File('${root.path}/samples.csv').writeAsString('$csv');
        await c.openArchive(await TelemetryArchive.open(root));
        expect(await c.archive!.atOrBefore(-1), isNull);
        expect((await c.archive!.atOrBefore(999999999))!.elapsedUs, 300000000);
        c.setChartPixelWidth(80);
        await c.inspectChart(centerUs: 123450000, windowSeconds: 300);
        final coarse = c.seriesFor('pitch', maxPoints: 320);
        expect(coarse.length, lessThanOrEqualTo(320));
        expect(coarse.map((p) => p.value), containsAll([999, -999]));
        // Opening now builds a full overview before the widget measures its
        // width. Reusing that finer preview remains bounded, not all raw rows.
        expect(c.samples.length, lessThanOrEqualTo(2048));
        expect(c.cursorUs, 123450000);
        expect(c.latest!.values['pitch'], 999);
        await c.inspectChart(centerUs: 123450000, windowSeconds: 1);
        final detail = c.seriesFor('pitch', maxPoints: 320);
        expect(detail.length, greaterThan(90));
        expect(detail.map((p) => p.value), containsAll([999, -999]));
        expect(
          c.archive!.rows,
          30001,
        ); // Never decimate the underlying archive.
      } finally {
        c.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
