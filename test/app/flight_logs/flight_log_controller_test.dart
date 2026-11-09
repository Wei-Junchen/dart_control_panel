import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/board/api/board_repository.dart';
import 'package:dart_control_panel/core/board/session/board_config_snapshot.dart';
import 'package:dart_control_panel/core/board/api/daemon_client.dart';
import 'package:dart_control_panel/features/files/board_file_api.dart';
import 'package:dart_control_panel/app/flight_logs/flight_log_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';

const csv =
    'mono_us,frame,vision_mono_us,uart_pitch,uart_roll,uart_yaw\n1000000,1,1000000,1,2,3\n1100000,2,1100000,4,5,6\n';
const session = RemoteEntry(
  name: 'flight_2',
  path: '/recordings/flight_2',
  isDir: true,
  size: 0,
  modifiedMs: 0,
);

class FakeFiles implements BoardFileApi {
  bool partial = false, closed = false, withManifest = false;
  final downloads = <String>[];
  @override
  String get host => 'board.test';
  @override
  int get port => 9002;
  @override
  Future<BoardFileInfo> info() async => const BoardFileInfo(
    hostname: 'test',
    port: 9002,
    readOnly: true,
    range: true,
    available: true,
    roots: ['/recordings'],
  );
  static const manifestJson = '{"device_id":"dv1_test","sn":"DART-1"}';
  @override
  Future<List<RemoteEntry>> list(String path) async => path == '/recordings'
      ? [session]
      : [
          RemoteEntry(
            name: partial ? '2.csv.part' : '2.csv',
            path: '/recordings/flight_2/2.csv',
            isDir: false,
            size: utf8.encode(csv).length,
            modifiedMs: 0,
          ),
          if (withManifest)
            RemoteEntry(
              name: 'manifest.json',
              path: '/recordings/flight_2/manifest.json',
              isDir: false,
              size: utf8.encode(manifestJson).length,
              modifiedMs: 0,
            ),
        ];
  @override
  Future<void> download(String remotePath, String localPath) async {
    downloads.add(remotePath);
    if (remotePath.endsWith('manifest.json')) {
      await File(localPath).writeAsString(manifestJson);
    } else {
      await File(localPath).writeAsString(csv);
    }
  }

  @override
  Future<String> readText(String path, {int maxBytes = 262144}) async => csv;
  @override
  Uri downloadUri(String path) => Uri.http('board.test', path);
  @override
  void close() {
    closed = true;
  }
}

void main() {
  test('default flight log root is under application data', () {
    expect(
      FlightLogController.defaultLocalRoot().path,
      endsWith('/dart_control_panel/flights'),
    );
  });
  late Directory temp;
  late FlightLogController c;
  late ServerSocket server;
  late BoardRepository repo;
  late FakeFiles files;
  final requests = <Map<String, dynamic>>[];
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('flight-controller-');
    requests.clear();
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {
      s
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final r = jsonDecode(line) as Map<String, dynamic>;
            requests.add(r);
            s.writeln(jsonEncode({'v': 1, 'type': 'accepted', 'id': r['id']}));
            s.writeln(
              jsonEncode({
                'v': 1,
                'type': 'result',
                'id': r['id'],
                'ok': true,
                'payload': {
                  'removed': r['op'] == 'cleanup_recordings'
                      ? ['/recordings/flight_1']
                      : [r['args']['path']],
                },
              }),
            );
            s.close();
          });
    });
    repo = BoardRepository(DaemonClient(host: '127.0.0.1', port: server.port));
    files = FakeFiles();
    c = FlightLogController(
      localRoot: Directory('${temp.path}/local'),
      settingsFile: File('${temp.path}/settings.json'),
    );
    await c.init();
    c.attach(files, repo, deviceId: 'dv1_test', deviceSn: 'DART-TEST');
  });
  tearDown(() async {
    c.dispose();
    await repo.close();
    await server.close();
    await temp.delete(recursive: true);
  });
  test(
    'recovers identifiable video folders without trusting missing manifests',
    () async {
      final missing = Directory('${c.localRoot.path}/board_flight_4');
      final corrupt = Directory('${c.localRoot.path}/flight_5');
      final unrelated = Directory('${c.localRoot.path}/other');
      for (final dir in [missing, corrupt, unrelated]) {
        await dir.create(recursive: true);
        await File('${dir.path}/video.mp4').writeAsBytes([1, 2, 3]);
      }
      final bad = File('${corrupt.path}/flight.json');
      await bad.writeAsString('{broken');
      await c.refreshLocal();
      expect(c.local, hasLength(2));
      expect(
        c.local.every((log) => log.deviceId == null && log.overlayMp4 != null),
        isTrue,
      );
      expect(await bad.readAsString(), '{broken');
      expect(await File('${missing.path}/flight.json').exists(), isFalse);
    },
  );

  test('discovers legacy root without assigning or moving records', () async {
    final oldRoot = Directory('${temp.path}/telemetry/flights');
    final oldSession = Directory('${oldRoot.path}/10.0.0.1_flight_3');
    await oldSession.create(recursive: true);
    final video = File('${oldSession.path}/flight.h264');
    await video.writeAsBytes([1, 2, 3]);
    final manifest = File('${oldSession.path}/flight.json');
    final original = jsonEncode({
      'remote_name': 'flight_3',
      'source_host': '10.0.0.1',
      'files': ['flight.h264'],
      'complete': true,
    });
    await manifest.writeAsString(original);
    final upgraded = FlightLogController(
      localRoot: Directory('${temp.path}/new'),
      legacyRoot: oldRoot,
      settingsFile: File('${temp.path}/upgrade-settings.json'),
    );
    await upgraded.init();
    expect(upgraded.local, hasLength(1));
    expect(upgraded.local.single.deviceId, isNull);
    expect(upgraded.local.single.overlayH264?.path, video.path);
    expect(await manifest.readAsString(), original);
    expect(await video.readAsBytes(), [1, 2, 3]);
    await upgraded.setLocalRoot(oldRoot);
    expect(upgraded.local, hasLength(1));
    await upgraded.deleteLocal(upgraded.local.single);
    expect(await oldSession.exists(), isFalse);
    upgraded.dispose();
  });

  test(
    'ground entry cleans once, lists records, never automatically downloads',
    () async {
      await c.observeGround(false);
      expect(requests, isEmpty);
      await c.observeGround(true);
      await c.observeGround(true);
      expect(requests.map((r) => r['op']), ['cleanup_recordings']);
      expect(c.remote.single.name, 'flight_2');
      expect(files.downloads, isEmpty);
      await c.observeGround(false);
      await c.observeGround(true);
      expect(requests.length, 2);
    },
  );
  test(
    'explicit copy keeps board CSV, no derived samples, and downloads manifest',
    () async {
      files.withManifest = true;
      await c.observeGround(true);
      await c.copyRemote(session, Directory('${temp.path}/chosen'));
      expect(c.error, isNull);
      expect(c.local, hasLength(1));
      final log = c.local.single;
      expect(log.replayable, true);
      expect(await log.file('.csv')!.readAsString(), csv);
      expect(await File('${log.directory.path}/samples.csv').exists(), false);
      expect(await File('${log.directory.path}/metadata.json').exists(), false);
      expect(
        await File('${log.directory.path}/board-manifest.json').readAsString(),
        FakeFiles.manifestJson,
      );
      final manifest = jsonDecode(
        await File('${log.directory.path}/flight.json').readAsString(),
      );
      expect(manifest['telemetry_rows'], 2);
      expect(manifest['telemetry_columns'], contains('pitch'));
      expect(log.metadata['source_path'], session.path);
      expect(log.metadata['device_id'], 'dv1_test');
      expect(log.metadata['sn'], 'DART-TEST');
      expect(log.directory.path, contains('${c.localRoot.path}/dv1_test/'));
      expect(DateTime.tryParse(log.metadata['copied_at']), isNotNull);
      expect(log.metadata['flight_wall_clock_known'], false);
      final archive = await TelemetryArchive.open(log.directory);
      expect(archive.durationUs, 100000);
      c.detach();
      expect(files.closed, true);
      expect((await archive.range(0, 100000).last).sample.valueOf('pitch'), 4);
      await c.refreshLocal();
      expect(c.local, hasLength(1));
    },
  );
  test(
    'copy attaches only the current connection snapshot and replay preserves CSV schema',
    () async {
      final snapshot = BoardConfigSnapshot(
        config: {
          'detector': {'green_y_min': 88},
          'uart': {
            'rx_layout': {
              'fields': [
                {'name': 'fake'},
              ],
            },
          },
        },
        capturedAt: DateTime.utc(2026),
        host: 'board.test',
        port: 9000,
        deviceId: 'dv1_test',
        resolvedRoi: [10, 20, 100, 80],
      );
      c.setConnectionSnapshot(Future.value(snapshot));
      await c.observeGround(true);
      await c.copyRemote(session, c.localRoot);
      final log = c.local.single;
      final saved = await log.configSnapshot();
      expect(saved?.config['detector']['green_y_min'], 88);
      expect(saved?.resolvedRoi, [10, 20, 100, 80]);
      expect(log.metadata['config_is_recording_time'], false);
      final archive = await TelemetryArchive.open(log.directory);
      expect(
        (archive.metadata['board_config_snapshot'] as Map)['device_id'],
        'dv1_test',
      );
      expect(archive.columns, contains('pitch'));
      expect(archive.columns, isNot(contains('fake')));
      c.detach();
      c.attach(files, repo, deviceId: 'other');
      expect(await c.local.single.configSnapshot(), isNotNull);
    },
  );

  test('partial sessions cannot be copied', () async {
    await c.observeGround(true);
    files.partial = true;
    await c.copyRemote(session, c.localRoot);
    expect(c.error, contains('未收尾'));
    expect(files.downloads, isEmpty);
    expect(c.local, isEmpty);
  });
  test(
    'remote delete sends explicit confirmation and leaves local copy',
    () async {
      await c.observeGround(true);
      await c.copyRemote(session, c.localRoot);
      await c.deleteRemote(session);
      expect(c.remote, isEmpty);
      expect(c.local, hasLength(1));
      expect(requests.last['args'], {'path': session.path, 'confirm': true});
      expect(await c.local.single.file('.csv')!.exists(), true);
    },
  );
  test('local deletion does not invoke remote deletion', () async {
    await c.observeGround(true);
    await c.copyRemote(session, c.localRoot);
    final before = requests.length;
    await c.deleteLocal(c.local.single);
    expect(c.error, isNull);
    expect(c.local, isEmpty);
    expect(requests.length, before);
  });
  test('flight mode refuses mutation without sending TCP', () async {
    await c.observeGround(false);
    await c.deleteRemote(session);
    expect(c.error, contains('地面模式'));
    expect(requests, isEmpty);
  });
  test(
    'legacy object remux metadata is retained while the missing video is remuxed',
    () async {
      final dir = Directory('${temp.path}/legacy_flight_186');
      await dir.create();
      final raw = File('${dir.path}/186.raw.h264');
      final generated = await Process.run('/usr/bin/ffmpeg', [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=c=green:s=16x16:r=25',
        '-frames:v',
        '3',
        '-c:v',
        'libx264',
        '-f',
        'h264',
        raw.path,
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');
      final original = await raw.readAsBytes();
      final existing = File('${dir.path}/186.mp4');
      await existing.writeAsBytes([1, 2, 3]);
      final oldRemux = {
        'fps': 80,
        'output': '186.mp4',
        'mode': 'copy',
        'converted_at': '2026-01-01T00:00:00Z',
        'future_field': {'retained': true},
      };
      final manifest = {
        'remote_name': 'flight_186',
        'files': ['186.h264', '186.raw.h264'],
        'video_remux': oldRemux,
        'complete': true,
        'unrelated': 'keep',
      };
      await File('${dir.path}/186.h264').writeAsBytes(original);
      await File('${dir.path}/flight.json').writeAsString(jsonEncode(manifest));
      final log = LocalFlightLog(dir, manifest);
      c.status = '已删除本地副本，板端原件不受影响';
      await c.remuxLocal(log, 25);
      expect(c.error, isNull);
      expect(c.status, contains('已无损封装'));
      expect(await raw.readAsBytes(), original);
      expect(await existing.readAsBytes(), [1, 2, 3]);
      expect(await File('${dir.path}/186.raw.mp4').length(), greaterThan(0));
      final stored =
          jsonDecode(await File('${dir.path}/flight.json').readAsString())
              as Map;
      expect(stored['unrelated'], 'keep');
      expect((stored['video_remux'] as List).first, oldRemux);
      expect((stored['video_remux'] as List).last['output'], '186.raw.mp4');
    },
    skip: !File('/usr/bin/ffmpeg').existsSync(),
  );

  test('invalid remux metadata is rejected without replacing files', () async {
    final dir = Directory('${temp.path}/invalid_remux');
    await dir.create();
    final raw = File('${dir.path}/186.h264');
    await raw.writeAsBytes([1, 2, 3]);
    final metadata = {
      'files': ['186.h264'],
      'video_remux': 'unexpected',
    };
    final manifest = File('${dir.path}/flight.json');
    final original = jsonEncode(metadata);
    await manifest.writeAsString(original);
    c.status = '已删除本地副本，板端原件不受影响';
    await c.remuxLocal(LocalFlightLog(dir, metadata), 25);
    expect(c.error, contains('录像封装记录格式无法识别'));
    expect(c.status, isNull);
    expect(await manifest.readAsString(), original);
    expect(await raw.readAsBytes(), [1, 2, 3]);
    expect(await File('${dir.path}/186.mp4').exists(), isFalse);
  });
  test(
    'local remux converts annotated and raw H.264 and prefers annotated playback',
    () async {
      final dir = Directory('${temp.path}/dual');
      await dir.create();
      for (final name in ['2.h264', '2.raw.h264']) {
        final generated = await Process.run('/usr/bin/ffmpeg', [
          '-nostdin',
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'lavfi',
          '-i',
          'color=c=green:s=16x16:r=25',
          '-frames:v',
          '10',
          '-c:v',
          'libx264',
          '-f',
          'h264',
          '${dir.path}/$name',
        ]);
        expect(generated.exitCode, 0, reason: '${generated.stderr}');
      }
      await File('${dir.path}/2.csv').writeAsString(csv);
      await File('${dir.path}/flight.json').writeAsString(
        jsonEncode({
          'remote_name': 'flight_2',
          'files': ['2.h264', '2.raw.h264', '2.csv'],
          'complete': true,
        }),
      );
      final manifest =
          jsonDecode(await File('${dir.path}/flight.json').readAsString())
              as Map<String, dynamic>;
      final log = LocalFlightLog(dir, manifest);
      await c.remuxLocal(log, 25);
      expect(c.error, isNull);
      expect(await File('${dir.path}/2.mp4').exists(), true);
      expect(await File('${dir.path}/2.raw.mp4').exists(), true);
      expect(await File('${dir.path}/2.h264').exists(), true);
      expect(await File('${dir.path}/2.raw.h264').exists(), true);
      expect(log.needsRemux, false);
      expect(log.mp4!.path, endsWith('/2.mp4'));
      final updated = jsonDecode(
        await File('${dir.path}/flight.json').readAsString(),
      );
      expect((updated['video_remux'] as List), hasLength(2));
    },
  );

  test(
    'MP4 is remuxed without replacing the raw stream',
    () async {
      final raw = File('${temp.path}/video.h264');
      final generated = await Process.run('/usr/bin/ffmpeg', [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=c=green:s=16x16:r=25',
        '-frames:v',
        '10',
        '-c:v',
        'libx264',
        '-f',
        'h264',
        raw.path,
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');
      final original = await raw.readAsBytes();
      final mp4 = await FlightLogController.remux(raw, 25);
      expect(await mp4.length(), greaterThan(0));
      expect(await raw.readAsBytes(), original);
      final probe = await Process.run('/usr/bin/ffprobe', [
        '-v',
        'error',
        '-show_entries',
        'stream=nb_frames,codec_name',
        '-of',
        'json',
        mp4.path,
      ]);
      final stream =
          (jsonDecode(probe.stdout as String)['streams'] as List).single;
      expect(stream['codec_name'], 'h264');
      expect(stream['nb_frames'], '10');
      await expectLater(FlightLogController.remux(raw, 25), throwsStateError);
    },
    skip:
        !File('/usr/bin/ffmpeg').existsSync() ||
        !File('/usr/bin/ffprobe').existsSync(),
  );
}
