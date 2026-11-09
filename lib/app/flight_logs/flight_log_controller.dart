import 'package:dart_control_panel/core/platform/app_paths.dart';
import 'package:dart_control_panel/core/platform/android_log_share.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:dart_control_panel/core/video/android_h264_remuxer.dart';
import 'package:dart_control_panel/core/board/api/board_repository.dart';
import 'package:dart_control_panel/core/board/session/board_config_snapshot.dart';
import 'package:dart_control_panel/features/files/board_file_api.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:dart_control_panel/core/preferences/device_registry.dart';

class LocalFlightLog {
  LocalFlightLog(this.directory, this.metadata, {this.snapshot});
  final BoardConfigSnapshot? snapshot;
  final Directory directory;
  final Map<String, dynamic> metadata;
  String get name =>
      metadata['remote_name']?.toString() ??
      directory.path.split(Platform.pathSeparator).last;
  List<File> files(String suffix) {
    final names =
        (metadata['files'] as List?)?.whereType<String>() ?? const <String>[];
    final result = <File>[];
    for (final name in names) {
      if (name.contains('/') ||
          name.contains('\\') ||
          name == '.' ||
          name == '..') {
        continue;
      }
      final path = File('${directory.path}/$name');
      if (name.toLowerCase().endsWith(suffix.toLowerCase()) &&
          FileSystemEntity.typeSync(path.path, followLinks: false) ==
              FileSystemEntityType.file) {
        result.add(path);
      }
    }
    return result;
  }

  File? file(String suffix) {
    final list = files(suffix);
    return list.isEmpty ? null : list.first;
  }

  File? mp4For(File raw) {
    final value = File('${raw.path.substring(0, raw.path.length - 5)}.mp4');
    return value.existsSync() ? value : null;
  }

  File? _h264(bool raw) {
    for (final file in files('.h264')) {
      if (file.path.toLowerCase().contains('.raw.') == raw) return file;
    }
    return null;
  }

  File? _mp4(bool raw) {
    for (final file in files('.mp4')) {
      if (file.path.toLowerCase().contains('.raw.') == raw) return file;
    }
    return null;
  }

  File? get overlayH264 => _h264(false);
  File? get rawH264 => _h264(true);
  File? get overlayMp4 {
    final h264 = overlayH264;
    return h264 == null ? _mp4(false) : mp4For(h264);
  }

  File? get rawMp4 {
    final h264 = rawH264;
    return h264 == null ? _mp4(true) : mp4For(h264);
  }

  bool get hasOverlay => overlayH264 != null || overlayMp4 != null;
  bool get hasRaw => rawH264 != null || rawMp4 != null;
  File? get mp4 => overlayMp4;
  bool get needsRemux => files('.h264').any((raw) => mp4For(raw) == null);

  bool get replayable =>
      File('${directory.path}/metadata.json').existsSync() ||
      file('.csv') != null;

  String? get deviceId {
    final value = metadata['device_id'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  String? get sn => metadata['sn']?.toString();

  Future<BoardConfigSnapshot?> configSnapshot() =>
      BoardConfigSnapshot.read(File('${directory.path}/board-config.json'));
}

/// One app-lifetime coordinator. Automatic maintenance only removes empty
/// sessions; downloading, remuxing and nonempty deletion are explicit actions.
class FlightLogController extends ChangeNotifier {
  FlightLogController({
    Directory? localRoot,
    Directory? legacyRoot,
    File? settingsFile,
    Future<void> Function(Directory)? shareLog,
  }) : _shareLog = shareLog ?? AndroidLogShare.share,
       localRoot = localRoot ?? FlightLogController.defaultLocalRoot(),
       legacyRoot =
           legacyRoot ??
           localRoot ??
           Directory('${TelemetryRecorder.defaultDirectory().path}/flights'),
       settingsFile =
           settingsFile ??
           File(
             '${AppPaths.configRoot.path}/dart_control_panel/flight_logs.json',
           );
  static Directory defaultLocalRoot() =>
      Directory('${AppPaths.dataRoot.path}/dart_control_panel/flights');

  final Future<void> Function(Directory) _shareLog;
  Directory localRoot;
  final Directory legacyRoot;
  String? deviceId;
  String? deviceSn;
  Directory get deviceRoot =>
      Directory('${localRoot.path}/${safeDeviceDirectory(deviceId)}');
  final File settingsFile;
  BoardFileApi? _api;
  BoardRepository? _repository;
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? _mutate;
  int _generation = 0;
  Future<BoardConfigSnapshot?>? _connectionSnapshot;
  void setConnectionSnapshot(Future<BoardConfigSnapshot?> snapshot) {
    _connectionSnapshot = snapshot;
  }

  bool _groundObserved = false, ground = false, busy = false, _disposed = false;
  List<RemoteEntry> remote = [];
  List<LocalFlightLog> local = [];
  String? status, error;
  bool get connected => _api != null;
  String? get remoteHost => _api?.host;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> init() async {
    if (await settingsFile.exists()) {
      try {
        final value = jsonDecode(await settingsFile.readAsString());
        if (value is Map && value['directory'] is String) {
          localRoot = Directory(value['directory'] as String);
        }
      } catch (_) {
        /* Keep default on corrupt preferences. */
      }
    }
    await localRoot.create(recursive: true);
    await refreshLocal();
  }

  void attach(
    BoardFileApi api,
    BoardRepository repository, {
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? mutate,
    String? deviceId,
    String? deviceSn,
  }) {
    detach();
    this.deviceId = deviceId;
    this.deviceSn = deviceSn;
    _api = api;
    _repository = repository;
    _mutate = mutate;
    changed();
  }

  void detach() {
    _generation++;
    _api?.close();
    _api = null;
    _repository = null;
    _connectionSnapshot = null;
    _mutate = null;
    ground = _groundObserved = false;
    remote = [];
    changed();
  }

  Future<void> observeGround(bool value) async {
    ground = value;
    if (!value) {
      _groundObserved = false;
      changed();
      return;
    }
    if (_groundObserved || !connected || busy) return;
    _groundObserved = true;
    await refreshRemote(cleanup: true);
  }

  Future<Map<String, dynamic>> _mutation(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async {
    final repo = _repository;
    if (!ground || repo == null) throw StateError('仅允许在连接后的地面模式操作');
    final mutate = _mutate;
    if (mutate != null) return mutate(op, args);
    return op == 'cleanup_recordings'
        ? repo.cleanupRecordings()
        : repo.deleteRecording(args['path'] as String);
  }

  Future<void> refreshRemote({bool cleanup = false}) => _run(() async {
    final api = _api, generation = _generation;
    if (!ground || api == null) throw StateError('飞行模式下日志锁定');
    var cleaned = 0;
    String? warning;
    if (cleanup) {
      try {
        final r = await _mutation('cleanup_recordings');
        cleaned = (r['removed'] as List?)?.length ?? 0;
      } catch (e) {
        warning = '空目录清理失败（可能需要更新板端）：$e';
      }
    }
    final entries = await api.list('/recordings');
    _check(generation);
    remote =
        entries
            .where(
              (e) =>
                  e.isDir && RegExp(r'^flight_[1-9][0-9]*$').hasMatch(e.name),
            )
            .toList()
          ..sort(
            (a, b) => int.parse(
              b.name.substring(7),
            ).compareTo(int.parse(a.name.substring(7))),
          );
    status = '发现 ${remote.length} 条飞行记录，清理 $cleaned 个空目录';
    error = warning;
  });
  void _check(int generation) {
    if (_disposed || generation != _generation) {
      throw StateError('连接已改变，操作停止；部分下载保留');
    }
  }

  void _validateRemote(RemoteEntry entry) {
    if (!entry.isDir ||
        !RegExp(r'^flight_[1-9][0-9]*$').hasMatch(entry.name) ||
        entry.path != '/recordings/${entry.name}') {
      throw ArgumentError('无效的飞行记录路径');
    }
  }

  Future<void> deleteRemote(RemoteEntry entry) => _run(() async {
    _validateRemote(entry);
    final generation = _generation;
    await _mutation('delete_recording', {'path': entry.path, 'confirm': true});
    _check(generation);
    remote.removeWhere((e) => e.path == entry.path);
    status = '已删除板端 ${entry.name}，本地副本不受影响';
  });
  Future<void> setLocalRoot(Directory value) async {
    await value.create(recursive: true);
    localRoot = value.absolute;
    await settingsFile.parent.create(recursive: true);
    await settingsFile.writeAsString(
      jsonEncode({'directory': localRoot.path}),
      flush: true,
    );
    await refreshLocal();
  }

  Future<void> refreshLocal() async {
    final logs = <LocalFlightLog>[];
    final visited = <String>{};
    Future<void> collect(Directory parent, int depth) async {
      final resolved = await parent.resolveSymbolicLinks();
      if (!visited.add(resolved)) return;
      await for (final entity in parent.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final manifest = File('${entity.path}/flight.json');
        try {
          if (await manifest.exists() && await manifest.length() <= 1048576) {
            final m = jsonDecode(await manifest.readAsString());
            if (m is Map<String, dynamic> && m['files'] is List) {
              final snapshot = await BoardConfigSnapshot.read(
                File('${entity.path}/board-config.json'),
              );
              logs.add(LocalFlightLog(entity, m, snapshot: snapshot));
              continue;
            }
          }
        } catch (_) {
          /* A corrupt session must not hide healthy ones. */
        }
        // Recover only recognisable flight-session directories, without
        // guessing an identity or changing a missing/corrupt manifest.
        final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (RegExp(
          r'^(?:.*_)?flight_[1-9][0-9]*(?:_[0-9]+)?$',
        ).hasMatch(name)) {
          final files = <String>[];
          await for (final file in entity.list(followLinks: false)) {
            if (file is File &&
                RegExp(
                  r'\.(?:h264|mp4|csv)$',
                  caseSensitive: false,
                ).hasMatch(file.path)) {
              files.add(file.uri.pathSegments.last);
            }
          }
          if (files.any(
            (name) =>
                RegExp(r'\.(?:h264|mp4)$', caseSensitive: false).hasMatch(name),
          )) {
            logs.add(
              LocalFlightLog(entity, {
                'remote_name': name,
                'files': files,
                'complete': false,
                '_recovered_without_manifest': true,
              }),
            );
            continue;
          }
        }
        if (depth < 3) await collect(entity, depth + 1);
      }
    }

    for (final root in [localRoot, legacyRoot]) {
      if (await root.exists()) await collect(root, 0);
    }
    logs.sort(
      (a, b) => (b.metadata['copied_at']?.toString() ?? '').compareTo(
        a.metadata['copied_at']?.toString() ?? '',
      ),
    );
    local = logs;
    changed();
  }

  Future<void> copyRemote(
    RemoteEntry entry,
    Directory destination,
  ) => _run(() async {
    _validateRemote(entry);
    final api = _api, generation = _generation;
    if (!ground || api == null) throw StateError('仅允许地面模式复制记录');
    final files = await api.list(entry.path);
    _check(generation);
    if (files.any((e) => e.isDir || e.name.endsWith('.part'))) {
      throw StateError('记录未收尾或包含子目录，暂不复制');
    }
    RemoteEntry? boardManifest;
    for (final file in files) {
      if (file.name == 'manifest.json') {
        boardManifest = file;
        break;
      }
    }
    final selected = files
        .where(
          (e) => RegExp(
            r'^[A-Za-z0-9_.-]+\.(csv|h264|mp4)$',
            caseSensitive: false,
          ).hasMatch(e.name),
        )
        .toList();
    if (selected.isEmpty) throw StateError('此记录没有 CSV / H.264 / MP4 文件');
    await setLocalRoot(destination);
    final host = api.host.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final root = Directory(
      '${localRoot.path}/${safeDeviceDirectory(deviceId)}',
    );
    await root.create(recursive: true);
    var dir = Directory('${root.path}/${host}_${entry.name}');
    var index = 2;
    while (await FileSystemEntity.type(dir.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      dir = Directory('${root.path}/${host}_${entry.name}_${index++}');
    }
    await dir.create();
    final metadata = <String, dynamic>{
      'remote_name': entry.name,
      'source_host': api.host,
      'source_path': entry.path,
      'source': '${api.host}:${entry.path}',
      'device_id': deviceId,
      'sn': deviceSn,
      'copied_at': DateTime.now().toUtc().toIso8601String(),
      'flight_wall_clock_known': false,
      'complete': false,
      'files': selected.map((e) => e.name).toList(),
    };
    final manifest = File('${dir.path}/flight.json');
    await manifest.writeAsString(jsonEncode(metadata), flush: true);
    try {
      final snapshot = await _connectionSnapshot;
      _check(generation);
      if (snapshot != null) {
        try {
          await snapshot.write(File('${dir.path}/board-config.json'));
          metadata['config_snapshot'] = 'board-config.json';
          metadata['config_snapshot_source'] = 'connection';
          metadata['config_snapshot_captured_at'] = snapshot.capturedAt
              .toUtc()
              .toIso8601String();
          metadata['config_is_recording_time'] = false;
          await manifest.writeAsString(jsonEncode(metadata), flush: true);
        } catch (_) {
          /* Recording download must not fail for snapshot storage. */
        }
      }
      for (final file in selected) {
        _check(generation);
        status = '复制 ${entry.name}/${file.name}';
        changed();
        final target = File('${dir.path}/${file.name}');
        await api.download(file.path, target.path);
        _check(generation);
        if (await target.length() != file.size) {
          throw StateError('${file.name} 下载长度不匹配');
        }
      }
      if (boardManifest != null) {
        _check(generation);
        status = '复制 ${entry.name}/manifest.json';
        changed();
        final target = File('${dir.path}/board-manifest.json');
        await api.download(boardManifest.path, target.path);
        _check(generation);
        if (await target.length() != boardManifest.size) {
          throw StateError('manifest.json 下载长度不匹配');
        }
        metadata['board_manifest'] = 'board-manifest.json';
        final listed = (metadata['files'] as List).cast<String>().toList();
        if (!listed.contains('board-manifest.json')) {
          listed.add('board-manifest.json');
          metadata['files'] = listed;
        }
      }
      // All remote operations end here. Local processing may continue offline.
      final log = LocalFlightLog(dir, metadata);
      final csv = log.file('.csv');
      double? fps;
      if (csv != null) {
        final archive = await TelemetryArchive.open(dir);
        fps = (archive.metadata['estimated_video_fps'] as num?)?.toDouble();
        metadata.addAll({
          'format': 'dart_flight_log_v1',
          'telemetry_format': archive.metadata['format'],
          'telemetry_columns': archive.metadata['columns'],
          'telemetry_rows': archive.rows,
          'telemetry_duration_us': archive.durationUs,
          'board_first_mono_us': archive.metadata['board_first_mono_us'],
          'board_last_mono_us': archive.metadata['board_last_mono_us'],
          'timestamp_source': archive.metadata['timestamp_source'],
          'source': '${api.host}:${entry.path}',
          'estimated_video_fps': fps,
        });
      }
      metadata['complete'] = true;
      await manifest.writeAsString(jsonEncode(metadata), flush: true);
      final raws = log.files('.h264');
      if (raws.isNotEmpty) {
        if (fps == null) {
          error = '原文件已保存；缺少可靠帧率，请手动指定帧率封装 MP4';
        } else {
          final remuxes = <Map<String, dynamic>>[];
          for (final raw in raws) {
            try {
              status = '本地封装 MP4（不重新编码） ${raw.uri.pathSegments.last}';
              changed();
              final mp4 = await remux(raw, fps);
              remuxes.add({
                'source': raw.uri.pathSegments.last,
                'output': mp4.uri.pathSegments.last,
                'fps': fps,
                'converted_at': DateTime.now().toUtc().toIso8601String(),
                'mode': 'copy',
              });
              metadata['video_remux'] = remuxes;
              await manifest.writeAsString(jsonEncode(metadata), flush: true);
            } catch (e) {
              error = '原始文件和 CSV 已保存，${raw.uri.pathSegments.last} 封装失败：$e';
            }
          }
        }
      }
      status = '已复制到 ${dir.path}；板端 CSV 原文件保留，客户端不生成 samples.csv';
    } catch (e) {
      metadata['error'] = '$e';
      await manifest.writeAsString(jsonEncode(metadata), flush: true);
      rethrow;
    } finally {
      await refreshLocal();
    }
  });
  Future<void> remuxLocal(LocalFlightLog log, double fps) => _run(() async {
    final raws = log.files('.h264');
    if (raws.isEmpty) throw StateError('没有 H.264 原文件');
    final metadata = Map<String, dynamic>.of(log.metadata);
    // Older versions stored one remux as an object; current versions store a
    // list for multiple tracks. Preserve every old entry during conversion.
    final previousRemux = metadata['video_remux'];
    final List<dynamic> remuxes;
    if (previousRemux == null) {
      remuxes = [];
    } else if (previousRemux is List) {
      remuxes = List<dynamic>.of(previousRemux);
    } else if (previousRemux is Map) {
      remuxes = [Map<String, dynamic>.from(previousRemux)];
    } else {
      throw const FormatException('录像封装记录格式无法识别，已保留原文件与元数据');
    }
    var converted = 0;
    for (final raw in raws) {
      if (log.mp4For(raw) != null) continue;
      final mp4 = await remux(raw, fps);
      remuxes.add({
        'source': raw.uri.pathSegments.last,
        'output': mp4.uri.pathSegments.last,
        'fps': fps,
        'converted_at': DateTime.now().toUtc().toIso8601String(),
        'mode': 'copy',
      });
      converted++;
    }
    if (converted == 0) throw StateError('所有 H.264 已有 MP4');
    metadata['video_remux'] = remuxes;
    if (metadata['_recovered_without_manifest'] != true) {
      final manifest = File('${log.directory.path}/flight.json');
      final pending = File('${manifest.path}.remux.part');
      try {
        await pending.writeAsString(jsonEncode(metadata), flush: true);
        await pending.rename(manifest.path);
      } finally {
        if (await pending.exists()) await pending.delete();
      }
    }
    status = '已无损封装 $converted 路 MP4';
    await refreshLocal();
  });

  /// Uses DART_FFMPEG when set, then an `ffmpeg` binary shipped next to the
  /// app (Windows release), and finally whatever is on PATH.
  static String get ffmpegPath {
    final configured = Platform.environment['DART_FFMPEG']?.trim();
    if (configured != null && configured.isNotEmpty) return configured;
    final name = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final local = File(
      '${File(Platform.resolvedExecutable).parent.path}'
      '${Platform.pathSeparator}$name',
    );
    return local.existsSync() ? local.path : name;
  }

  static Future<File> remux(File raw, double fps) async {
    if (!fps.isFinite || fps < 1 || fps > 1000) {
      throw ArgumentError('帧率应在1..1000之间');
    }
    if (!raw.path.toLowerCase().endsWith('.h264')) {
      throw ArgumentError('需要 H.264 原文件');
    }
    final output = File('${raw.path.substring(0, raw.path.length - 5)}.mp4');
    if (await output.exists()) throw StateError('MP4 已存在，不覆盖');
    if (Platform.isAndroid) return AndroidH264Remuxer.convert(raw, fps);
    final temporary = File('${output.path}.part');
    if (await temporary.exists()) await temporary.delete();
    final process = await Process.start(ffmpegPath, [
      '-nostdin',
      '-hide_banner',
      '-loglevel',
      'error',
      '-n',
      '-fflags',
      '+genpts',
      '-r',
      '$fps',
      '-i',
      raw.path,
      '-c:v',
      'copy',
      '-an',
      '-movflags',
      '+faststart',
      '-f',
      'mp4',
      temporary.path,
    ]);
    final stderr = process.stderr.transform(utf8.decoder).join();
    final stdout = process.stdout.drain<void>();
    try {
      final code = await process.exitCode.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          throw StateError('MP4 封装超时');
        },
      );
      await stdout;
      final message = await stderr;
      if (code != 0 ||
          !await temporary.exists() ||
          await temporary.length() == 0) {
        throw StateError('ffmpeg: $message');
      }
      return temporary.rename(output.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> shareLocal(LocalFlightLog log) => _run(() async {
    status = '正在压缩 ${log.name}，完成后打开分享面板…';
    changed();
    await _shareLog(log.directory);
    status = '已打开 ${log.name} 的分享面板（是否发送由目标应用决定）';
  });

  Future<void> deleteLocal(LocalFlightLog log) => _run(() async {
    final actual = await log.directory.resolveSymbolicLinks();
    var allowed = false;
    for (final root in [localRoot, legacyRoot]) {
      if (!await root.exists()) continue;
      final resolved = await root.resolveSymbolicLinks();
      if (actual.startsWith('$resolved${Platform.pathSeparator}')) {
        allowed = true;
        break;
      }
    }
    if (!allowed) {
      throw StateError('不允许删除日志目录之外的文件');
    }
    await log.directory.delete(recursive: true);
    await refreshLocal();
    status = '已删除本地副本，板端原件不受影响';
  });
  Future<void> _run(Future<void> Function() operation) async {
    if (busy) return;
    busy = true;
    error = null;
    status = null;
    changed();
    try {
      await operation();
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    detach();
    super.dispose();
  }
}
