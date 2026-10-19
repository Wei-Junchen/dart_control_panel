import 'package:dart_control_panel/core/platform/app_paths.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:dart_control_panel/features/files/board_file_api.dart';

/// Read-only board file panel over the dedicated HTTP API.
class FileController extends ChangeNotifier {
  FileController({required this.api, File? bookmarksFile})
    : _bookmarksFile = bookmarksFile ?? _defaultBookmarksFile();

  final BoardFileApi api;
  final File _bookmarksFile;

  static const _defaultBookmarks = ['/', '/logs', '/recordings'];

  String _path = '/';
  List<RemoteEntry> _entries = const [];
  bool _loading = false;
  String? _error;
  bool _busy = false;
  String? _status;
  bool _serviceReady = false;
  BoardFileInfo? _boardInfo;
  List<String> _bookmarks = [..._defaultBookmarks];

  String get path => _path;
  List<RemoteEntry> get entries => _entries;
  bool get loading => _loading;
  bool get busy => _busy;
  String? get error => _error;
  String? get status => _status;

  bool get serviceReady => _serviceReady;
  BoardFileInfo? get boardInfo => _boardInfo;
  String get boardLabel {
    final info = _boardInfo;
    if (info == null) return '${api.host}:${api.port}';
    return '${info.hostname} · ${api.host}:${api.port}';
  }

  List<String> get bookmarks => List.unmodifiable(_bookmarks);

  Future<void> init() async {
    await _loadBookmarks();
    await probe();
    await refresh();
  }

  /// Reachability/auth probe.
  Future<void> probe() async {
    try {
      _boardInfo = await api.info();
      _serviceReady = true;
      _error = _boardInfo!.available ? null : '文件服务在 Flight 模式下锁定';
    } on FileServiceException catch (e) {
      _serviceReady = false;
      _error = e.message;
    }
    notifyListeners();
  }

  String? serviceHint() {
    if (_serviceReady) return null;
    return '无法连接板端只读文件服务 ${api.host}:${api.port}；无需 SSH 密钥或密码。';
  }

  /// Parent of the current path (normalized); [path] itself if at root.
  String get parentPath {
    final trimmed = _path.endsWith('/') && _path != '/'
        ? _path.substring(0, _path.length - 1)
        : _path;
    final idx = trimmed.lastIndexOf('/');
    if (idx <= 0) return '/';
    return trimmed.substring(0, idx);
  }

  static String joinPath(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  Future<void> refresh() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _entries = await api.list(_path);
    } on FileServiceException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = '$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> cd(String newPath) async {
    if (newPath == _path) return;
    _path = newPath.endsWith('/') && newPath != '/'
        ? newPath.substring(0, newPath.length - 1)
        : newPath;
    await refresh();
  }

  Future<void> up() => cd(parentPath);

  /// Downloads [entry] into directory [localDir], keeping its remote name.
  Future<void> download(RemoteEntry entry, String localDir) async {
    _run('download ${entry.name}', () async {
      final localPath = '$localDir/${entry.name}';
      await api.download(entry.path, localPath);
    });
  }

  Future<String> readText(RemoteEntry entry) => api.readText(entry.path);

  Uri downloadUri(RemoteEntry entry) => api.downloadUri(entry.path);

  Future<void> _run(String label, Future<void> Function() op) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await op();
      _status = '$label: ok';
      await refresh();
    } on FileServiceException catch (e) {
      _status = null;
      _error = '$label failed: ${e.message}';
    } catch (e) {
      _status = null;
      _error = '$label failed: $e';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // --- bookmarks -----------------------------------------------------------

  static File _defaultBookmarksFile() {
    return File(
      '${AppPaths.configRoot.path}/dart_control_panel/bookmarks.json',
    );
  }

  Future<void> _loadBookmarks() async {
    if (!_bookmarksFile.existsSync()) return;
    try {
      final decoded = jsonDecode(_bookmarksFile.readAsStringSync());
      if (decoded is List) {
        _bookmarks = [
          for (final b in decoded)
            if (b is String && b.isNotEmpty) b,
        ];
        if (_bookmarks.isEmpty) _bookmarks.addAll(_defaultBookmarks);
      }
    } catch (_) {}
  }

  Future<void> addBookmark() async {
    if (!_bookmarks.contains(_path)) {
      _bookmarks.add(_path);
      await _persistBookmarks();
      notifyListeners();
    }
  }

  Future<void> removeBookmark(String path) async {
    _bookmarks.remove(path);
    await _persistBookmarks();
    notifyListeners();
  }

  Future<void> _persistBookmarks() async {
    try {
      _bookmarksFile.parent.createSync(recursive: true);
      await _bookmarksFile.writeAsString(jsonEncode(_bookmarks));
    } catch (_) {}
  }

  @override
  void dispose() {
    api.close();
    super.dispose();
  }
}

FileController filesFor({required String host, int port = 9002}) =>
    FileController(api: HttpBoardFileApi(host, port: port));
