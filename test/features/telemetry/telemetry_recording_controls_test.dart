import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_recording_controls.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';

class SilentSource implements TelemetrySource {
  @override
  String get label => 'silent';
  @override
  void start(void Function(TelemetrySample) onSample) {}
  @override
  Future<void> stop() async {}
}

class PushSource extends SilentSource {
  void Function(TelemetrySample)? receive;
  @override
  void start(void Function(TelemetrySample) onSample) {
    receive = onSample;
  }

  void emit(int seq) => receive?.call(
    TelemetrySample(
      time: DateTime.now(),
      values: {'seq': seq.toDouble(), 'pitch': seq.toDouble()},
    ),
  );
}

/// A deterministic renderer clock; these samples exercise display geometry,
/// while connection_recording_test covers the real writer independently.
class FrameClockRecorder extends TelemetryRecorder {
  FrameClockRecorder(Directory directory) : super(directory: directory);
  int elapsed = 0;
  @override
  int get sessionDurationUs => elapsed;
  @override
  int? add(TelemetrySample sample) => elapsed;
}

void main() {
  for (final secondsTotal in [30, 4]) {
    final center = secondsTotal == 30 ? 20 : 2;
    testWidgets(
      'Pause freezes curves and centers playback for a $secondsTotal second session',
      (tester) async {
        late Directory root;
        late FrameClockRecorder recorder;
        late TelemetryController c;
        final src = PushSource();
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('pause-transform-');
          recorder = FrameClockRecorder(root);
          c = TelemetryController(source: src, recorder: recorder);
          await c.beginConnection('test');
          for (final seconds
              in (secondsTotal == 30
                  ? [10, 15, 20, 25, 30]
                  : [0, 1, 2, 3, 4])) {
            recorder.elapsed = seconds * 1000000;
            src.emit(seconds);
          }
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(child: TelemetryChart(controller: c)),
                  TelemetryRecordingControls(controller: c, timeline: true),
                ],
              ),
            ),
          ),
        );
        dynamic painter() => tester
            .widget<CustomPaint>(
              find.byKey(const ValueKey('telemetry-chart-plot')),
            )
            .painter;
        List<String> points() => (painter().series as Map).entries
            .expand(
              (e) => (e.value as List).map(
                (p) => '${e.key.id}:${p.seconds}:${p.value}',
              ),
            )
            .toList();
        final before = points();
        expect(before, isNotEmpty);
        final right = c.chartRightUs;
        recorder.elapsed =
            (secondsTotal + 5) *
            1000000; // Time passes without another rendered frame.
        src.emit(
          secondsTotal + 5,
        ); // Trim the live ring without painting another frame.
        await tester.tap(find.byKey(const ValueKey('telemetry-pause')));
        await tester.pump();
        expect(c.chartRightUs, right);
        expect(points(), before);
        expect(c.timelineDurationUs, secondsTotal * 1000000);
        expect(c.cursorUs, center * 1000000);
        expect(c.chartFocusUs, center * 1000000);
        expect(c.latest!.values['seq'], center);
        final markers = painter().markers as Map;
        expect(markers.containsKey('播放'), isFalse);
        expect(markers['终点'].$1, secondsTotal);
        expect((c.chartRightUs - c.cursorUs) / (c.chartWindow * 1000000), .5);
        src.emit(secondsTotal + 5);
        await tester.pump();
        expect(points(), before);
        expect(c.latest!.values['seq'], center);
        expect(c.timelineDurationUs, secondsTotal * 1000000);
        expect(c.connected, true);
        expect(recorder.sessionActive, true);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await c.endConnection();
          await recorder.close();
          c.dispose();
          await root.delete(recursive: true);
        });
      },
    );
  }

  testWidgets('dense history repaints the chart while pointer remains down', (
    tester,
  ) async {
    late Directory root;
    late TelemetryArchive archive;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('dense-scrub-');
      await File('${root.path}/metadata.json').writeAsString(
        jsonEncode({
          'format': 'dart_telemetry_csv_v1',
          'columns': ['seq', 'pitch'],
          'complete': true,
        }),
      );
      final csv = StringBuffer(
        'client_elapsed_us,client_received_at,seq,pitch\n',
      );
      for (var i = 0; i <= 12000; i++) {
        csv.writeln(
          '${i * 10000},2026-10-12T00:00:00Z,$i,${sin(i / 70) * 30 + cos(i / 250) * 10}',
        );
      }
      await File('${root.path}/samples.csv').writeAsString(csv.toString());
      archive = await TelemetryArchive.open(root);
    });
    final controller = TelemetryController(source: SilentSource());
    await tester.runAsync(() => controller.openArchive(archive));
    const graphKey = ValueKey('scrub-graph');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: RepaintBoundary(
                  key: graphKey,
                  child: TelemetryChart(controller: controller),
                ),
              ),
              TelemetryRecordingControls(
                controller: controller,
                timeline: true,
              ),
            ],
          ),
        ),
      ),
    );
    final rect = tester.getRect(
      find.byKey(const ValueKey('telemetry-history-slider')),
    );
    late TestGesture gesture;
    await tester.runAsync(() async {
      gesture = await tester.startGesture(
        Offset(rect.left + rect.width * .75, rect.center.dy),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    final firstCursor = controller.cursorUs;
    final firstValue = controller.latest!.values['seq']!;
    final firstPoints = controller.seriesFor('pitch');
    expect(firstCursor, greaterThan(80000000));
    expect(firstPoints.length, greaterThan(1900));
    Future<List<int>> pixels() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(graphKey),
      );
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List().toList();
    }

    final before = (await tester.runAsync(pixels))!;
    await tester.runAsync(() async {
      await gesture.moveTo(
        Offset(rect.left + rect.width * .35, rect.center.dy),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(controller.cursorUs, lessThan(firstCursor));
    expect(controller.latest!.values['seq'], lessThan(firstValue));
    expect(controller.seriesFor('pitch').length, greaterThan(1900));
    final after = (await tester.runAsync(pixels))!;
    expect(
      after,
      isNot(equals(before)),
    ); // Actual rendered pixels, not only slider state.
    await tester.runAsync(() => gesture.up());
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.runAsync(() => root.delete(recursive: true));
  });

  testWidgets(
    'paused slider stays enabled with fixed max, scrubs before pointer up and resumes latest',
    (tester) async {
      late Directory root;
      late TelemetryRecorder recorder;
      late TelemetryController controller;
      final source = PushSource();
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('paused-slider-');
        recorder = TelemetryRecorder(directory: root);
        controller = TelemetryController(source: source, recorder: recorder)
          ..start();
        await controller.beginConnection('test');
        source.emit(1);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        source.emit(2);
        await recorder.flush();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 600,
                child: TelemetryRecordingControls(
                  controller: controller,
                  timeline: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('telemetry-pause')));
      await tester.pump();
      final frozen = controller.timelineDurationUs;
      final sliderFinder = find.byKey(
        const ValueKey('telemetry-history-slider'),
      );
      final frozenMax = tester.widget<Slider>(sliderFinder).max;
      expect(tester.widget<Slider>(sliderFinder).onChanged, isNotNull);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        source.emit(3);
        await recorder.flush();
      });
      await tester.pump();
      expect(recorder.written, 3);
      expect(
        controller.latest,
        isNull,
      ); // Startup window center is before data.
      expect(controller.timelineDurationUs, frozen);
      expect(tester.widget<Slider>(sliderFinder).max, frozenMax);
      final rect = tester.getRect(sliderFinder);
      late TestGesture gesture;
      await tester.runAsync(() async {
        gesture = await tester.startGesture(
          Offset(rect.left + rect.width * 0.75, rect.center.dy),
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      await tester.pump();
      // The pointer is still down: onChangeEnd has not run.
      expect(controller.cursorUs, lessThan(frozen));
      expect(controller.cursorUs, greaterThan(0));
      expect(tester.widget<Slider>(sliderFinder).onChanged, isNotNull);
      final firstPosition = controller.cursorUs;
      await tester.runAsync(() async {
        await gesture.moveTo(
          Offset(rect.left + rect.width * 0.35, rect.center.dy),
        );
        await Future<void>.delayed(const Duration(milliseconds: 160));
      });
      await tester.pump();
      expect(controller.cursorUs, lessThan(firstPosition));
      expect(controller.timelineDurationUs, frozen);
      expect(controller.latest!.values['seq'], lessThan(3));
      await tester.runAsync(() async {
        await gesture.up();
      });
      await tester.tap(find.byKey(const ValueKey('telemetry-resume')));
      await tester.pump();
      expect(controller.latest!.values['seq'], 3);
      expect(controller.timelineDurationUs, greaterThan(frozen));
      expect(controller.followingLatest, true);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      expect(
        controller.followingLatest,
        true,
      ); // No delayed seek can undo Resume.
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await controller.endConnection();
        await recorder.close();
        controller.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await root.delete(recursive: true);
      });
    },
  );

  testWidgets(
    'offline replay controls seek, step and resume to session end at narrow width',
    (tester) async {
      late Directory root;
      late TelemetryArchive archive;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('record-controls-');
        await File('${root.path}/metadata.json').writeAsString(
          jsonEncode({
            'format': 'dart_telemetry_csv_v1',
            'columns': ['seq', 'pitch'],
            'source': '10.0.0.1',
            'complete': true,
          }),
        );
        await File('${root.path}/samples.csv').writeAsString(
          'client_elapsed_us,client_received_at,seq,pitch\n'
          '0,2026-10-12T00:00:00Z,1,1\n'
          '1000000,2026-10-12T00:00:01Z,2,2\n'
          '2000000,2026-10-12T00:00:02Z,3,3\n',
        );
        archive = await TelemetryArchive.open(root);
      });
      final controller = TelemetryController(source: SilentSource());
      await tester.runAsync(() => controller.openArchive(archive));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 480,
                child: TelemetryRecordingControls(
                  controller: controller,
                  timeline: true,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('暂停'), findsOneWidget);
      expect(find.text('恢复'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('telemetry-history-slider')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('telemetry-history-time')),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        await controller.step();
      });
      await tester.pump();
      expect(controller.cursorUs, 1000000);
      expect(controller.latest!.values['seq'], 2);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('恢复'));
      await tester.pump();
      expect(controller.replaying, true);
      expect(controller.archive, same(archive));
      expect(controller.cursorUs, 2000000);
      expect(controller.latest!.values['seq'], 3);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(() async {
        await root.delete(recursive: true);
      });
    },
  );
}
