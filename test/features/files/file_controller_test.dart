import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/features/files/file_controller.dart';
import 'package:dart_control_panel/features/files/board_file_api.dart';

class FakeBoardFileApi implements BoardFileApi {
  final Map<String, List<RemoteEntry>> filesystem = {
    '/': const [
      RemoteEntry(
        name: 'logs',
        path: '/logs',
        isDir: true,
        size: 0,
        modifiedMs: 0,
      ),
      RemoteEntry(
        name: 'recordings',
        path: '/recordings',
        isDir: true,
        size: 0,
        modifiedMs: 0,
      ),
    ],
    '/recordings': const [
      RemoteEntry(
        name: 'flight_1.h264',
        path: '/recordings/flight_1.h264',
        isDir: false,
        size: 1048576,
        modifiedMs: 1788790260000,
      ),
    ],
  };
  final List<(String, String)> downloads = [];
  final List<String> listed = [];
  bool failList = false;
  bool closed = false;

  @override
  String get host => 'board.test';
  @override
  int get port => 9002;

  @override
  Future<BoardFileInfo> info() async => const BoardFileInfo(
    hostname: 'dart-a',
    port: 9002,
    readOnly: true,
    range: true,
    available: true,
    roots: ['/logs', '/recordings'],
  );

  @override
  Future<List<RemoteEntry>> list(String path) async {
    listed.add(path);
    if (failList) throw const FileServiceException('list failed');
    return filesystem[path] ?? const [];
  }

  @override
  Future<void> download(String remotePath, String localPath) async {
    downloads.add((remotePath, localPath));
  }

  @override
  Future<String> readText(String remotePath, {int maxBytes = 262144}) async =>
      'tail:$remotePath';

  @override
  Uri downloadUri(String remotePath) =>
      Uri.parse('http://board.test:9002/v1/download?path=$remotePath');

  @override
  void close() => closed = true;
}

void main() {
  late FakeBoardFileApi api;
  late File bookmarksFile;
  late FileController controller;

  setUp(() {
    api = FakeBoardFileApi();
    final dir = Directory.systemTemp.createTempSync('dart_ctrl_files_');
    bookmarksFile = File('${dir.path}/bookmarks.json');
    controller = FileController(api: api, bookmarksFile: bookmarksFile);
  });

  tearDown(() {
    controller.dispose();
    if (bookmarksFile.existsSync()) bookmarksFile.deleteSync();
    if (bookmarksFile.parent.existsSync()) {
      bookmarksFile.parent.deleteSync(recursive: true);
    }
  });

  test('init probes service and lists virtual roots', () async {
    await controller.init();
    expect(controller.serviceReady, isTrue);
    expect(controller.boardLabel, contains('dart-a · board.test:9002'));
    expect(controller.entries.map((e) => e.name), ['logs', 'recordings']);
    expect(controller.bookmarks, containsAll(['/', '/logs', '/recordings']));
  });

  test('navigation uses server-provided virtual path', () async {
    await controller.init();
    await controller.cd('/recordings/');
    expect(controller.path, '/recordings');
    expect(controller.entries.single.name, 'flight_1.h264');
    await controller.up();
    expect(controller.path, '/');
  });

  test('list failure surfaces without SSH advice', () async {
    api.failList = true;
    await controller.refresh();
    expect(controller.error, contains('list failed'));
    expect(controller.serviceHint(), contains('无需 SSH'));
  });

  test('download uses virtual path and preserves filename', () async {
    await controller.init();
    await controller.cd('/recordings');
    await controller.download(controller.entries.single, '/tmp/opencode');
    expect(api.downloads.single.$1, '/recordings/flight_1.h264');
    expect(api.downloads.single.$2, '/tmp/opencode/flight_1.h264');
    expect(controller.status, contains('download flight_1.h264'));
  });

  test('text preview and direct playback URL use HTTP API', () async {
    const log = RemoteEntry(
      name: 'worker.log',
      path: '/logs/worker.log',
      isDir: false,
      size: 10,
      modifiedMs: 1,
    );
    expect(await controller.readText(log), 'tail:/logs/worker.log');
    expect(controller.downloadUri(log).scheme, 'http');
    expect(controller.downloadUri(log).port, 9002);
  });

  test('bookmark add/remove persists', () async {
    await controller.init();
    await controller.cd('/recordings');
    await controller.addBookmark();
    final reloaded = FileController(api: api, bookmarksFile: bookmarksFile);
    await reloaded.init();
    expect(reloaded.bookmarks, contains('/recordings'));
    await reloaded.removeBookmark('/recordings');
    reloaded.dispose();
  });

  test('joinPath remains normalized for navigation helpers', () {
    expect(FileController.joinPath('/a/', 'b'), '/a/b');
    expect(FileController.joinPath('/a', 'b'), '/a/b');
  });
}
