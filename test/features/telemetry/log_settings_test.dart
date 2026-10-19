import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/preferences/telemetry_log_settings.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('log-settings-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test(
    'startup loads persistent directory, default name and tags; corruption falls back',
    () async {
      final store = TelemetryLogSettingsStore(
        file: File('${root.path}/config/telemetry.json'),
      );
      expect(store.load().name, '日志');
      final first = TelemetryRecorder(
        directory: Directory('${root.path}/old'),
        settingsStore: store,
      );
      await first.updateSettings(
        TelemetryLogSettings(
          directory: '${root.path}/new',
          name: '试飞',
          tags: TelemetryLogSettings.parseTags(' A, B，A '),
        ),
      );
      await first.close();
      final next = TelemetryRecorder(
        settingsStore: TelemetryLogSettingsStore(file: store.file),
      );
      expect(next.directory.path, '${root.path}/new');
      expect(next.settings.name, '试飞');
      expect(next.settings.tags, ['A', 'B']);
      await next.close();
      await store.file.writeAsString('{broken');
      expect(store.load().name, '日志');
    },
  );
  test(
    'changing defaults leaves active session in place, next session uses new directory',
    () async {
      final r = TelemetryRecorder(
        directory: Directory('${root.path}/old'),
        settingsStore: TelemetryLogSettingsStore(
          file: File('${root.path}/settings.json'),
        ),
      );
      await r.beginSession('board');
      final old = r.sessionDirectory!;
      r.add(TelemetrySample(time: DateTime.now(), values: {'pitch': 1}));
      await r.updateSettings(
        TelemetryLogSettings(directory: '${root.path}/new', name: 'next'),
      );
      await r.endSession();
      expect(r.sessionDirectory!.path, old.path);
      expect((await TelemetryArchive.open(old)).rows, 1);
      await r.beginSession('board');
      expect(r.sessionDirectory!.path, startsWith('${root.path}/new/'));
      await r.close();
    },
  );
  test(
    'named saves keep exact timestamps, CSV and metadata; collisions never overwrite; crop retains source time',
    () async {
      final source = Directory('${root.path}/source');
      await source.create();
      final meta = {
        'format': 'dart_telemetry_csv_v1',
        'complete': true,
        'columns': ['seq', 'pitch'],
        'started_at': '2026-10-12T11:45:12.123456Z',
        'ended_at': '2026-10-12T11:45:14.987654Z',
        'schema': {'fields': []},
        'source': 'board',
      };
      await File(
        '${source.path}/metadata.json',
      ).writeAsString(jsonEncode(meta));
      const csv =
          'client_elapsed_us,client_received_at,seq,pitch\n0,2026-10-12T11:45:12.123456Z,1,1\n1000000,2026-10-12T11:45:13.223456Z,2,2\n2000000,2026-10-12T11:45:14.987654Z,3,3\n';
      await File('${source.path}/samples.csv').writeAsString(csv);
      final a = await TelemetryArchive.open(source);
      final dest = Directory('${root.path}/chosen');
      final one = await a.saveNamed(dest, '试飞/测试', ['A', 'A', 'B']);
      final two = await a.saveNamed(dest, '试飞/测试', ['C']);
      final date = DateTime.parse(meta['started_at'] as String).toLocal();
      String n(int v) => v.toString().padLeft(2, '0');
      expect(
        one.path,
        endsWith(
          '${n(date.month)}月${n(date.day)}日${n(date.hour)}时${n(date.minute)}分_试飞_测试',
        ),
      );
      expect(two.path, endsWith('_2'));
      expect(await File('${one.path}/samples.csv').readAsString(), csv);
      final saved = await TelemetryArchive.open(one);
      expect(saved.metadata['started_at'], meta['started_at']);
      expect(saved.metadata['ended_at'], meta['ended_at']);
      expect(saved.metadata['tags'], ['A', 'B']);
      expect(saved.metadata['log_name'], '试飞/测试');
      final clip = await a.exportRange(dest, 1000000, 2000000);
      final clipped = await TelemetryArchive.open(clip);
      expect(clipped.metadata['started_at'], meta['started_at']);
      expect(
        clipped.metadata['clip_first_received_at'],
        '2026-10-12T11:45:13.223456Z',
      );
      expect(clipped.metadata['clip_last_received_at'], meta['ended_at']);
      expect(clipped.metadata['original_range_us'], [1000000, 2000000]);
      final namedClip = await clipped.saveNamed(dest, '裁剪', ['clip']);
      expect((await TelemetryArchive.open(namedClip)).rows, 2);
      await expectLater(a.saveNamed(source, 'bad', []), throwsArgumentError);
      expect(await File('${source.path}/samples.csv').readAsString(), csv);
    },
  );
}
