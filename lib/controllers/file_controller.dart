import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:dart_control_panel/services/board_ssh.dart';

/// Remote file panel state: current directory, entries, bookmarks, and
/// download/upload through the injected [BoardSsh].
class FileController extends ChangeNotifier {
  FileController({required this.ssh, File? bookmarksFile})
      : _bookmarksFile = bookmarksFile ?? _defaultBookmarksFile();

  final BoardSsh ssh;
  final File _bookmarksFile;

  static const _defaultBookmarks = ['/', '/release', '/release/recordings'];

  String _path = '/';
  List<RemoteEntry> _entries = const [];
  bool _loading = false;
  String? _error;
  bool _busy = false;
  String? _status;
  bool _sshReady = false;
  List<String> _bookmarks = [..._defaultBookmarks];

  String get path => _path;
  List<RemoteEntry> get entries => _entries;
  bool get loading => _loading;
  bool get busy => _busy;
  String? get error => _error;
  String? get status => _status;

  /// True once a `ssh ping` succeeded (auth + reachability verified).
  bool get sshReady => _sshReady;
  List<String> get bookmarks => List.unmodifiable(_bookmarks);

  Future<void> init() async {
    await _loadBookmarks();
    await probe();
    await refresh();
  }

  /// Reachability/auth probe.
  Future<void> probe() async {
    _sshReady = await ssh.ping();
    notifyListeners();
  }

  /// Maps common ssh failure text to actionable advice.
  String? sshHint() {
    if (_sshReady) return null;
    return 'SSH 连接不可用：${_hintForError(error ?? '认证/可达性失败')}';
  }

  String _hintForError(String text) {
    if (text.contains('Permission denied')) {
      return '认证失败（Permission denied）——请配置密钥后重试：\n'
          '  本机执行: ssh-copy-id root@${ssh.host}\n'
          '  或确认 ssh 用户名（默认 root，可用 DART_CTRL_SSH_USER 环境变量覆盖）';
    }
    if (text.contains('No route to host') || text.contains('timed out') ||
        text.contains('Connection refused')) {
      return '网络不可达/超时/拒绝连接——检查板端 IP 与网段';
    }
    if (text.contains('Unknown cipher') || text.contains('no matching')) {
      return 'openssh 版本不匹配，请升级本机 openssh-client';
    }
    return '详见下方错误信息';
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
      _entries = await ssh.ls(_path);
    } on SshException catch (e) {
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
      await ssh.download(joinPath(_path, entry.name), localPath);
    });
  }

  /// Uploads local file [localPath] to the current remote directory.
  Future<void> upload(String localPath) async {
    final name = localPath.split(Platform.pathSeparator).last;
    _run('upload $name', () async {
      await ssh.upload(localPath, joinPath(_path, name));
    });
  }

  Future<void> _run(String label, Future<void> Function() op) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await op();
      _status = '$label: ok';
      await refresh();
    } on SshException catch (e) {
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
    final configHome = Platform.environment['XDG_CONFIG_HOME']?.trim();
    final base = (configHome != null && configHome.isNotEmpty)
        ? Directory(configHome)
        : Directory('${Platform.environment['HOME'] ?? '.'}/.config');
    return File('${base.path}/dart_control_panel/bookmarks.json');
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
}

/// Convenience: build a FileController for the shared session's host.
BoardSsh sshFor({required String host, String user = 'root'}) =>
    BoardSshImpl(host, user: user);