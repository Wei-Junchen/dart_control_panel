import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/board/api/board_repository.dart';
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
  bool partial = false, closed = false;
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
        ];
  @override
  Future<void> download(String remotePath, String localPath) async {
    downloads.add(remotePath);
    await File(localPath).writeAsString(csv);
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
    c.attach(files, repo);
  });
  tearDown(() async {
    c.dispose();
    await repo.close();
    await server.close();
    await temp.delete(recursive: true);
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
    'explicit copy persists raw CSV, normalized archive, source and copy time',
    () async {
      await c.observeGround(true);
      await c.copyRemote(session, Directory('${temp.path}/chosen'));
      expect(c.error, isNull);
      expect(c.local, hasLength(1));
      final log = c.local.single;
      expect(log.replayable, true);
      expect(await log.file('.csv')!.readAsString(), csv);
      expect(log.metadata['source_path'], session.path);
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
