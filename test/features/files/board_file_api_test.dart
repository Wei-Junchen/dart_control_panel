import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/features/files/board_file_api.dart';

void main() {
  late HttpServer server;
  late HttpBoardFileApi api;
  final video = List<int>.generate(4096, (i) => i & 0xff);
  final ranges = <String>[];

  setUp(() async {
    ranges.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      if (path == '/v1/info') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'hostname': 'dart-b',
            'port': server.port,
            'read_only': true,
            'range': true,
            'available': true,
            'roots': ['/logs', '/recordings'],
          }),
        );
      } else if (path == '/v1/list') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'entries': [
              {
                'name': 'run 1.h264',
                'path': '/recordings/run 1.h264',
                'type': 'file',
                'size': video.length,
                'mtime_ms': 1000,
              },
            ],
          }),
        );
      } else if (path == '/v1/download') {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) ranges.add(range);
        var start = 0;
        var end = video.length - 1;
        if (range?.startsWith('bytes=') == true) {
          final spec = range!.substring(6);
          if (spec.startsWith('-')) {
            start = video.length - int.parse(spec.substring(1));
          } else {
            start = int.parse(spec.split('-').first);
          }
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${video.length}',
          );
        }
        request.response.add(video.sublist(start, end + 1));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    api = HttpBoardFileApi('127.0.0.1', port: server.port);
  });

  tearDown(() async {
    api.close();
    await server.close(force: true);
  });

  test('info and virtual listing parse service metadata and paths', () async {
    final info = await api.info();
    expect(info.hostname, 'dart-b');
    expect(info.readOnly, isTrue);
    final entries = await api.list('/recordings');
    expect(entries.single.name, 'run 1.h264');
    expect(entries.single.path, '/recordings/run 1.h264');
    expect(
      api.downloadUri(entries.single.path).queryParameters['path'],
      '/recordings/run 1.h264',
    );
  });

  test('download resumes a .part file with HTTP Range', () async {
    final dir = Directory.systemTemp.createTempSync('dart_file_http_');
    final target = File('${dir.path}/run 1.h264');
    await File('${target.path}.part').writeAsBytes(video.sublist(0, 1000));
    await api.download('/recordings/run 1.h264', target.path);
    expect(await target.readAsBytes(), video);
    expect(ranges, contains('bytes=1000-'));
    expect(File('${target.path}.part').existsSync(), isFalse);
    dir.deleteSync(recursive: true);
  });

  test('readText asks only for a bounded tail', () async {
    final text = await api.readText('/logs/worker.log', maxBytes: 1024);
    expect(text.length, 1024);
    expect(ranges, contains('bytes=-1024'));
  });
}
