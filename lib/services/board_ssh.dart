import 'dart:convert';
import 'dart:io';

/// One entry from a remote `ls -la`.
class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
    required this.linkTarget,
  });

  final String name;
  final bool isDir;
  final int size;
  final String modified; // board mtime string as-is
  final String? linkTarget; // "-> target" for symlinks, else null
}

/// Errors produced by the ssh/scp layer (no credentials involved).
class SshException implements Exception {
  const SshException(this.message, {this.exitCode});

  final String message;
  final int? exitCode;

  @override
  String toString() => 'SshException: $message';
}

/// Seam for ssh/scp operations; implemented by [BoardSshImpl] and faked in
/// tests.
abstract class BoardSsh {
  String get host;

  /// Lists one directory via `ssh ls -la`.
  Future<List<RemoteEntry>> ls(String path);

  /// Copies a remote file to a local path.
  Future<void> download(String remotePath, String localPath);

  /// Copies a local file to a remote path.
  Future<void> upload(String localPath, String remotePath);

  /// True once the board answered anything (reachability probe).
  Future<bool> ping();
}

/// ssh/scp implementation for the board at [host].
///
/// Auth modes:
/// - no [password] → key-based (`BatchMode=yes`, password prompts fail fast);
/// - [password] set → `sshpass -e ssh/scp` with the password passed via the
///   `SSHPASS` environment variable (NOT in argv / `ps` output), session-only,
///   never persisted. Requires `sshpass` installed on the host machine.
///
/// Uses argument arrays only (no shell interpolation).
class BoardSshImpl implements BoardSsh {
  BoardSshImpl(
    this.host, {
    this.user = 'root',
    this.password,
    this.connectTimeoutSec = 5,
  });

  @override
  final String host;
  final String user;
  final String? password;
  final int connectTimeoutSec;

  String get _target => '$user@$host';

  String get _sshpass =>
      password != null && password!.isNotEmpty ? 'sshpass' : '';

  // --- command construction (package-visible for tests) --------------------

  List<String> sshArgsFor(List<String> args) => [
        if (_sshpass.isNotEmpty) _sshpass,
        if (_sshpass.isNotEmpty) '-e',
        'ssh',
        if (_sshpass.isEmpty) '-o',
        if (_sshpass.isEmpty) 'BatchMode=yes',
        '-o',
        'ConnectTimeout=$connectTimeoutSec',
        '-o',
        'StrictHostKeyChecking=accept-new',
        _target,
        ...args,
      ];

  List<String> scpArgsFor(List<String> args) => [
        if (_sshpass.isNotEmpty) _sshpass,
        if (_sshpass.isNotEmpty) '-e',
        'scp',
        if (_sshpass.isEmpty) '-o',
        if (_sshpass.isEmpty) 'BatchMode=yes',
        '-o',
        'ConnectTimeout=$connectTimeoutSec',
        '-o',
        'StrictHostKeyChecking=accept-new',
        ...args,
      ];

  /// Runs with a password only in the child environment (never argv/disk).
  Future<ProcessResult> _runScp(List<String> argv) => Process.run(
        argv.first,
        argv.skip(1).toList(),
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: password != null && password!.isNotEmpty
            ? {'SSHPASS': password as String}
            : null,
      );

  @override
  Future<List<RemoteEntry>> ls(String path) async {
    var result = await _runScp(sshArgsFor(['ls', '-la', '--time-style=long-iso', path]));
    if (result.exitCode != 0) {
      // busybox ls may reject --time-style; retry with a plain listing
      final retry = await _runScp(sshArgsFor(['ls', '-la', path]));
      if (retry.exitCode == 0) result = retry;
    }
    if (result.exitCode != 0) {
      throw SshException(
          'ls "$path" failed: ${(result.stderr as String).trim()}',
          exitCode: result.exitCode);
    }
    return _parseLs(result.stdout as String);
  }

  List<RemoteEntry> _parseLs(String stdout) {
    final entries = <RemoteEntry>[];
    for (final line in stdout.split('\n').skip(1)) {
      if (line.trim().isEmpty) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 8) continue;
      final perms = parts[0];
      String name = parts[7];
      String? linkTarget;
      // ls -la prints symlinks as "name -> target" (separate fields)
      if (parts.length >= 10 && parts[8] == '->') {
        linkTarget = parts[9];
      } else {
        final arrow = name.indexOf(' -> ');
        if (arrow >= 0) {
          linkTarget = name.substring(arrow + 4);
          name = name.substring(0, arrow);
        }
      }
      entries.add(RemoteEntry(
        name: name,
        isDir: perms.startsWith('d'),
        size: int.tryParse(parts[4]) ?? 0,
        modified: '${parts[5]} ${parts[6]}',
        linkTarget: linkTarget,
      ));
    }
    return entries;
  }

  @override
  Future<void> download(String remotePath, String localPath) async {
    final result = await _runScp(scpArgsFor([
      '$_target:$remotePath',
      localPath,
    ]));
    _throwIfFailed(result, 'download $remotePath');
  }

  @override
  Future<void> upload(String localPath, String remotePath) async {
    final result = await _runScp(scpArgsFor([
      localPath,
      '$_target:$remotePath',
    ]));
    _throwIfFailed(result, 'upload to $remotePath');
  }

  void _throwIfFailed(ProcessResult result, String what) {
    if (result.exitCode != 0) {
      var stderr = (result.stderr as String).trim();
      if (stderr.contains('sshpass')) {
        stderr = 'sshpass not found — install it: sudo apt install sshpass';
      }
      throw SshException('$what failed: $stderr', exitCode: result.exitCode);
    }
  }

  @override
  Future<bool> ping() async {
    final result = await _runScp(sshArgsFor(['true']));
    return result.exitCode == 0;
  }
}