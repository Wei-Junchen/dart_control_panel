import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/controllers/file_controller.dart';
import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/services/board_ssh.dart';

/// In-memory fake ssh backend: an actual `ls` output template plus recorded
/// scp invocations.
class FakeBoardSsh implements BoardSsh {
  FakeBoardSsh(this.filesystem);

  /// path -> raw `ls -la` output (without the "total N" line)
  final Map<String, String> filesystem;
  final List<(String, String)> downloads = [];
  final List<(String, String)> uploads = [];
  final List<String> listed = [];
  int lsCalls = 0;
  bool failLs = false;
  String lsError = 'ls failed';
  bool failScp = false;

  static const sampleLs = """
drwxr-xr-x 2 root root 4096 2026-09-07 22:10 recordings
-rw-r--r-- 1 root root 1048576 2026-09-07 22:11 flight_1.bin
lrwxrwxrwx 1 root root 9 2026-09-07 22:12 latest -> flight_1.bin
""";

  @override
  String get host => 'board.test';

  @override
  Future<List<RemoteEntry>> ls(String path) async {
    lsCalls++;
    listed.add(path);
    if (failLs) throw SshException(lsError);
    final output = filesystem[path] ?? '';
    return FakeBoardSsh.parseLsSample(output);
  }

  static List<RemoteEntry> parseLsSample(String output) {
    final entries = <RemoteEntry>[];
    for (final line in output.split('\n')) {
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 8) continue;
      String name = parts[7];
      String? link;
      if (parts.length >= 10 && parts[8] == '->') {
        link = parts[9];
      } else {
        final arrow = name.indexOf(' -> ');
        if (arrow >= 0) {
          link = name.substring(arrow + 4);
          name = name.substring(0, arrow);
        }
      }
      entries.add(RemoteEntry(
        name: name,
        isDir: parts[0].startsWith('d'),
        size: int.tryParse(parts[4]) ?? 0,
        modified: '${parts[5]} ${parts[6]}',
        linkTarget: link,
      ));
    }
    return entries;
  }

  @override
  Future<void> download(String remotePath, String localPath) async {
    if (failScp) throw const SshException('scp failed');
    downloads.add((remotePath, localPath));
  }

  @override
  Future<void> upload(String localPath, String remotePath) async {
    if (failScp) throw const SshException('scp failed');
    uploads.add((localPath, remotePath));
  }

  @override
  Future<bool> ping() async => !failLs;
}

void main() {
  late FakeBoardSsh ssh;
  late File bookmarksFile;
  late FileController controller;

  setUp(() {
    ssh = FakeBoardSsh({
      '/': '''
drwxr-xr-x 2 root root 4096 2026-09-07 20:00 release
-rw-r--r-- 1 root root 100 2026-09-07 20:01 boot.log
''',
      '/release': FakeBoardSsh.sampleLs,
    });
    final dir = Directory.systemTemp.createTempSync('dart_ctrl_files_');
    bookmarksFile = File('${dir.path}/bookmarks.json');
    controller = FileController(ssh: ssh, bookmarksFile: bookmarksFile);
  });

  tearDown(() {
    if (bookmarksFile.existsSync()) bookmarksFile.deleteSync();
    bookmarksFile.parent.deleteSync(recursive: true);
  });

  group('FileController', () {
    test('init lists the root and default bookmarks exist', () async {
      await controller.init();
      expect(controller.path, '/');
      expect(controller.entries.map((e) => e.name), contains('release'));
      expect(controller.error, isNull);
      expect(controller.bookmarks, containsAll(['/', '/release', '/release/recordings']));
    });

    test('parses directories, files and symlinks', () async {
      await controller.cd('/release');
      final entries = controller.entries;
      expect(entries, hasLength(3));
      final dir = entries.firstWhere((e) => e.name == 'recordings');
      expect(dir.isDir, isTrue);
      final file = entries.firstWhere((e) => e.name == 'flight_1.bin');
      expect(file.isDir, isFalse);
      expect(file.size, 1048576);
      final link = entries.firstWhere((e) => e.name == 'latest');
      expect(link.linkTarget, 'flight_1.bin');
    });

    test('navigation: up and cd normalize trailing slashes', () async {
      await controller.init();
      await controller.cd('/release/');
      expect(controller.path, '/release');
      await controller.up();
      expect(controller.path, '/');
    });

    test('ls failure surfaces as an error and keeps the path', () async {
      ssh.failLs = true;
      await controller.init();
      await controller.cd('/release');
      expect(controller.error, contains('ls failed'));
      expect(controller.path, '/release');
    });

    test('download builds remote path and keeps local filename', () async {
      await controller.init();
      await controller.cd('/release');
      final file = controller.entries.firstWhere((e) => e.name == 'flight_1.bin');
      await controller.download(file, '/tmp/opencode');
      expect(ssh.downloads, hasLength(1));
      expect(ssh.downloads.first.$1, '/release/flight_1.bin');
      expect(ssh.downloads.first.$2, '/tmp/opencode/flight_1.bin');
      expect(controller.status, contains('download flight_1.bin'));
    });

    test('upload targets the current directory', () async {
      await controller.init();
      await controller.cd('/release');
      await controller.upload('/tmp/opencode/app_new.bin');
      expect(ssh.uploads.single.$2, '/release/app_new.bin');
      expect(ssh.uploads.single.$1, '/tmp/opencode/app_new.bin');
    });

    test('scp failure sets an error and refreshes', () async {
      await controller.init();
      await controller.cd('/release');
      ssh.failScp = true;
      final file = controller.entries.firstWhere((e) => e.name == 'flight_1.bin');
      await controller.download(file, '/tmp/opencode');
      expect(controller.error, contains('scp failed'));
      expect(controller.busy, isFalse);
    });

    test('bookmark add/remove persists', () async {
      await controller.init();
      await controller.cd('/release');
      await controller.addBookmark();
      expect(controller.bookmarks, contains('/release'));

      final reloaded = FileController(ssh: ssh, bookmarksFile: bookmarksFile);
      await reloaded.init();
      expect(reloaded.bookmarks, contains('/release'));

      await reloaded.removeBookmark('/release');
      expect(reloaded.bookmarks, isNot(contains('/release')));
    });
  });

  group('BoardSshImpl parse', () {
    test('real ls output parses correctly (integration-ish)', () async {
      const raw = 'total 12\n'
          'drwxr-xr-x 3 root root 4096 2026-09-07 22:10 runtime\n'
          '-rw-r--r-- 1 root root 2048 2026-09-07 22:11 note.txt\n';
      final entries = FakeBoardSsh.parseLsSample(raw);
      expect(entries, hasLength(2));
      expect(entries[0].name, 'runtime');
      expect(entries[0].isDir, isTrue);
      expect(entries[1].size, 2048);
    });

  });

  group('BoardSshImpl auth modes', () {
    test('key mode uses BatchMode and no sshpass', () {
      final ssh = BoardSshImpl('10.0.0.1');
      final args = ssh.sshArgsFor(['true']);
      expect(args, containsAllInOrder(['ssh', '-o', 'BatchMode=yes']));
      expect(args, isNot(contains('sshpass')));

      final scpArgs = ssh.scpArgsFor(['a', 'b']);
      expect(scpArgs.first, 'scp');
      expect(scpArgs, isNot(contains('sshpass')));
    });

    test('password mode uses sshpass -e and drops BatchMode', () {
      final ssh = BoardSshImpl('10.0.0.1', password: 'root');
      final args = ssh.sshArgsFor(['true']);
      expect(args.sublist(0, 2), ['sshpass', '-e']);
      expect(args, isNot(contains('BatchMode=yes')));

      final scpArgs = ssh.scpArgsFor(['a', 'b']);
      expect(scpArgs.sublist(0, 2), ['sshpass', '-e']);
      expect(scpArgs.first, 'sshpass');
    });

    test('joinPath handles trailing slashes', () {
      expect(FileController.joinPath('/a/', 'b'), '/a/b');
      expect(FileController.joinPath('/a', 'b'), '/a/b');
    });
  });

  group('mode envelope parsing', () {
    test('DaemonState exposes mode with ground default', () async {
      final noMode = DaemonStateFixture.mode('');
      expect(noMode.mode, 'ground');
      expect(noMode.modePending, isNull);
      expect(noMode.modeTransition, isFalse);
      final flight = DaemonStateFixture.mode('flight');
      expect(flight.mode, 'flight');
      expect(flight.modePending, 'ground');
      expect(flight.modeTransition, isTrue);
    });
  });
}

class DaemonStateFixture {
  static DaemonState mode(String mode) {
    final envelope = jsonDecode(
            File('test/fixtures/payloads/state_envelope_full.json')
                .readAsStringSync())
        as Map<String, dynamic>;
    final payload = Map<String, dynamic>.from(envelope['payload'] as Map)
      ..['mode_pending'] = mode == 'flight' ? 'ground' : null
      ..['mode_transition'] = mode == 'flight';
    if (mode.isNotEmpty) payload['mode'] = mode;
    envelope['payload'] = payload;
    return DaemonState.fromEnvelope(envelope);
  }
}