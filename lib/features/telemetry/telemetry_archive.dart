import 'package:dart_control_panel/core/platform/app_paths.dart';
import 'package:dart_control_panel/core/board/session/board_config_snapshot.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:dart_control_panel/core/preferences/telemetry_log_settings.dart';
import 'package:dart_control_panel/core/preferences/device_registry.dart';

import 'package:flutter/foundation.dart';
import 'telemetry_sample.dart';

List<String> _csvCells(String line) {
  final out = <String>[];
  final value = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      if (quoted && i + 1 < line.length && line[i + 1] == '"') {
        value.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (c == ',' && !quoted) {
      out.add(value.toString());
      value.clear();
    } else {
      value.write(c);
    }
  }
  if (quoted) throw const FormatException('CSV quote is not closed');
  out.add(value.toString());
  return out;
}

/// Only accepted receiver samples enter this bounded, asynchronous writer.
/// UI windows and playback never own the recording lifecycle.
class TelemetryRecorder extends ChangeNotifier {
  TelemetryRecorder({
    Directory? directory,
    this.capacity = 2048,
    TelemetryLogSettingsStore? settingsStore,
  }) : settingsStore = settingsStore ?? TelemetryLogSettingsStore() {
    settings = this.settingsStore.load();
    this.directory = directory ?? defaultDirectory(settings: settings);
  }
  Directory directory = Directory('.');
  String? deviceId;
  Directory get sessionRoot => deviceId == null || deviceId!.isEmpty
      ? directory
      : Directory('${directory.path}/${safeDeviceDirectory(deviceId)}');
  final TelemetryLogSettingsStore settingsStore;
  late TelemetryLogSettings settings;
  Future<void> updateSettings(TelemetryLogSettings value) async {
    final path = Directory(value.directory ?? directory.path).absolute;
    await path.create(recursive: true);
    final normalized = TelemetryLogSettings(
      directory: path.path,
      name: value.name,
      tags: List.unmodifiable(value.tags),
    );
    await settingsStore.save(normalized);
    settings = normalized;
    directory = path; // An active session keeps its already opened directory.
    notifyListeners();
  }

  final int capacity;
  static Directory defaultDirectory({TelemetryLogSettings? settings}) {
    final env = Platform.environment;
    final override = env['DART_TELEMETRY_DIR'];
    if (override != null && override.isNotEmpty) return Directory(override);
    final saved = (settings ?? TelemetryLogSettingsStore().load()).directory;
    if (saved != null && saved.isNotEmpty) return Directory(saved);
    return Directory('${AppPaths.dataRoot.path}/dart_control_panel/telemetry');
  }

  bool _connectionManaged = false;
  bool sessionActive = false;
  bool _sessionFinished = false;
  bool get sessionSaved => _sessionFinished;
  Directory? sessionDirectory;
  Map<String, dynamic>? _sessionMetadata;
  final _sessionSegments = <String>[];
  int _sessionStartUs = 0, _endedDurationUs = 0;
  int get sessionDurationUs => sessionActive
      ? _clock.elapsedMicroseconds - _sessionStartUs
      : _endedDurationUs;

  Future<void> beginSession(String endpoint) async {
    try {
      await _beginSession(endpoint);
    } catch (e) {
      sessionActive = false;
      error = e;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _beginSession(String endpoint) async {
    if (_closed) throw StateError('recorder is closed');
    if (sessionActive) await endSession();
    _timer?.cancel();
    _finalizing = true;
    await flush();
    if (error == null) await _finish();
    _timer?.cancel();
    _connectionManaged = true;
    error = null;
    written = dropped = 0;
    _accepted = 0;
    _sessionStartUs = _clock.elapsedMicroseconds;
    _endedDurationUs = 0;
    _sessionFinished = false;
    _sessionSegments.clear();
    current = null;
    _metadata = null;
    _lastSample = null;
    _signature = null;
    final root = sessionRoot;
    await root.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    sessionDirectory = Directory(
      '${root.path}/connection_${stamp}_${pid}_${_counter++}',
    );
    if (await sessionDirectory!.exists()) {
      throw StateError('session already exists');
    }
    await sessionDirectory!.create();
    _sessionMetadata = {
      'format': 'dart_telemetry_session_v1',
      'source': endpoint,
      'device_id': deviceId,
      'started_at': DateTime.now().toUtc().toIso8601String(),
      'complete': false,
    };
    sessionActive = true;
    _finalizing = false;
    await _saveSession();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _kick());
    notifyListeners();
  }

  Future<void>? _finalizeTask;
  Future<void> endSession() {
    if (_finalizeTask != null) return _finalizeTask!;
    if (!sessionActive) return Future.value();
    return _finalizeTask = _endSession().whenComplete(() {
      _finalizeTask = null;
    });
  }

  Future<void> _endSession() async {
    if (!sessionActive) return;
    _endedDurationUs = sessionDurationUs;
    sessionActive = false; // Gate new input before draining accepted rows.
    _finalizing = true;
    _sessionMetadata?['ended_at'] = DateTime.now().toUtc().toIso8601String();
    _timer?.cancel();
    _timer = null;
    try {
      await _flush();
      if (error == null) await _finish();
      _sessionFinished = error == null;
      await _saveSession(complete: _sessionFinished);
    } catch (e) {
      _sessionFinished = false;
      error = e;
      try {
        await _file?.close();
      } catch (_) {}
      _file = null;
    }
    notifyListeners();
  }

  void forgetSession(Directory removed) {
    if (sessionActive ||
        _pump != null ||
        sessionDirectory?.path != removed.path) {
      throw StateError('cannot forget an active recording');
    }
    sessionDirectory = current = null;
    _sessionMetadata = _metadata = null;
    _sessionSegments.clear();
    _signature = null;
    _lastSample = null;
    _sessionFinished = false;
    written = dropped = _accepted = _endedDurationUs = 0;
  }

  Future<void> _saveSession({bool? complete}) async {
    if (_sessionMetadata == null || sessionDirectory == null) return;
    _sessionMetadata!.addAll({
      'segments': List.of(_sessionSegments),
      'rows': written,
      'duration_us': sessionDurationUs,
      'complete': complete ?? _sessionFinished,
      'local_dropped_total': dropped,
      'error': error?.toString(),
    });
    final tmp = File('${sessionDirectory!.path}/metadata.json.tmp');
    await tmp.writeAsString(jsonEncode(_sessionMetadata), flush: true);
    await tmp.rename('${sessionDirectory!.path}/metadata.json');
  }

  final _clock = Stopwatch()..start();
  final _queue = Queue<({TelemetrySample sample, int us})>();
  Future<void>? _pump;
  Timer? _timer;
  bool _closed = false;
  bool _finalizing = false;
  Object? error;
  int dropped = 0, written = 0;
  int _accepted = 0;
  Directory? current;
  bool get recording => _file != null;
  RandomAccessFile? _file;
  Map<String, dynamic>? _metadata;
  List<String> _columns = [];
  String? _signature;
  int _startUs = 0, _lastUs = 0, _segmentRows = 0, _counter = 0;
  TelemetrySample? _lastSample;

  int? add(TelemetrySample sample) {
    if (_closed || error != null || (_connectionManaged && !sessionActive)) {
      return null;
    }
    if (_queue.length >= capacity) {
      dropped++;
      return _connectionManaged
          ? _clock.elapsedMicroseconds - _sessionStartUs
          : null;
    }
    final us = _clock.elapsedMicroseconds;
    _queue.add((sample: sample, us: us));
    _accepted++;
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _kick(),
    );
    if (_queue.length >= 64) _kick();
    return _connectionManaged ? us - _sessionStartUs : us;
  }

  void _kick({bool forced = false}) {
    if (_finalizing && !forced) return;
    if (_pump != null || error != null) return;
    _pump = _drain()
        .catchError((Object e) async {
          error = e;
          dropped += _queue.length;
          _queue.clear();
          try {
            await _file?.close();
          } catch (_) {}
          _file = null;
          notifyListeners();
        })
        .whenComplete(() {
          _pump = null;
        });
  }

  Future<void> _drain() async {
    var batch = StringBuffer();
    var count = 0;
    Future<void> writeBatch() async {
      if (count == 0) return;
      await _file!.writeString(batch.toString());
      _segmentRows += count;
      written += count;
      batch = StringBuffer();
      count = 0;
    }

    // Drain only the batch accepted when this pump started. A continuously
    // receiving source must not turn a flush into an unending chase of input.
    var remaining = _queue.length;
    while (remaining-- > 0 && _queue.isNotEmpty) {
      final event = _queue.removeFirst();
      final s = event.sample;
      final columns = s.values.keys.toList()..sort();
      if (columns.any(
        (c) => !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(c),
      )) {
        throw const FormatException('invalid telemetry column name');
      }
      final signature = jsonEncode([
        s.sourceAddress,
        s.schema,
        s.values['stream_id'],
        columns,
      ]);
      if (_file == null ||
          _signature != signature ||
          (!_connectionManaged && event.us - _lastUs > 10000000)) {
        await writeBatch();
        await _finish();
        await directory.create(recursive: true);
        final name =
            '${s.time.toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '')}_${pid}_${_counter++}';
        current = Directory(
          '${(_connectionManaged ? sessionDirectory! : directory).path}/$name',
        );
        if (await current!.exists()) {
          throw StateError('recording directory already exists');
        }
        await current!.create();
        _columns = columns;
        _signature = signature;
        _startUs = _connectionManaged ? _sessionStartUs : event.us;
        _segmentRows = 0;
        _lastUs = event.us;
        _lastSample = s;
        _metadata = {
          'format': 'dart_telemetry_csv_v1',
          'source': s.sourceAddress,
          'elapsed_start_us': event.us - _startUs,
          'started_at': s.time.toUtc().toIso8601String(),
          'schema': s.schema,
          'stream_id': s.values['stream_id'],
          'columns': columns,
          'complete': false,
          'rows': 0,
          'duration_us': 0,
          'receiver_start': s.receiverStats,
          'local_dropped_start': dropped,
        };
        await _saveMetadata();
        _file = await File(
          '${current!.path}/samples.csv.part',
        ).open(mode: FileMode.write);
        await _file!.writeString(
          'client_elapsed_us,client_received_at,${columns.join(',')}\n',
        );
        if (_connectionManaged) {
          _sessionSegments.add(name);
          await _saveSession();
        }
      }
      _lastUs = event.us;
      _lastSample = s;
      final values = _columns
          .map((key) {
            final value = s.values[key];
            return value == null || !value.isFinite ? '' : value.toString();
          })
          .join(',');
      batch.writeln(
        '${event.us - _startUs},${s.time.toUtc().toIso8601String()},$values',
      );
      count++;
      if (count >= 64) await writeBatch();
    }
    await writeBatch();
    if (_file != null) {
      await _file!.flush();
      await _saveMetadata();
      if (!_connectionManaged &&
          _clock.elapsedMicroseconds - _lastUs > 10000000) {
        await _finish();
      }
    }
    await _saveSession();
    notifyListeners();
  }

  Future<void> _saveMetadata({bool complete = false}) async {
    if (_metadata == null || current == null) return;
    _metadata!.addAll({
      'complete': complete,
      'rows': _segmentRows,
      'duration_us': _lastUs >= _startUs ? _lastUs - _startUs : 0,
      'receiver_end': _lastSample?.receiverStats,
      'local_dropped_total': dropped,
    });
    final tmp = File('${current!.path}/metadata.json.tmp');
    await tmp.writeAsString(jsonEncode(_metadata), flush: true);
    await tmp.rename('${current!.path}/metadata.json');
  }

  Future<void> _finish() async {
    if (_file == null) return;
    await _file!.flush();
    await _file!.close();
    _file = null;
    await File(
      '${current!.path}/samples.csv.part',
    ).rename('${current!.path}/samples.csv');
    await _saveMetadata(complete: true);
  }

  Future<void> flush() async {
    // A history read must not start a writer while Disconnect closes its FD.
    if (_closing != null) return _closing;
    if (_finalizeTask != null) return _finalizeTask;
    await _flush();
  }

  Future<void> _flush() async {
    // A flush is a barrier for already accepted rows, not a request to wait
    // for the receiver to go idle. New UDP samples belong to the next batch.
    final target = _accepted;
    do {
      _kick(forced: true);
      await _pump;
    } while (written < target && error == null);
  }

  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _finalizing = true;
    _timer?.cancel();
    if (sessionActive) await endSession();
    _timer?.cancel();
    await _flush();
    if (error == null) {
      try {
        await _finish();
      } catch (e) {
        error = e;
        notifyListeners();
      }
    }
  }
}

class ArchiveRow {
  ArchiveRow(this.elapsedUs, this.sample);
  final int elapsedUs;
  final TelemetrySample sample;
}

/// Sparse byte offsets (one per 256 rows) keep long recordings out of RAM.
class TelemetryArchive {
  TelemetryArchive._(this.directory, this.file, this.metadata);
  final Directory directory;
  File file;
  final Map<String, dynamic> metadata;
  List<String> columns = [];
  final _index = <({int us, int offset})>[];
  int durationUs = 0, rows = 0, incompleteRows = 0;
  int _scannedOffset = 0;

  static Future<TelemetryArchive> open(Directory directory) async {
    final metaFile = File('${directory.path}/metadata.json');
    if (await metaFile.exists()) {
      if (await metaFile.length() > 1048576) {
        throw const FormatException('recording metadata too large');
      }
      final metadata = jsonDecode(await metaFile.readAsString());
      if (metadata is Map<String, dynamic> &&
          metadata['format'] == 'dart_telemetry_session_v1') {
        final archive = TelemetrySessionArchive._(directory, metadata);
        await archive.refresh();
        await _attachConfigSnapshot(archive);
        return archive;
      }
      if (metadata is! Map<String, dynamic> ||
          metadata['format'] != 'dart_telemetry_csv_v1') {
        throw const FormatException('unsupported recording metadata');
      }
      final names = metadata['columns'];
      if (names is! List ||
          names.length > 128 ||
          names.any(
            (n) =>
                n is! String ||
                !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(n),
          ) ||
          names.toSet().length != names.length) {
        throw const FormatException('invalid recording columns');
      }
      var file = File('${directory.path}/samples.csv');
      if (!await file.exists()) {
        file = File('${directory.path}/samples.csv.part');
      }
      final archive = TelemetryArchive._(directory, file, metadata);
      await archive.refresh();
      await _attachConfigSnapshot(archive);
      return archive;
    }
    final manifestFile = File('${directory.path}/flight.json');
    Map<String, dynamic> manifest = {};
    if (await manifestFile.exists() && await manifestFile.length() <= 1048576) {
      final value = jsonDecode(await manifestFile.readAsString());
      if (value is Map<String, dynamic>) manifest = value;
    }
    final board = await _boardCsv(directory, manifest);
    if (board != null) {
      final archive = BoardCsvArchive._(directory, board, manifest);
      await archive.refresh();
      await _attachConfigSnapshot(archive);
      return archive;
    }
    throw const FormatException('recording has no recognised telemetry CSV');
  }

  static Future<void> _attachConfigSnapshot(TelemetryArchive archive) async {
    final snapshot = await BoardConfigSnapshot.read(
      File('${archive.directory.path}/board-config.json'),
    );
    if (snapshot != null) {
      // CSV/schema names remain authoritative; a later connection snapshot
      // must not be used to infer a historical binary layout.
      archive.metadata['board_config_snapshot'] = snapshot.toJson();
    }
  }

  static Future<File?> _boardCsv(
    Directory directory,
    Map<String, dynamic> manifest,
  ) async {
    final names = (manifest['files'] as List?)?.whereType<String>() ?? const [];
    for (final name in names) {
      if (!name.toLowerCase().endsWith('.csv') ||
          name.toLowerCase() == 'samples.csv' ||
          name.endsWith('.part')) {
        continue;
      }
      final file = File('${directory.path}/$name');
      if (await file.exists()) return file;
    }
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last.toLowerCase();
      if (name.endsWith('.csv') &&
          name != 'samples.csv' &&
          !name.endsWith('.part')) {
        return entity;
      }
    }
    return null;
  }

  Future<void> refresh() async {
    if (!await file.exists()) file = File('${directory.path}/samples.csv');
    final size = await file.length();
    if (size < _scannedOffset) {
      throw const FormatException('recording was truncated');
    }
    final doc = jsonDecode(
      await File('${directory.path}/metadata.json').readAsString(),
    );
    if (doc is Map<String, dynamic>) metadata.addAll(doc);
    var header = _scannedOffset == 0;
    incompleteRows = 0;
    await for (final line in _lines(_scannedOffset, size)) {
      _scannedOffset = line.offset + utf8.encode(line.text).length + 1;
      if (header) {
        columns = line.text.split(',');
        final expected = metadata['columns'];
        if (expected is! List ||
            columns.join(',') !=
                [
                  'client_elapsed_us',
                  'client_received_at',
                  ...expected,
                ].join(',')) {
          throw const FormatException('recording header/schema mismatch');
        }
        header = false;
        continue;
      }
      final row = _parse(line.text);
      if (row.elapsedUs < durationUs) {
        throw const FormatException('non-monotonic recording time');
      }
      if (rows % 256 == 0) _index.add((us: row.elapsedUs, offset: line.offset));
      durationUs = row.elapsedUs;
      rows++;
    }
    if (header) throw const FormatException('missing CSV header');
  }

  Stream<({String text, int offset})> _lines([int start = 0, int? end]) async* {
    var pending = <int>[];
    var offset = start;
    await for (final block in file.openRead(start, end)) {
      var first = 0;
      for (var i = 0; i < block.length; i++) {
        if (block[i] != 10) continue;
        final bytes = [...pending, ...block.sublist(first, i)];
        if (bytes.length > 65536) {
          throw const FormatException('CSV row too long');
        }
        yield (text: utf8.decode(bytes), offset: offset);
        offset += bytes.length + 1;
        pending = [];
        first = i + 1;
      }
      pending.addAll(block.sublist(first));
      if (pending.length > 65536) {
        throw const FormatException('CSV row too long');
      }
    }
    // A crash may leave the last write incomplete. Never invent a sample.
    if (pending.isNotEmpty) incompleteRows++;
  }

  ArchiveRow _parse(String line) {
    final cells = line.split(',');
    if (cells.length != columns.length) {
      throw const FormatException('CSV column count mismatch');
    }
    final us = int.parse(cells[0]);
    if (us < 0) throw const FormatException('negative elapsed time');
    final values = <String, double>{};
    for (var i = 2; i < cells.length; i++) {
      final value = cells[i].isEmpty ? double.nan : double.parse(cells[i]);
      if (value.isInfinite) {
        throw const FormatException('infinite recorded value');
      }
      values[columns[i]] = value;
    }
    // A synthetic monotonic timeline prevents wall-clock adjustments affecting plots.
    return ArchiveRow(
      us,
      TelemetrySample(
        time: DateTime.fromMicrosecondsSinceEpoch(us, isUtc: true),
        values: values,
        sourceAddress: metadata['source'] as String?,
        receivedAt: DateTime.parse(cells[1]),
      ),
    );
  }

  /// Exact original row at/before a cursor; no full-range scan through gaps.
  Future<ArchiveRow?> atOrBefore(int targetUs) async {
    if (targetUs < 0 || _index.isEmpty || _index.first.us > targetUs) {
      return null;
    }
    int low = 0, high = _index.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_index[mid].us <= targetUs) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final offset = _index[low - 1].offset;
    ArchiveRow? result;
    await for (final line in _lines(offset, _scannedOffset)) {
      final row = _parse(line.text);
      if (row.elapsedUs > targetUs) break;
      result = row;
    }
    return result;
  }

  Stream<ArchiveRow> range(int fromUs, int toUs) async* {
    if (fromUs < 0 || toUs < fromUs) {
      throw ArgumentError('invalid recording range');
    }
    if (_index.isEmpty) return;
    var offset = _index.first.offset;
    for (final entry in _index) {
      if (entry.us >= fromUs) break;
      offset = entry.offset;
    }
    await for (final line in _lines(offset, _scannedOffset)) {
      final row = _parse(line.text);
      if (row.elapsedUs > toUs) break;
      if (row.elapsedUs >= fromUs) yield row;
    }
  }

  Future<Directory> saveNamed(
    Directory root,
    String name,
    List<String> tags,
  ) async {
    if (metadata['complete'] != true) {
      throw StateError('cannot save an active recording');
    }
    await root.create(recursive: true);
    final sourcePath = await directory.resolveSymbolicLinks();
    final rootPath = await root.resolveSymbolicLinks();
    if (rootPath == sourcePath ||
        rootPath.startsWith('$sourcePath${Platform.pathSeparator}')) {
      throw ArgumentError(
        'save destination cannot be inside the source recording',
      );
    }
    final time =
        (DateTime.tryParse(metadata['started_at'] as String? ?? '') ??
                DateTime.now())
            .toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final safe = name
        .trim()
        .replaceAll(RegExp(r'[\x00-\x1f\x7f/\\:*?"<>|]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    var label = '';
    for (final rune in safe.runes) {
      final next = label + String.fromCharCode(rune);
      if (utf8.encode(next).length > 180) break;
      label = next;
    }
    if (label.isEmpty) label = '日志';
    final base =
        '${two(time.month)}月${two(time.day)}日${two(time.hour)}时${two(time.minute)}分_$label';
    var target = Directory('${root.path}/$base');
    var suffix = 2;
    while (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      target = Directory('${root.path}/${base}_${suffix++}');
    }
    await target.create();
    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        final path =
            '${target.path}/${entity.path.substring(directory.path.length + 1)}';
        if (entity is Directory) {
          await Directory(path).create(recursive: true);
        } else if (entity is File) {
          await File(path).parent.create(recursive: true);
          await entity.copy(path);
        } else {
          throw StateError('unexpected link in recording');
        }
      }
      final doc = {
        ...metadata,
        'log_name': name.trim(),
        'tags': tags.toSet().toList(),
        'saved_at': DateTime.now().toUtc().toIso8601String(),
        'display_timezone_offset_minutes': time.timeZoneOffset.inMinutes,
        'original_recording': metadata['original_recording'] ?? directory.path,
      };
      await File(
        '${target.path}/metadata.json',
      ).writeAsString(jsonEncode(doc), flush: true);
      final check = await TelemetryArchive.open(target);
      if (check.rows != rows) {
        throw StateError('saved recording verification failed');
      }
      return target;
    } catch (_) {
      await target.delete(recursive: true);
      rethrow;
    }
  }

  Future<Directory> exportRange(Directory root, int fromUs, int toUs) async {
    if (fromUs < 0 || toUs < fromUs || toUs > durationUs) {
      throw ArgumentError('invalid export range');
    }
    await root.create(recursive: true);
    final target = Directory(
      '${root.path}/clip_${DateTime.now().microsecondsSinceEpoch}_$pid',
    );
    if (await target.exists()) throw StateError('export already exists');
    await target.create();
    final output = await File(
      '${target.path}/samples.csv.part',
    ).open(mode: FileMode.write);
    var count = 0, duration = 0;
    DateTime? firstReceived, lastReceived;
    try {
      await output.writeString('${columns.join(',')}\n');
      await for (final row in range(fromUs, toUs)) {
        firstReceived ??= row.sample.receivedAt;
        lastReceived = row.sample.receivedAt;
        final elapsed = row.elapsedUs - fromUs;
        final values = columns
            .skip(2)
            .map((c) {
              final value = row.sample.values[c];
              return value == null || !value.isFinite ? '' : value.toString();
            })
            .join(',');
        await output.writeString(
          '$elapsed,${row.sample.receivedAt!.toUtc().toIso8601String()},$values\n',
        );
        duration = elapsed;
        count++;
      }
      await output.flush();
    } finally {
      await output.close();
    }
    final meta = {
      ...metadata,
      'format': 'dart_telemetry_csv_v1',
      'columns': columns.skip(2).toList(),
      'complete': true,
      'rows': count,
      'duration_us': duration,
      'original_recording': directory.path,
      'original_range_us': [fromUs, toUs],
      'original_duration_us': durationUs,
      'clip_first_received_at': firstReceived?.toUtc().toIso8601String(),
      'clip_last_received_at': lastReceived?.toUtc().toIso8601String(),
      'receiver_stats_scope': 'original_recording',
    };
    await File(
      '${target.path}/metadata.json',
    ).writeAsString(jsonEncode(meta), flush: true);
    await File(
      '${target.path}/samples.csv.part',
    ).rename('${target.path}/samples.csv');
    return target;
  }
}

/// Read-only adapter for the board's own flight CSV. It keeps the raw
/// `N.csv` and derives the replay timeline in memory instead of writing a
/// duplicate samples.csv/metadata.json into the flight directory.
class BoardCsvArchive extends TelemetryArchive {
  BoardCsvArchive._(
    Directory directory,
    File file,
    Map<String, dynamic> manifest,
  ) : super._(directory, file, Map<String, dynamic>.of(manifest));

  List<String> _boardHeader = [];
  final _aliases = <String, String>{};
  bool _headerSeen = false;
  int? _firstMonoUs, _previousMonoUs;
  int? _firstFrame, _lastFrame, _firstVisionUs, _lastVisionUs;
  int? _previousFrame, _previousVisionUs;

  @override
  Future<void> refresh() async {
    final size = await file.length();
    if (size < _scannedOffset) {
      throw const FormatException('recording was truncated');
    }
    incompleteRows = 0;
    var headerLine = _scannedOffset == 0;
    await for (final line in _lines(_scannedOffset, size)) {
      _scannedOffset = line.offset + utf8.encode(line.text).length + 1;
      if (headerLine) {
        var text = line.text;
        if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
        _boardHeader = _csvCells(text).map((v) {
          return v.replaceFirst('\uFEFF', '');
        }).toList();
        if (_boardHeader.toSet().length != _boardHeader.length ||
            !_boardHeader.contains('mono_us')) {
          throw const FormatException(
            'board CSV missing mono_us or duplicate columns',
          );
        }
        final names = _boardHeader.where((v) => v != 'uart_schema').toList();
        if (names.any(
          (n) => !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(n),
        )) {
          throw const FormatException('invalid board CSV column name');
        }
        for (final field in ['pitch', 'roll', 'yaw', 'air_speed']) {
          if (!names.contains(field)) {
            for (final candidate in ['uart_$field', 'uart_rx_$field']) {
              if (names.contains(candidate)) {
                _aliases[field] = candidate;
                break;
              }
            }
          }
        }
        if (!names.contains('fps') && names.contains('capture_fps')) {
          _aliases['fps'] = 'capture_fps';
        }
        final replayNames = [...names, ..._aliases.keys];
        if (replayNames.length > 128) {
          throw const FormatException('CSV has more than 128 replay columns');
        }
        columns = ['client_elapsed_us', 'client_received_at', ...replayNames];
        metadata['columns'] = replayNames;
        metadata['format'] = 'dart_telemetry_csv_v1';
        metadata['source'] ??= directory.path;
        metadata['complete'] = true;
        metadata['flight_wall_clock_known'] = false;
        metadata['timestamp_source'] = 'board_monotonic';
        metadata['board_csv'] = file.path;
        _headerSeen = true;
        headerLine = false;
        continue;
      }
      final cells = _csvCells(
        line.text.endsWith('\r')
            ? line.text.substring(0, line.text.length - 1)
            : line.text,
      );
      if (cells.length != _boardHeader.length) {
        throw const FormatException('board CSV column count mismatch');
      }
      final raw = <String, String>{
        for (var i = 0; i < _boardHeader.length; i++) _boardHeader[i]: cells[i],
      };
      final mono = int.tryParse(raw['mono_us'] ?? '');
      if (mono == null ||
          mono < 0 ||
          (_previousMonoUs != null && mono < _previousMonoUs!)) {
        throw const FormatException(
          'board mono_us is invalid or non-monotonic',
        );
      }
      _firstMonoUs ??= mono;
      _previousMonoUs = mono;
      final row = _boardRow(line.text);
      final frame = int.tryParse(raw['frame'] ?? '');
      final vision = int.tryParse(raw['vision_mono_us'] ?? raw['mono_us']!);
      if (frame != null && frame > 0 && vision != null && vision > 0) {
        if (_previousFrame == null) {
          _previousFrame = frame;
          _previousVisionUs = vision;
        } else if (frame > _previousFrame!) {
          _firstFrame ??= _previousFrame;
          _firstVisionUs ??= _previousVisionUs;
          _previousFrame = frame;
          _previousVisionUs = vision;
          _lastFrame = frame;
          _lastVisionUs = vision;
        } else if (frame < _previousFrame!) {
          _previousFrame = frame;
          _previousVisionUs = vision;
          _firstFrame = null;
          _firstVisionUs = null;
          _lastFrame = null;
          _lastVisionUs = null;
        } else {
          _previousVisionUs = vision;
        }
      }
      if (rows % 256 == 0) _index.add((us: row.elapsedUs, offset: line.offset));
      durationUs = row.elapsedUs;
      rows++;
    }
    if (!_headerSeen) {
      throw const FormatException('missing board CSV header');
    }
    double? fps;
    if (_firstFrame != null &&
        _lastFrame! > _firstFrame! &&
        _lastVisionUs! > _firstVisionUs!) {
      final estimate =
          (_lastFrame! - _firstFrame!) *
          1000000 /
          (_lastVisionUs! - _firstVisionUs!);
      if (estimate >= 1 && estimate <= 1000) fps = estimate;
    }
    metadata['rows'] = rows;
    metadata['duration_us'] = durationUs;
    metadata['board_first_mono_us'] = _firstMonoUs;
    metadata['board_last_mono_us'] = _previousMonoUs;
    if (fps != null) metadata['estimated_video_fps'] = fps;
  }

  ArchiveRow _boardRow(String line) {
    if (!_headerSeen) throw const FormatException('board CSV header not read');
    var text = line;
    if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
    final cells = _csvCells(text);
    if (cells.length != _boardHeader.length) {
      throw const FormatException('board CSV column count mismatch');
    }
    final raw = <String, String>{
      for (var i = 0; i < _boardHeader.length; i++) _boardHeader[i]: cells[i],
    };
    final mono = int.tryParse(raw['mono_us'] ?? '');
    if (mono == null || mono < 0) {
      throw const FormatException('board mono_us is invalid');
    }
    _firstMonoUs ??= mono;
    final elapsed = mono - _firstMonoUs!;
    if (elapsed < 0) {
      throw const FormatException('board mono_us is non-monotonic');
    }
    final values = <String, double>{};
    for (final name in columns.skip(2)) {
      final text = raw[_aliases[name] ?? name] ?? '';
      if (text.isEmpty) {
        values[name] = double.nan;
      } else {
        final value = double.tryParse(text);
        if (value == null || value.isInfinite) {
          throw FormatException('board CSV non-numeric column: $name');
        }
        values[name] = value;
      }
    }
    final stamp = DateTime.fromMicrosecondsSinceEpoch(elapsed, isUtc: true);
    return ArchiveRow(
      elapsed,
      TelemetrySample(
        time: stamp,
        values: values,
        sourceAddress: metadata['source'] as String?,
        receivedAt: stamp,
      ),
    );
  }

  @override
  ArchiveRow _parse(String line) => _boardRow(line);
}

/// One Connect session may contain several schema/worker segments, all using
/// the same client monotonic origin. Refresh only scans newly appended bytes.
class TelemetrySessionArchive extends TelemetryArchive {
  TelemetrySessionArchive._(Directory directory, Map<String, dynamic> metadata)
    : super._(directory, File('${directory.path}/samples.csv'), metadata);
  final _segments = <String, TelemetryArchive>{};

  @override
  Future<void> refresh() async {
    final metaFile = File('${directory.path}/metadata.json');
    if (await metaFile.length() > 1048576) {
      throw const FormatException('session metadata too large');
    }
    final doc = jsonDecode(await metaFile.readAsString());
    if (doc is! Map<String, dynamic> ||
        doc['format'] != 'dart_telemetry_session_v1') {
      throw const FormatException('invalid session metadata');
    }
    final names = doc['segments'];
    if (names is! List ||
        names.length > 10000 ||
        names.any((n) => n is! String || !RegExp(r'^[0-9_]+$').hasMatch(n))) {
      throw const FormatException('invalid session segment names');
    }
    metadata.addAll(doc);
    final keys = <String>{};
    final fields = <String, Map>{};
    rows = incompleteRows = 0;
    durationUs = (doc['duration_us'] as num?)?.toInt() ?? 0;
    for (final name in names.cast<String>()) {
      final existing = _segments[name];
      if (existing == null) {
        _segments[name] = await TelemetryArchive.open(
          Directory('${directory.path}/$name'),
        );
      } else {
        await existing.refresh();
      }
      final segment = _segments[name]!;
      rows += segment.rows;
      incompleteRows += segment.incompleteRows;
      if (segment.durationUs > durationUs) durationUs = segment.durationUs;
      keys.addAll(segment.columns.skip(2));
      metadata['segment_schemas'] = [
        for (final child in _segments.values)
          {
            'schema': child.metadata['schema'],
            'elapsed_start_us': child.metadata['elapsed_start_us'],
          },
      ];
      final descriptors = (segment.metadata['schema'] as Map?)?['fields'];
      if (descriptors is List) {
        for (final f in descriptors.whereType<Map>()) {
          fields[f['name'] as String] = f;
        }
      }
    }
    final sorted = keys.toList()..sort();
    columns = ['client_elapsed_us', 'client_received_at', ...sorted];
    metadata['schema'] = {'fields': fields.values.toList()};
  }

  @override
  Future<ArchiveRow?> atOrBefore(int targetUs) async {
    ArchiveRow? result;
    for (final segment in _segments.values) {
      final row = await segment.atOrBefore(targetUs);
      if (row != null &&
          (result == null || row.elapsedUs >= result.elapsedUs)) {
        result = row;
      }
    }
    return result;
  }

  @override
  Stream<ArchiveRow> range(int fromUs, int toUs) async* {
    if (fromUs < 0 || toUs < fromUs) {
      throw ArgumentError('invalid recording range');
    }
    for (final segment in _segments.values) {
      if (segment.durationUs < fromUs) continue;
      yield* segment.range(fromUs, toUs);
    }
  }
}
