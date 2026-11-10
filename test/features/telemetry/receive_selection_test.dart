import 'dart:convert';
import 'dart:async';
import 'package:dart_control_panel/core/preferences/telemetry_log_settings.dart';
import 'package:flutter/material.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_save_dialog.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_chart.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_recording_controls.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';

class Push implements TelemetrySource {
  void Function(TelemetrySample)? receive;
  int starts = 0, stops = 0;
  @override
  String get label => 'push';
  @override
  void start(void Function(TelemetrySample) f) {
    receive = f;
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  void emit(int seq) => receive?.call(
    TelemetrySample(
      time: DateTime.now(),
      values: {'seq': seq.toDouble(), 'pitch': seq.toDouble()},
    ),
  );
}

void main() {
  testWidgets(
    'save form chooses directory, name and tags and persists defaults without losing time metadata',
    (tester) async {
      late Directory root;
      late TelemetryRecorder recorder;
      late TelemetryController controller;
      late TelemetryLogSettingsStore store;
      final source = Push();
      late String started;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('save-form-');
        store = TelemetryLogSettingsStore(
          file: File('${root.path}/config/telemetry.json'),
        );
        recorder = TelemetryRecorder(
          directory: Directory('${root.path}/staging'),
          settingsStore: store,
        );
        controller = TelemetryController(source: source, recorder: recorder);
        await controller.beginConnection('test');
        source.emit(1);
        await controller.endConnection();
        started =
            (await TelemetryArchive.open(
                  controller.pendingRecording!,
                )).metadata['started_at']
                as String;
      });
      late BuildContext page;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              page = context;
              return const Scaffold();
            },
          ),
        ),
      );
      await tester.runAsync(() async {
        unawaited(showTelemetrySaveDialog(page, controller));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('log-save-directory')),
        '${root.path}/chosen',
      );
      await tester.enterText(
        find.byKey(const ValueKey('log-save-name')),
        '试飞A',
      );
      await tester.enterText(
        find.byKey(const ValueKey('log-save-tags')),
        '室外, 晴天，室外',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('保存完整日志'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(controller.pendingRecording, isNull);
      expect(
        controller.archive!.directory.path,
        startsWith('${root.path}/chosen/'),
      );
      expect(controller.archive!.directory.path, endsWith('_试飞A'));
      expect(controller.archive!.metadata['tags'], ['室外', '晴天']);
      expect(controller.archive!.metadata['started_at'], started);
      expect(controller.archive!.metadata['ended_at'], isNotNull);
      expect(store.load().name, '试飞A');
      expect(store.load().tags, ['室外', '晴天']);
      expect(store.load().directory, '${root.path}/chosen');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await controller.endConnection();
        await recorder.close();
        controller.dispose();
        await root.delete(recursive: true);
      });
    },
  );

  testWidgets(
    'save dialog has three constrained sliders and only endpoint chart markers',
    (tester) async {
      late Directory root;
      late TelemetryController controller;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('save-dialog-');
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
        for (var i = 0; i <= 100; i++) {
          csv.writeln('${i * 1000000},2026-10-12T00:00:00Z,$i');
        }
        await File('${root.path}/samples.csv').writeAsString(csv.toString());
        controller = TelemetryController(source: Push())
          ..pendingRecording = root;
      });
      late BuildContext pageContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              pageContext = context;
              return const Scaffold();
            },
          ),
        ),
      );
      await tester.runAsync(() async {
        unawaited(showTelemetrySaveDialog(pageContext, controller));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(find.text('保存完整日志'), findsOneWidget);
      final start = find.byKey(const ValueKey('telemetry-start-slider'));
      final end = find.byKey(const ValueKey('telemetry-end-slider'));
      final play = find.byKey(const ValueKey('telemetry-history-slider'));
      expect(start, findsOneWidget);
      expect(end, findsOneWidget);
      expect(play, findsOneWidget);
      final rect = tester.getRect(
        find.byKey(const ValueKey("telemetry-selection-timeline")),
      );
      await tester.runAsync(() async {
        final gesture = await tester.startGesture(tester.getCenter(start));
        await gesture.moveTo(
          Offset(rect.left + rect.width * .25, rect.top + 14),
        );
        await gesture.up();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(controller.chartFocusUs, controller.selectionStartUs);
      expect(controller.selectionStartUs, greaterThan(0));
      expect(
        controller.selectionStartUs,
        lessThanOrEqualTo(controller.cursorUs),
      );
      expect(controller.cursorUs, lessThanOrEqualTo(controller.selectionEndUs));
      final dynamic painter = tester
          .widget<CustomPaint>(
            find
                .descendant(
                  of: find.byType(TelemetryChart),
                  matching: find.byKey(const ValueKey('telemetry-chart-plot')),
                )
                .first,
          )
          .painter;
      expect((painter.markers as Map).length, 2);
      expect((painter.markers as Map).containsKey('播放'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await tester.tap(find.text('取消'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(controller.pendingRecording, isNotNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'no UDP switch; disconnect exposes manual save without a dialog',
    (tester) async {
      late Directory root;
      late TelemetryRecorder recorder;
      late TelemetryController c;
      final src = Push();
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('disconnect-ui-');
        recorder = TelemetryRecorder(directory: root);
        c = TelemetryController(source: src, recorder: recorder);
        await c.beginConnection('test');
        src.emit(1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        src.emit(2);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TelemetryRecordingControls(controller: c),
                TelemetryRecordingControls(controller: c, timeline: true),
              ],
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('telemetry-receive-switch')),
        findsNothing,
      );
      expect(find.text('接收 UDP'), findsNothing);
      await tester.runAsync(c.endConnection);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('保存接收日志'), findsOneWidget);
      expect(find.byTooltip('播放选区'), findsOneWidget);
      final archive = c.archive;
      await tester.runAsync(() async {
        final first = await archive!.range(0, c.timelineDurationUs).first;
        await c.seekTimeline(first.elapsedUs);
        c.resumeDisplay();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(c.archive, same(archive));
      expect(c.latest!.values['pitch'], 2);
      expect(c.timelineCursorUs, c.timelineDurationUs);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await recorder.close();
        c.dispose();
        await root.delete(recursive: true);
      });
    },
  );

  test(
    'disconnect retains complete replay cache; cancel is non-destructive; reconnect starts a fresh session',
    () async {
      final root = await Directory.systemTemp.createTemp('receive-selection-');
      final src = Push();
      final recorder = TelemetryRecorder(directory: root);
      final c = TelemetryController(source: src, recorder: recorder);
      try {
        await c.beginConnection('test');
        src.emit(1);
        await Future<void>.delayed(const Duration(milliseconds: 15));
        src.emit(2);
        await c.endConnection();
        final original = c.pendingRecording!;
        final count = recorder.written;
        src.emit(99);
        expect(recorder.written, count);
        expect(c.connected, false);
        expect(c.archive, isNotNull);
        expect(c.playbackToUs, greaterThan(0));
        final first = await c.archive!.range(0, c.timelineDurationUs).first;
        await c.seekTimeline(first.elapsedUs);
        expect(c.latest!.values['pitch'], 1);
        await c.seekTimeline(c.timelineDurationUs);
        expect(c.latest!.values['pitch'], 2);
        await c.prepareSave();
        await c.decideRecording(save: false);
        expect(await original.exists(), true);
        expect(c.pendingRecording!.path, original.path);
        expect(c.latest!.values['pitch'], 2);
        await c.endConnection(); // Idempotent: no data clearing.
        expect(c.pendingRecording!.path, original.path);
        await c.beginConnection('test-new');
        expect(c.followingLatest, true);
        expect(c.pendingRecording, isNull);
        expect(c.latest, isNull);
        src.emit(3);
        await c.endConnection();
        await c.prepareSave();
        final cached = c.pendingRecording!;
        await c.decideRecording(save: true);
        expect(await cached.exists(), false);
        expect(await c.archive!.directory.exists(), true);
        expect(c.pendingRecording, isNull);
        expect(c.archive!.metadata['log_name'], isNotEmpty);
        expect(await original.exists(), true);
      } finally {
        await c.endConnection();
        await recorder.close();
        c.dispose();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'start <= play <= end; dragging each marker centers its own time; crop preserves only selection',
    () async {
      final root = await Directory.systemTemp.createTemp('selection-');
      final original = Directory('${root.path}/original');
      await original.create();
      await File('${original.path}/metadata.json').writeAsString(
        jsonEncode({
          'format': 'dart_telemetry_csv_v1',
          'columns': ['pitch'],
          'complete': true,
        }),
      );
      final csv = StringBuffer('client_elapsed_us,client_received_at,pitch\n');
      for (var i = 0; i <= 100; i++) {
        csv.writeln('${i * 1000000},2026-10-12T00:00:00Z,$i');
      }
      await File('${original.path}/samples.csv').writeAsString(csv.toString());
      final recorder = TelemetryRecorder(directory: root);
      final c = TelemetryController(source: Push(), recorder: recorder);
      try {
        c.pendingRecording = original;
        await c.prepareSave();
        await c.seekTimeline(50000000);
        await c.moveSelection(true, 20000000);
        expect(c.chartFocusUs, 20000000);
        expect(c.cursorUs, 50000000);
        expect(c.latest!.values['pitch'], 50);
        await c.moveSelection(false, 80000000);
        expect(c.chartFocusUs, 80000000);
        await c.seekTimeline(90000000);
        expect(c.cursorUs, 80000000);
        expect(c.chartFocusUs, 80000000);
        await c.moveSelection(true, 95000000);
        expect(c.selectionStartUs, 80000000);
        await c.moveSelection(true, 20000000);
        await c.seekTimeline(50000000);
        await c.moveSelection(false, 10000000);
        expect(c.selectionEndUs, 50000000);
        await c.decideRecording(save: true, trim: true);
        expect(await original.exists(), false);
        expect(c.archive!.rows, 31);
        expect(c.archive!.durationUs, 30000000);
        expect(c.archive!.metadata['original_range_us'], [20000000, 50000000]);
      } finally {
        await recorder.close();
        c.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
