import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';

class ScriptedSource implements TelemetrySource {
  void Function(TelemetrySample)? callback;
  @override
  String get label => 'scripted';
  @override
  void start(void Function(TelemetrySample) onSample) {
    callback = onSample;
  }

  @override
  Future<void> stop() async {}
}

TelemetrySample sample(
  int seq, {
  int stream = 1,
  String peer = '10.0.0.1',
  bool extra = false,
  bool live = false,
}) => TelemetrySample(
  time: live
      ? DateTime.now()
      : DateTime.utc(2026, 10, 12).add(Duration(milliseconds: seq)),
  sourceAddress: peer,
  schema: {
    'id': extra ? 2 : 1,
    'fields': [
      {'name': 'pitch', 'type': 'float32', 'index': 0},
    ],
  },
  receiverStats: {'packets': seq, 'dropped_packets': 2},
  values: {
    'seq': seq.toDouble(),
    'stream_id': stream.toDouble(),
    'mono_ms': seq * 10.0,
    'pitch': seq * 0.125,
    'missing': double.nan,
    if (extra) 'new_field': 3.0,
  },
);

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('telemetry-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'one received sample per CSV row; no timer resampling; metadata preserved',
    () async {
      final recorder = TelemetryRecorder(directory: root);
      for (var i = 0; i < 120; i++) {
        recorder.add(sample(i));
      }
      await recorder.flush();
      expect(recorder.written, 120);
      await recorder.flush();
      expect(recorder.written, 120);
      await recorder.close();
      final archive = await TelemetryArchive.open(recorder.current!);
      expect(archive.rows, 120);
      expect(archive.metadata['complete'], true);
      expect(archive.metadata['schema']['id'], 1);
      final rows = await archive.range(0, archive.durationUs).toList();
      expect(
        rows.map((r) => r.sample.values['seq']),
        List.generate(120, (i) => i.toDouble()),
      );
      expect(rows.last.sample.values['pitch'], 119 * 0.125);
      expect(rows.first.sample.values['missing']!.isNaN, true);
      expect(rows.first.sample.receivedAt, sample(0).time);
      recorder.dispose();
    },
  );

  test(
    'source, worker stream and schema changes rotate files without mixing rows',
    () async {
      final recorder = TelemetryRecorder(directory: root);
      recorder.add(sample(0));
      recorder.add(sample(1, stream: 2));
      recorder.add(sample(2, stream: 2, peer: '10.0.0.2'));
      recorder.add(sample(3, stream: 2, peer: '10.0.0.2', extra: true));
      await recorder.close();
      final directories = await root
          .list()
          .where((e) => e is Directory)
          .toList();
      expect(directories, hasLength(4));
      for (final dir in directories) {
        final archive = await TelemetryArchive.open(dir as Directory);
        expect(archive.rows, 1);
        expect(archive.metadata['complete'], true);
      }
      recorder.dispose();
    },
  );

  test(
    'bounded queue reports overflow and close drains accepted samples',
    () async {
      final recorder = TelemetryRecorder(directory: root, capacity: 3);
      for (var i = 0; i < 10; i++) {
        recorder.add(sample(i));
      }
      expect(recorder.dropped, 7);
      await recorder.close();
      expect(recorder.written, 3);
      expect((await TelemetryArchive.open(recorder.current!)).rows, 3);
      recorder.dispose();
    },
  );

  test('disk failure is explicit and prevents retry storms', () async {
    final blocker = File('${root.path}/blocked');
    await blocker.writeAsString('not a directory');
    final recorder = TelemetryRecorder(directory: Directory(blocker.path));
    recorder.add(sample(0));
    await recorder.flush();
    expect(recorder.error, isNotNull);
    expect(recorder.written, 0);
    recorder.add(sample(1));
    await recorder.close();
    expect(recorder.written, 0);
    recorder.dispose();
  });

  test(
    'sparse seek, interval export, original timestamps and independent reopen',
    () async {
      final recorder = TelemetryRecorder(directory: root);
      for (var i = 0; i < 600; i++) {
        recorder.add(sample(i));
      }
      await recorder.close();
      final archive = await TelemetryArchive.open(recorder.current!);
      final original = await archive.range(0, archive.durationUs).toList();
      final from = original[270].elapsedUs, to = original[410].elapsedUs;
      final expected = original
          .where((r) => r.elapsedUs >= from && r.elapsedUs <= to)
          .toList();
      expect((await archive.range(from, to).toList()).length, expected.length);
      final clip = await archive.exportRange(
        Directory('${root.path}/exports'),
        from,
        to,
      );
      final reopened = await TelemetryArchive.open(clip);
      final clipped = await reopened.range(0, reopened.durationUs).toList();
      expect(clipped.length, expected.length);
      expect(clipped.first.elapsedUs, 0);
      expect(clipped.first.sample.values, expected.first.sample.values);
      expect(clipped.last.sample.receivedAt, expected.last.sample.receivedAt);
      expect(reopened.metadata['original_range_us'], [from, to]);
      expect(archive.rows, 600);
      recorder.dispose();
    },
  );

  test(
    'playback respects the selected interval and stops at its end',
    () async {
      final metadata = File('${root.path}/metadata.json');
      await metadata.writeAsString(
        jsonEncode({
          'format': 'dart_telemetry_csv_v1',
          'columns': ['seq'],
        }),
      );
      await File('${root.path}/samples.csv').writeAsString(
        'client_elapsed_us,client_received_at,seq\n'
        '0,2026-10-12T00:00:00Z,1\n'
        '1000,2026-10-12T00:00:01Z,2\n'
        '2000,2026-10-12T00:00:02Z,3\n',
      );
      final archive = await TelemetryArchive.open(root);
      final controller = TelemetryController(source: ScriptedSource());
      await controller.openArchive(archive);
      controller.setPlaybackRange(1000, 2000);
      await controller.play();
      expect(controller.cursorUs, 1000);
      expect(controller.latest!.values['seq'], 2);
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(controller.cursorUs, 2000);
      expect(controller.playing, false);
      expect(controller.latest!.values['seq'], 3);
      controller.dispose();
    },
  );

  test('partial final line from interrupted recording is ignored', () async {
    final recorder = TelemetryRecorder(directory: root);
    recorder.add(sample(1));
    await recorder.close();
    final file = File('${recorder.current!.path}/samples.csv');
    await file.rename('${file.path}.part');
    await File(
      '${file.path}.part',
    ).writeAsString('999,broken', mode: FileMode.append);
    final archive = await TelemetryArchive.open(recorder.current!);
    expect(archive.rows, 1);
    expect(archive.incompleteRows, 1);
    recorder.dispose();
  });

  test(
    'schema/header mismatch and decreasing elapsed time are rejected',
    () async {
      final dir = Directory('${root.path}/manual');
      await dir.create();
      await File('${dir.path}/metadata.json').writeAsString(
        jsonEncode({
          'format': 'dart_telemetry_csv_v1',
          'columns': ['seq'],
        }),
      );
      final csv = File('${dir.path}/samples.csv');
      await csv.writeAsString('client_elapsed_us,client_received_at,bad\n');
      await expectLater(TelemetryArchive.open(dir), throwsFormatException);
      await csv.writeAsString(
        'client_elapsed_us,client_received_at,seq\n'
        '10,2026-10-12T00:00:00Z,1\n0,2026-10-12T00:00:00Z,2\n',
      );
      await expectLater(TelemetryArchive.open(dir), throwsFormatException);
    },
  );

  test(
    'playback does not stop live reception or recording; return restores live values',
    () async {
      final source = ScriptedSource();
      final recorder = TelemetryRecorder(directory: root);
      final controller = TelemetryController(source: source, recorder: recorder)
        ..start();
      source.callback!(sample(1, live: true));
      await recorder.flush();
      final archive = await TelemetryArchive.open(recorder.current!);
      await controller.openArchive(archive);
      expect(controller.latest!.values['seq'], 1);
      source.callback!(sample(2, live: true));
      expect(controller.latest!.values['seq'], 1);
      await recorder.flush();
      expect(recorder.written, 2);
      controller.returnToLive();
      expect(controller.latest!.values['seq'], 2);
      expect(controller.running, true);
      await recorder.close();
      controller.dispose();
      // The controller asynchronously closes and disposes its recorder.
      await Future<void>.delayed(Duration.zero);
    },
  );
}
