import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';

class ConnectionSource implements TelemetrySource {
  void Function(TelemetrySample)? receive;
  @override
  String get label => 'connection-test';
  @override
  void start(void Function(TelemetrySample) onSample) {
    receive = onSample;
  }

  @override
  Future<void> stop() async {}
  void emit(int sequence, {int stream = 1, bool extra = false}) =>
      receive?.call(
        TelemetrySample(
          time: DateTime.now(),
          sourceAddress: '10.0.0.1',
          values: {
            'seq': sequence.toDouble(),
            'stream_id': stream.toDouble(),
            'pitch': sequence.toDouble(),
            if (extra) 'new_field': 2,
          },
          schema: {
            'fields': [
              {'name': 'pitch', 'type': 'float64'},
            ],
          },
        ),
      );
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('connect-record-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'chart inspection freezes only display and resume restores default window',
    () async {
      final source = ConnectionSource();
      final recorder = TelemetryRecorder(directory: root);
      final c = TelemetryController(source: source, recorder: recorder);
      try {
        await c.beginConnection('test');
        source.emit(1);
        await Future<void>.delayed(const Duration(milliseconds: 15));
        source.emit(2);
        await c.inspectChart(centerUs: 0, windowSeconds: 5);
        expect(c.cursorUs, 0);
        expect(c.chartFocusUs, 0);
        final duration = c.timelineDurationUs;
        expect(c.chartWindow, 5);
        expect(c.connected, true);
        expect(recorder.sessionActive, true);
        source.emit(3);
        await recorder.flush();
        expect(recorder.written, 3);
        expect(c.timelineDurationUs, duration);
        c.resumeDisplay();
        expect(c.chartWindow, 20);
        expect(c.followingLatest, true);
        expect(c.latest!.values['seq'], 3);
        await c.endConnection();
        expect(c.archive!.rows, 3);
      } finally {
        await c.endConnection();
        await recorder.close();
        c.dispose();
      }
    },
  );

  test(
    'history flush racing Disconnect never writes to a closing descriptor',
    () async {
      final recorder = TelemetryRecorder(directory: root);
      for (var session = 0; session < 5; session++) {
        await recorder.beginSession('test');
        for (var i = 0; i < 200; i++) {
          recorder.add(
            TelemetrySample(
              time: DateTime.now(),
              values: {'seq': i.toDouble()},
            ),
          );
        }
        final finish = recorder.endSession();
        await Future.wait([
          finish,
          ...List.generate(10, (_) => recorder.flush()),
        ]);
        expect(recorder.error, isNull);
        expect(recorder.sessionSaved, true);
        final archive = await TelemetryArchive.open(recorder.sessionDirectory!);
        expect(archive.rows, 200);
      }
      await recorder.close();
    },
  );

  test(
    'Connect gates recording, pause/seek keep recording, Disconnect finalizes, reconnect creates new session',
    () async {
      final source = ConnectionSource();
      final recorder = TelemetryRecorder(directory: root);
      final c = TelemetryController(source: source, recorder: recorder)
        ..enableConnectionRecording()
        ..start();
      source.emit(0);
      expect(c.latest, isNull);
      expect(await root.list().toList(), isEmpty);
      await c.beginConnection('10.0.0.1:9000');
      final firstDirectory = recorder.sessionDirectory!;
      source.emit(1);
      c.pauseDisplay();
      final frozenCursor = c.timelineCursorUs;
      final frozenDuration = c.timelineDurationUs;
      await Future<void>.delayed(const Duration(milliseconds: 15));
      source.emit(2);
      expect(
        c.latest,
        isNull,
      ); // Window center precedes first sample at startup.
      expect(c.timelineCursorUs, frozenCursor);
      expect(c.timelineDurationUs, frozenDuration);
      expect(recorder.sessionDurationUs, greaterThan(frozenCursor));
      await recorder.flush();
      expect(recorder.written, 2);
      final snapshot = await c.historyForExport();
      final rows = await snapshot!.range(0, snapshot.durationUs).toList();
      await c.seekTimeline(rows.first.elapsedUs);
      expect(c.latest!.values['seq'], 1);
      source.emit(3);
      await recorder.flush();
      expect(recorder.written, 3);
      expect(c.latest!.values['seq'], 1);
      c.returnToLive();
      expect(c.latest!.values['seq'], 3);
      expect(c.timelineDurationUs, greaterThan(frozenCursor));
      expect((c.timelineCursorUs - c.timelineDurationUs).abs(), lessThan(1000));
      await c.endConnection();
      source.emit(4);
      expect(recorder.written, 3);
      final saved = await TelemetryArchive.open(firstDirectory);
      expect(saved.rows, 3);
      expect(saved.metadata['complete'], true);
      expect(saved.metadata['segments'], hasLength(1));
      await c.beginConnection('10.0.0.1:9000');
      expect(recorder.sessionDirectory!.path, isNot(firstDirectory.path));
      expect(c.latest, isNull);
      expect(recorder.written, 0);
      source.emit(100);
      await c.endConnection();
      expect((await TelemetryArchive.open(recorder.sessionDirectory!)).rows, 1);
      expect((await TelemetryArchive.open(firstDirectory)).rows, 3);
      c.dispose();
      await recorder.close();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'worker/schema changes stay inside one connection and exported union CSV reopens',
    () async {
      final recorder = TelemetryRecorder(directory: root);
      final source = ConnectionSource();
      final c = TelemetryController(source: source, recorder: recorder)
        ..start();
      await c.beginConnection('10.0.0.1:9000');
      source.emit(1);
      source.emit(2, stream: 2);
      source.emit(3, stream: 2, extra: true);
      await c.endConnection();
      final saved = await TelemetryArchive.open(recorder.sessionDirectory!);
      expect(saved.rows, 3);
      expect(saved.metadata['segments'], hasLength(3));
      expect(saved.columns, contains('new_field'));
      final clip = await saved.exportRange(
        Directory('${root.path}/clips'),
        0,
        saved.durationUs,
      );
      final imported = await TelemetryArchive.open(clip);
      expect(imported.rows, 3);
      expect(imported.metadata['segment_schemas'], hasLength(3));
      expect(
        (await imported.range(0, imported.durationUs).toList())
            .last
            .sample
            .values['seq'],
        3,
      );
      c.dispose();
      await recorder.close();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'incremental history refresh appends once and handles part-to-final rename',
    () async {
      final recorder = TelemetryRecorder(directory: root);
      await recorder.beginSession('test');
      for (var i = 0; i < 600; i++) {
        recorder.add(
          TelemetrySample(time: DateTime.now(), values: {'seq': i.toDouble()}),
        );
      }
      await recorder.flush();
      final history = await TelemetryArchive.open(recorder.sessionDirectory!);
      expect(history.rows, 600);
      for (var i = 600; i < 610; i++) {
        recorder.add(
          TelemetrySample(time: DateTime.now(), values: {'seq': i.toDouble()}),
        );
      }
      await recorder.flush();
      await history.refresh();
      expect(history.rows, 610);
      await history.refresh();
      expect(history.rows, 610);
      await recorder.endSession();
      await history.refresh();
      expect(history.metadata['complete'], true);
      expect(history.rows, 610);
      expect(
        (await history.range(0, history.durationUs).toList())
            .last
            .sample
            .values['seq'],
        609,
      );
      await recorder.close();
      recorder.dispose();
    },
  );

  test(
    'empty connection is saved and can be opened without CSV segments',
    () async {
      final recorder = TelemetryRecorder(directory: root);
      await recorder.beginSession('test');
      await recorder.endSession();
      final history = await TelemetryArchive.open(recorder.sessionDirectory!);
      expect(history.rows, 0);
      expect(history.metadata['complete'], true);
      expect(await history.range(0, history.durationUs).toList(), isEmpty);
      await recorder.close();
      recorder.dispose();
    },
  );

  test(
    'connection stays open across a UDP silence longer than old idle timeout',
    () async {
      final recorder = TelemetryRecorder(directory: root);
      await recorder.beginSession('test');
      recorder.add(TelemetrySample(time: DateTime.now(), values: {'seq': 1}));
      await recorder.flush();
      await Future<void>.delayed(const Duration(seconds: 11));
      expect(recorder.sessionActive, true);
      expect(recorder.recording, true);
      expect(
        jsonDecode(
          await File(
            '${recorder.sessionDirectory!.path}/metadata.json',
          ).readAsString(),
        )['complete'],
        false,
      );
      recorder.add(TelemetrySample(time: DateTime.now(), values: {'seq': 2}));
      await recorder.endSession();
      final history = await TelemetryArchive.open(recorder.sessionDirectory!);
      expect(history.rows, 2);
      expect(history.metadata['segments'], hasLength(1));
      await recorder.close();
      recorder.dispose();
    },
  );
}
