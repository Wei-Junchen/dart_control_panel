import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modifiedMs,
  });

  factory RemoteEntry.fromJson(Map<String, dynamic> json) => RemoteEntry(
    name: json['name'] is String ? json['name'] as String : '',
    path: json['path'] is String ? json['path'] as String : '',
    isDir: json['type'] == 'directory',
    size: json['size'] is num ? (json['size'] as num).toInt() : 0,
    modifiedMs: json['mtime_ms'] is num ? (json['mtime_ms'] as num).toInt() : 0,
  );

  final String name;
  final String path;
  final bool isDir;
  final int size;
  final int modifiedMs;

  DateTime? get modified =>
      modifiedMs > 0 ? DateTime.fromMillisecondsSinceEpoch(modifiedMs) : null;
}

class BoardFileInfo {
  const BoardFileInfo({
    required this.hostname,
    required this.port,
    required this.readOnly,
    required this.range,
    required this.available,
    required this.roots,
  });

  factory BoardFileInfo.fromJson(Map<String, dynamic> json) => BoardFileInfo(
    hostname: json['hostname'] is String ? json['hostname'] as String : '',
    port: json['port'] is num ? (json['port'] as num).toInt() : 9002,
    readOnly: json['read_only'] == true,
    range: json['range'] == true,
    available: json['available'] == true,
    roots: (json['roots'] as List?)?.whereType<String>().toList() ?? const [],
  );

  final String hostname;
  final int port;
  final bool readOnly;
  final bool range;
  final bool available;
  final List<String> roots;
}

class FileServiceException implements Exception {
  const FileServiceException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'FileServiceException: $message';
}

abstract class BoardFileApi {
  String get host;
  int get port;

  Future<BoardFileInfo> info();
  Future<List<RemoteEntry>> list(String path);
  Future<void> download(String remotePath, String localPath);
  Future<String> readText(String remotePath, {int maxBytes = 262144});
  Uri downloadUri(String remotePath);
  void close();
}

/// Read-only HTTP API. No SSH key, password, known_hosts entry or shell is
/// involved. Partial `.part` files are resumed with HTTP Range.
class HttpBoardFileApi implements BoardFileApi {
  HttpBoardFileApi(this.host, {this.port = 9002, HttpClient? client})
    : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 5);
  }

  @override
  final String host;
  @override
  final int port;
  final HttpClient _client;

  Uri _uri(String endpoint, [Map<String, String>? query]) => Uri(
    scheme: 'http',
    host: host,
    port: port,
    path: endpoint,
    queryParameters: query,
  );

  @override
  Uri downloadUri(String remotePath) =>
      _uri('/v1/download', {'path': remotePath});

  Future<HttpClientResponse> _get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    try {
      final request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'dart-control-panel/1');
      headers.forEach(request.headers.set);
      return await request.close();
    } on SocketException catch (e) {
      throw FileServiceException('无法连接 $host:$port：${e.message}');
    } on HttpException catch (e) {
      throw FileServiceException('HTTP 连接失败：${e.message}');
    }
  }

  Future<Uint8List> _readBytes(HttpClientResponse response) async {
    final chunks = <int>[];
    await for (final chunk in response) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  }

  Future<Map<String, dynamic>> _json(Uri uri) async {
    final response = await _get(uri);
    final body = await _readBytes(response);
    Map<String, dynamic>? decoded;
    try {
      final value = jsonDecode(utf8.decode(body));
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    } catch (_) {}
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FileServiceException(
        decoded?['error']?.toString() ?? 'HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    if (decoded == null) {
      throw const FileServiceException('板端返回的 JSON 无效');
    }
    return decoded;
  }

  @override
  Future<BoardFileInfo> info() async =>
      BoardFileInfo.fromJson(await _json(_uri('/v1/info')));

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final json = await _json(_uri('/v1/list', {'path': path, 'limit': '2000'}));
    final raw = json['entries'];
    if (raw is! List) throw const FileServiceException('entries 字段无效');
    return [
      for (final entry in raw)
        if (entry is Map)
          RemoteEntry.fromJson(Map<String, dynamic>.from(entry)),
    ];
  }

  @override
  Future<void> download(String remotePath, String localPath) async {
    final target = File(localPath);
    final partial = File('$localPath.part');
    var existing = await partial.exists() ? await partial.length() : 0;
    var response = await _get(
      downloadUri(remotePath),
      headers: {if (existing > 0) HttpHeaders.rangeHeader: 'bytes=$existing-'},
    );
    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        existing > 0) {
      await response.drain<void>();
      await partial.delete();
      existing = 0;
      response = await _get(downloadUri(remotePath));
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      final bytes = await _readBytes(response);
      String message = 'HTTP ${response.statusCode}';
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map && decoded['error'] != null) {
          message = decoded['error'].toString();
        }
      } catch (_) {}
      throw FileServiceException(message, statusCode: response.statusCode);
    }
    final resume =
        response.statusCode == HttpStatus.partialContent && existing > 0;
    final sink = partial.openWrite(
      mode: resume ? FileMode.append : FileMode.write,
    );
    try {
      await response.pipe(sink);
    } catch (_) {
      await sink.close();
      rethrow; // keep .part for the next resume attempt
    }
    if (await target.exists()) await target.delete();
    await partial.rename(localPath);
  }

  @override
  Future<String> readText(String remotePath, {int maxBytes = 262144}) async {
    final limit = maxBytes.clamp(1024, 1048576);
    final response = await _get(
      downloadUri(remotePath),
      headers: {HttpHeaders.rangeHeader: 'bytes=-$limit'},
    );
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      final body = await _readBytes(response);
      throw FileServiceException(
        utf8.decode(body, allowMalformed: true),
        statusCode: response.statusCode,
      );
    }
    return utf8.decode(await _readBytes(response), allowMalformed: true);
  }

  @override
  void close() => _client.close(force: true);
}
